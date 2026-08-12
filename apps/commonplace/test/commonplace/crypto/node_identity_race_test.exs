defmodule Commonplace.Crypto.NodeIdentityRaceTest do
  @moduledoc """
  CX-d59r: concurrent first-time mints of node identity artifacts must publish
  once. This re-arms the landed CX-37d9 signing-key pattern and closes the twin
  CX-kmtq node-id defect.

  `mint_keypair/2` wrote the PRIVATE key through one fixed temp path
  (`.node_signing_key.tmp`), chmod'd it, then renamed it into place. Two
  concurrent first-use callers therefore shared a single temp file. The
  identical defect on the PUBLIC-key path raced for real on 2026-08-09 and
  surfaced two layers away as an unrelated-looking error, so this test asserts
  on the OBSERVED values rather than on a predicted failure shape.

  Two distinct failures are possible and both are checked:

    * `File.rename/2` on a temp file another caller already consumed returns
      an error, which propagates out of `signing_context/0`.
    * Two callers each mint a DIFFERENT keypair and each re-read the key file
      at a moment when their own rename was the winner, so the node ends up
      with two divergent signing identities for one node_id.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Crypto.NodeIdentity
  alias Commonplace.Workspace

  @rounds 25
  @concurrency 8
  @node_id_rounds 25

  setup do
    old = Application.get_env(:commonplace, :data_dir)
    on_exit(fn -> Application.put_env(:commonplace, :data_dir, old || "tmp/test_data") end)
    :ok
  end

  test "concurrent first-use mints agree on one keypair and never error" do
    failures =
      Enum.flat_map(1..@rounds, fn round ->
        dir =
          Path.join(
            System.tmp_dir!(),
            "cp_node_id_race_#{System.unique_integer([:positive])}_#{round}"
          )

        File.mkdir_p!(dir)
        # Seed node_id so Workspace.node_id/0 takes its READ path: this test is
        # scoped to the node_signing_key mint, not to node_id's own writer.
        File.write!(Path.join(dir, "node_id"), UUID.uuid4())
        Application.put_env(:commonplace, :data_dir, dir)

        results = race(@concurrency)
        mode = key_file_mode(dir)

        File.rm_rf!(dir)
        classify(round, results, mode)
      end)

    if failures != [] do
      IO.puts("\n=== CX-37d9 observed failures (#{length(failures)}) ===")
      Enum.each(Enum.take(failures, 10), &IO.puts(inspect(&1, limit: :infinity)))
    end

    assert failures == [],
           "concurrent signing_context/0 raced; observed: " <>
             inspect(Enum.take(failures, 5), limit: :infinity)
  end

  test "concurrent node-id first-use never returns filesystem errors" do
    failures =
      Enum.flat_map(1..@node_id_rounds, fn round ->
        {dir, results} = race_node_ids(round)
        File.rm_rf!(dir)

        case Enum.filter(results, &match?({:error, _}, &1)) do
          [] -> []
          errors -> [{:round, round, :errors, Enum.uniq(errors)}]
        end
      end)

    assert failures == [],
           "concurrent Workspace.node_id/1 returned errors: " <>
             inspect(Enum.take(failures, 5), limit: :infinity)
  end

  test "concurrent node-id first-use successful callers never diverge" do
    {dir, results} = race_node_ids_at_publish()
    File.rm_rf!(dir)

    assert [{:ok, first}, {:ok, second}] = results

    assert first == second,
           "successful Workspace.node_id/1 callers returned divergent values: " <>
             inspect([first, second])
  end

  # All tasks block on the same barrier message so they hit mint_keypair/2
  # inside the same scheduling window.
  defp race(n) do
    parent = self()

    tasks =
      for _ <- 1..n do
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :go -> :ok
          end

          NodeIdentity.signing_context()
        end)
      end

    for _ <- 1..n, do: assert_receive({:ready, _}, 5_000)
    Enum.each(tasks, fn t -> send(t.pid, :go) end)
    Task.await_many(tasks, 15_000)
  end

  defp race_node_ids(round) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "cp_workspace_node_id_race_#{System.unique_integer([:positive])}_#{round}"
      )

    File.mkdir_p!(dir)

    {dir, race_call(@concurrency, fn -> Workspace.node_id(dir) end)}
  end

  # Pause both callers at the temp-file write after each has already observed
  # `node_id` as absent. Publishing them one at a time makes a clobbering rename
  # return each caller's own UUID, while create-once makes the loser read back
  # the winner's UUID. The divergence assertion above is deliberately separate
  # from the filesystem-error arm.
  defp race_node_ids_at_publish do
    dir =
      Path.join(
        System.tmp_dir!(),
        "cp_workspace_node_id_divergence_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    parent = self()

    tasks =
      for _ <- 1..2 do
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :go -> Workspace.node_id(dir)
          end
        end)
      end

    for task <- tasks do
      :erlang.trace(task.pid, true, [:call, {:tracer, self()}])
    end

    :erlang.trace_pattern({File, :write, 3}, true, [:local])

    try do
      for _ <- tasks, do: assert_receive({:ready, _}, 5_000)
      Enum.each(tasks, fn task -> send(task.pid, :go) end)

      paused =
        for _ <- tasks do
          assert_receive({:trace, pid, :call, {File, :write, [tmp, fresh, [:write]]}}, 5_000)
          true = :erlang.suspend_process(pid)
          {pid, tmp, fresh}
        end

      results =
        Enum.map(paused, fn {pid, tmp, fresh} ->
          # Restore this caller's own staged value before releasing it. With
          # the defective fixed temp name, the other paused caller may already
          # have truncated or replaced those bytes after emitting its trace.
          File.write!(tmp, fresh, [:write])
          File.chmod!(tmp, 0o600)
          true = :erlang.resume_process(pid)
          task = Enum.find(tasks, &(&1.pid == pid))
          Task.await(task, 5_000)
        end)

      {dir, results}
    after
      :erlang.trace_pattern({File, :write, 3}, false, [:local])

      Enum.each(tasks, fn task ->
        safe_resume(task.pid)
        safe_trace_off(task.pid)
      end)
    end
  end

  defp safe_resume(pid) do
    :erlang.resume_process(pid)
  catch
    :error, :badarg -> false
  end

  defp safe_trace_off(pid) do
    :erlang.trace(pid, false, [:call])
  catch
    :error, :badarg -> false
  end

  defp race_call(n, fun) do
    parent = self()

    tasks =
      for _ <- 1..n do
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :go -> :ok
          end

          fun.()
        end)
      end

    for _ <- 1..n, do: assert_receive({:ready, _}, 5_000)
    Enum.each(tasks, fn task -> send(task.pid, :go) end)
    Task.await_many(tasks, 15_000)
  end

  defp key_file_mode(dir) do
    case File.stat(Path.join(dir, "node_signing_key")) do
      {:ok, %File.Stat{mode: mode}} -> Bitwise.band(mode, 0o7777)
      {:error, reason} -> {:no_key_file, reason}
    end
  end

  defp classify(round, results, mode) do
    errors = for {:error, _} = e <- results, do: e

    keys =
      results
      |> Enum.flat_map(fn
        {:ok, ctx} -> [{ctx.public_key, ctx.private_key}]
        _ -> []
      end)
      |> Enum.uniq()

    cond do
      errors != [] ->
        [{:round, round, :errors, Enum.uniq(errors), :distinct_keypairs, length(keys)}]

      length(keys) > 1 ->
        [
          {:round, round, :divergent_signing_identities, length(keys), :public_keys,
           Enum.map(keys, fn {pub, _} -> Base.encode64(pub) end)}
        ]

      # The key the race publishes must be no more permissive than the key a
      # quiet single-caller mint publishes: 0o600, never world-readable.
      mode != 0o600 ->
        [{:round, round, :private_key_mode, mode, :expected, 0o600}]

      true ->
        []
    end
  end
end
