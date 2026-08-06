defmodule Commonplace.Store.CommitStoreFreshReinitGuardTest do
  @moduledoc """
  CX-pm68: archive-and-start-fresh must not silently substitute an EMPTY
  store when a prior world demonstrably existed. This morning that put an
  enforce-mode serve on a fresh empty world writing genesis docs.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Store.CommitStore

  defp tmp_dir(tag) do
    dir = Path.join(System.tmp_dir!(), "cxpm68_#{tag}_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp uniq(tag), do: :"cxpm68_#{tag}_#{:rand.uniform(1_000_000_000)}"

  defp stop_store(pid, name) do
    db = CommitStore.db_handle(name)
    if Process.alive?(pid), do: GenServer.stop(pid)
    if is_pid(db) and Process.alive?(db), do: CubDB.stop(db)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  # Build a real store with real commits, close it cleanly, then break it.
  #
  # Corruption shape: replace the .cub data file with a DIRECTORY, so
  # CubDB's open(2) fails with :eisdir. Byte-level garbling of the .cub was
  # tried first and is NOT reliable — CubDB tolerated 64KB of random bytes
  # and opened the store as empty (measured, and the same flakiness the
  # CX-xrds salvage tests document). :eisdir is deterministic and exercises
  # the real "CubDB failed to open" branch of init/1.
  defp make_corrupt_store!(dir) do
    name = uniq("seed")
    {:ok, pid} = CommitStore.start_link(data_dir: dir, name: name)
    for n <- 1..25, do: CommitStore.create_commit(name, "doc-#{n}", <<n>>, nil)
    stop_store(pid, name)

    cub =
      Path.join(dir, "commits")
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".cub"))
      |> Enum.map(&Path.join([dir, "commits", &1]))
      |> hd()

    File.rm!(cub)
    File.mkdir_p!(cub)
    cub
  end

  defp archives(dir) do
    dir |> File.ls!() |> Enum.filter(&String.starts_with?(&1, "commits.corrupt."))
  end

  defp with_override(value, fun) do
    prev = Application.get_env(:commonplace, :accept_fresh_reinit)

    try do
      Application.put_env(:commonplace, :accept_fresh_reinit, value)
      fun.()
    after
      if is_nil(prev) do
        Application.delete_env(:commonplace, :accept_fresh_reinit)
      else
        Application.put_env(:commonplace, :accept_fresh_reinit, prev)
      end
    end
  end

  test "prior-world evidence + corrupt store → REFUSES to boot, touches nothing" do
    dir = tmp_dir("refuse")
    cub = make_corrupt_store!(dir)
    File.write!(Path.join(dir, "root"), "11111111-2222-3333-4444-555555555555")
    assert File.dir?(cub)

    Process.flag(:trap_exit, true)
    result = CommitStore.start_link(data_dir: dir, name: uniq("refuse"))

    assert {:error, {:refusing_fresh_reinit, detail}} = result,
           "init silently started fresh instead of refusing: #{inspect(result)}"

    assert detail.data_dir == dir
    assert detail.corrupt_path == Path.join(dir, "commits")
    assert detail.evidence == :root_file_present
    assert detail.reason != nil
    assert is_binary(detail.override)
    assert detail.override =~ "accept_fresh_reinit"

    # The corrupt store is UNTOUCHED — no archive, still in place.
    assert archives(dir) == [], "an archive was created despite the refusal"
    assert File.dir?(cub)
  end

  test "NO prior-world evidence + corrupt store → archive-and-fresh proceeds (as today)" do
    dir = tmp_dir("fresh")
    make_corrupt_store!(dir)
    refute File.exists?(Path.join(dir, "root"))

    name = uniq("fresh")
    assert {:ok, pid} = CommitStore.start_link(data_dir: dir, name: name)
    assert archives(dir) != []
    stop_store(pid, name)
  end

  test "healthy store + root file → opens normally (the guard must not false-alarm)" do
    dir = tmp_dir("healthy")
    name = uniq("healthy_seed")
    {:ok, pid} = CommitStore.start_link(data_dir: dir, name: name)
    commit = CommitStore.create_commit(name, "doc-1", <<1, 2, 3>>, nil)
    stop_store(pid, name)

    File.write!(Path.join(dir, "root"), "11111111-2222-3333-4444-555555555555")

    name2 = uniq("healthy_boot")
    assert {:ok, pid2} = CommitStore.start_link(data_dir: dir, name: name2)
    assert {:ok, fetched} = CommitStore.get_commit(name2, commit.id)
    assert fetched.id == commit.id
    assert archives(dir) == []
    stop_store(pid2, name2)
  end

  test "a genuinely fresh empty data_dir still boots (every fixture depends on this)" do
    dir = tmp_dir("virgin")
    name = uniq("virgin")
    assert {:ok, pid} = CommitStore.start_link(data_dir: dir, name: name)
    stop_store(pid, name)
  end

  test "override + evidence + corrupt → boots fresh AND records a durable boot fact" do
    dir = tmp_dir("override")
    make_corrupt_store!(dir)
    File.write!(Path.join(dir, "root"), "11111111-2222-3333-4444-555555555555")

    with_override(true, fn ->
      name = uniq("override")
      assert {:ok, pid} = CommitStore.start_link(data_dir: dir, name: name)

      [archive] = archives(dir)
      archive_path = Path.join(dir, archive)

      facts =
        CommitStore.db_handle(name)
        |> CubDB.select()
        |> Enum.filter(fn {k, _v} -> match?({:fresh_reinit_fact, _}, k) end)
        |> Enum.to_list()

      assert [{{:fresh_reinit_fact, stamp}, fact}] = facts
      assert {:ok, _, _} = DateTime.from_iso8601(stamp)
      assert fact.predecessor_archive == archive_path
      assert fact.evidence == :root_file_present
      assert fact.reason != nil

      stop_store(pid, name)
    end)
  end

  test "the override reads from COMMONPLACE_ACCEPT_FRESH_REINIT via app env bridging" do
    # The env-var bridge lives in config/runtime.exs (like
    # COMMONPLACE_LOCAL_WRITE_GATE); what this asserts is that the code
    # consults the app-env knob the bridge writes, with a fail-closed default.
    prev = Application.get_env(:commonplace, :accept_fresh_reinit)
    on_exit(fn -> Application.put_env(:commonplace, :accept_fresh_reinit, prev) end)
    Application.delete_env(:commonplace, :accept_fresh_reinit)

    refute CommitStore.accept_fresh_reinit?()

    Application.put_env(:commonplace, :accept_fresh_reinit, true)
    assert CommitStore.accept_fresh_reinit?()
  end
end
