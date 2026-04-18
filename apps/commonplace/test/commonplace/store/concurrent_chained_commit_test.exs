defmodule Commonplace.Store.ConcurrentChainedCommitTest do
  @moduledoc """
  CX-l7j: concurrent `create_chained_commit/3` calls on the same
  `doc_uuid` must produce a LINEAR chain, not siblings.

  Previously the public `create_chained_commit/3` made two separate
  GenServer calls — `latest_commit/2` to read the parent, then
  `create_commit/4` to write with that parent. Two processes could
  interleave: both read the same `:latest`, both write chained to
  that same parent, result: two siblings claiming the same parent.
  The second write's `:latest` update wins; the first write is
  silently lost at the chain-walk layer.

  The fix atomicizes the read-latest + write-commit pair inside a
  single `handle_call({:create_chained_commit, ...})` so the
  GenServer mailbox serializes concurrent writers per-UUID.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Store.{CommitStore, Commit}

  setup do
    dir = Path.join(System.tmp_dir!(), "cxl7j_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    name = :"cxl7j_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: name})
    on_exit(fn -> File.rm_rf!(dir) end)
    %{store: name}
  end

  # Walks parent chain from head, stopping at (and excluding) the
  # auto-stamped `:genesis` commit so assertions count only the
  # caller-written commits.
  defp walk_chain(store, from_id) do
    walk_chain(store, from_id, [])
  end

  defp walk_chain(_store, nil, acc), do: Enum.reverse(acc)

  defp walk_chain(store, id, acc) do
    case CommitStore.get_commit(store, id) do
      {:ok, %{metadata: %{kind: :genesis}}} -> Enum.reverse(acc)
      {:ok, commit} -> walk_chain(store, commit.parent_id, [commit.id | acc])
      :none -> Enum.reverse(acc)
    end
  end

  describe "create_chained_commit/3 atomicity" do
    test "sequential calls chain linearly (baseline)", %{store: store} do
      c1 = CommitStore.create_chained_commit(store, "seq", <<1>>, %{})
      c2 = CommitStore.create_chained_commit(store, "seq", <<2>>, %{})
      c3 = CommitStore.create_chained_commit(store, "seq", <<3>>, %{})

      assert c2.parent_id == c1.id
      assert c3.parent_id == c2.id

      {:ok, latest} = CommitStore.latest_commit(store, "seq")
      assert latest.id == c3.id
    end

    test "concurrent calls from N processes chain linearly, no siblings",
         %{store: store} do
      uuid = "concurrent"
      n = 50
      parent = self()

      tasks =
        for i <- 1..n do
          Task.async(fn ->
            commit = CommitStore.create_chained_commit(store, uuid, <<i::32>>, %{})
            send(parent, {:written, commit.id})
            commit
          end)
        end

      commits = Task.await_many(tasks, 10_000)

      # All N commits should be distinct.
      ids = MapSet.new(commits, & &1.id)
      assert MapSet.size(ids) == n, "duplicate commit ids suggest lost writes"

      # The chain from :latest must include ALL N commits. Under the
      # old (buggy) code, some concurrent writes end up as siblings
      # unreachable from :latest.
      {:ok, head} = CommitStore.latest_commit(store, uuid)
      chain_ids = walk_chain(store, head.id) |> MapSet.new()

      missing = MapSet.difference(ids, chain_ids)

      assert MapSet.size(missing) == 0,
             "#{MapSet.size(missing)} concurrent writes are siblings unreachable from :latest"
    end

    test "concurrent calls produce a chain whose length equals the number of writes",
         %{store: store} do
      uuid = "chain-length"
      n = 20

      tasks =
        for i <- 1..n do
          Task.async(fn ->
            CommitStore.create_chained_commit(store, uuid, <<i::32>>, %{})
          end)
        end

      _commits = Task.await_many(tasks, 10_000)

      {:ok, head} = CommitStore.latest_commit(store, uuid)
      chain = walk_chain(store, head.id)

      assert length(chain) == n,
             "expected #{n}-long chain, got #{length(chain)} — sibling collapse lost writes"
    end

    test "every commit in the resulting chain has a unique parent", %{store: store} do
      uuid = "unique-parents"
      n = 30

      tasks =
        for i <- 1..n do
          Task.async(fn ->
            CommitStore.create_chained_commit(store, uuid, <<i::32>>, %{})
          end)
        end

      _ = Task.await_many(tasks, 10_000)

      {:ok, head} = CommitStore.latest_commit(store, uuid)
      chain = walk_chain(store, head.id)

      # Each commit.parent_id should be the previous commit.id (strict
      # linear chain — no duplicate parents means no siblings).
      parents =
        chain
        |> Enum.map(fn id ->
          {:ok, c} = CommitStore.get_commit(store, id)
          c.parent_id
        end)

      assert Enum.uniq(parents) == parents,
             "duplicate parent_ids mean two commits share a parent — sibling bug"
    end

    test "create_chained_commit/3 on a different UUID does not serialize",
         %{store: store} do
      # Sanity: two distinct UUIDs' writers do not contend with each other.
      # (Can't easily assert non-blocking without timing flakiness, so just
      # verify both UUIDs end up with their own chain intact.)
      n = 10

      tasks_a =
        for i <- 1..n do
          Task.async(fn ->
            CommitStore.create_chained_commit(store, "uuid-a", <<i::32>>, %{})
          end)
        end

      tasks_b =
        for i <- 1..n do
          Task.async(fn ->
            CommitStore.create_chained_commit(store, "uuid-b", <<i::32>>, %{})
          end)
        end

      _ = Task.await_many(tasks_a ++ tasks_b, 10_000)

      {:ok, head_a} = CommitStore.latest_commit(store, "uuid-a")
      {:ok, head_b} = CommitStore.latest_commit(store, "uuid-b")

      chain_a = walk_chain(store, head_a.id)
      chain_b = walk_chain(store, head_b.id)

      assert length(chain_a) == n
      assert length(chain_b) == n
      # No cross-contamination.
      assert MapSet.disjoint?(MapSet.new(chain_a), MapSet.new(chain_b))
    end

    test "ids are content-addressed and stay verifiable after concurrent writes",
         %{store: store} do
      # CX-gwz: every commit stored must pass Commit.verify_id/1 — the
      # atomic write path still produces legitimate content-addressed
      # commits, not shortcuts.
      uuid = "ids-verified"
      n = 10

      tasks =
        for i <- 1..n do
          Task.async(fn ->
            CommitStore.create_chained_commit(store, uuid, <<i::32>>, %{})
          end)
        end

      commits = Task.await_many(tasks, 10_000)

      for commit <- commits do
        assert :ok = Commit.verify_id(commit)
      end
    end
  end
end
