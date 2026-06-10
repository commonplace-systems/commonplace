defmodule Commonplace.Store.OutOfOrderImportTest do
  @moduledoc """
  CX-tdkq.11 (architecture-review R11 / §6.1): out-of-order import validation.

  Namespace validation walks the *local* commit table, so a commit B that
  references identity introduced by commit A fails if B arrives before A.
  Peers were assumed to send in order; under PubSub + catch-up interleaving
  that breaks, and the failure is a rejected-but-legitimate commit.

  The fix: a rejected commit is held in a small pending queue and retried
  after each subsequent successful import — so once its dependency lands, it
  is accepted, with no special ordering required of peers.

  These tests inject a validator gated on a controllable flag to simulate
  "the dependency hasn't landed yet" deterministically, without building a
  real namespace chain.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Store.{Commit, CommitStore}

  setup do
    dir = Path.join(System.tmp_dir!(), "ooo_import_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    name = :"ooo_store_#{:rand.uniform(1_000_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: name})
    on_exit(fn -> File.rm_rf!(dir) end)
    %{store: name}
  end

  defp commit(doc_uuid, bytes), do: Commit.new(doc_uuid, bytes, nil, %{})

  test "a commit rejected for a missing dependency is queued and accepted once the dep lands",
       %{store: store} do
    {:ok, dep} = Agent.start_link(fn -> false end)
    # B validates only after its dependency has "landed" (flag flipped).
    validator = fn _c -> if Agent.get(dep, & &1), do: :ok, else: {:error, {:unknown_reference, "A"}} end

    b = commit("doc-b", <<2>>)
    a = commit("doc-a", <<1>>)

    # B arrives first; dependency unmet → rejected, and NOT yet stored.
    assert {:error, {:namespace_rejected, {:unknown_reference, "A"}}} =
             CommitStore.import_commit(store, b, validator: validator)

    assert :none = CommitStore.get_commit(store, b.id)

    # The dependency lands. Importing A (now valid) triggers a retry of the
    # pending queue, which re-validates B — now satisfied — and stores it.
    Agent.update(dep, fn _ -> true end)
    assert :ok = CommitStore.import_commit(store, a, validator: validator)

    assert {:ok, fetched} = CommitStore.get_commit(store, b.id)
    assert fetched.id == b.id
  end

  test "a still-unsatisfiable pending commit stays rejected (no spurious store)",
       %{store: store} do
    validator = fn _c -> {:error, {:unknown_reference, "never"}} end

    b = commit("doc-b", <<2>>)
    a = commit("doc-a", <<1>>)

    assert {:error, _} = CommitStore.import_commit(store, b, validator: validator)
    # A also fails the same validator → no successful import, B never retried.
    assert {:error, _} = CommitStore.import_commit(store, a, validator: validator)

    assert :none = CommitStore.get_commit(store, b.id)
  end

  test "a chain of out-of-order commits all land in one fixpoint pass when the root arrives",
       %{store: store} do
    a = commit("doc-a", <<1>>)
    b = commit("doc-b", <<2>>)
    c = commit("doc-c", <<3>>)

    # A real dependency: a commit validates iff its named dependency commit is
    # already stored. (Safe to query the store from inside validation — R4a
    # made get_commit/2 a caller-side read, so there's no GenServer.call back
    # into the store mid-handle_call, hence no deadlock.)
    needs = fn dep_id ->
      fn _c ->
        if match?({:ok, _}, CommitStore.get_commit(store, dep_id)),
          do: :ok,
          else: {:error, {:unknown_reference, dep_id}}
      end
    end

    # C needs B, B needs A; they arrive before their dependencies.
    assert {:error, _} = CommitStore.import_commit(store, c, validator: needs.(b.id))
    assert {:error, _} = CommitStore.import_commit(store, b, validator: needs.(a.id))
    assert :none = CommitStore.get_commit(store, c.id)
    assert :none = CommitStore.get_commit(store, b.id)

    # A lands (no dependency). Its retry cascades through the fixpoint: B's dep
    # (A) is now stored → B stored → the pass re-runs → C's dep (B) is now
    # stored → C stored. One import, whole chain.
    assert :ok = CommitStore.import_commit(store, a)
    assert {:ok, _} = CommitStore.get_commit(store, b.id)
    assert {:ok, _} = CommitStore.get_commit(store, c.id)
  end
end
