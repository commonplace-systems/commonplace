defmodule Commonplace.Crypto.NodeIdentityRaceTest do
  @moduledoc """
  CX-37d9: concurrent first-time mints of the node signing identity must not
  race on a shared temp filename.

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

  @rounds 25
  @concurrency 8

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
          {:round, round, :divergent_signing_identities, length(keys),
           :public_keys, Enum.map(keys, fn {pub, _} -> Base.encode64(pub) end)}
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
