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

  # R4c carve-out: the R11 pending-imports queue now lives in
  # Commonplace.Store.PendingImports, a separate process — so this needs
  # the full trio (a bare CommitStore has no companion by default, meaning
  # rejected commits would never be held at all). Retries are triggered by
  # async casts (CommitStore's notify_landed / TrustSideStore's
  # notify_capability), so tests that used to assert synchronously right
  # after the triggering call now poll via `wait_until/2`.
  setup do
    dir = Path.join(System.tmp_dir!(), "ooo_import_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    n = :rand.uniform(1_000_000_000)
    name = :"ooo_store_#{n}"

    start_supervised!({
      Commonplace.Store.Supervisor,
      # Fast test-only sweep so the "lost cast" backstop tests elsewhere
      # in this suite don't have to wait the production 45s default; kept
      # short here too so any missed cast in THIS file's tests still
      # self-heals quickly instead of hanging on wait_until's timeout.
      data_dir: dir,
      name: :"ooo_sup_#{n}",
      commit_store_name: name,
      trust_side_store_name: :"ooo_tss_#{n}",
      pending_imports_name: :"ooo_pi_#{n}",
      pending_imports_sweep_interval_ms: 200
    })

    on_exit(fn -> File.rm_rf!(dir) end)
    %{store: name}
  end

  defp commit(doc_uuid, bytes), do: Commit.new(doc_uuid, bytes, nil, %{})

  # Poll `fun` (returns boolean) until it's true or `timeout_ms` elapses.
  defp wait_until(fun, timeout_ms \\ 1000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("condition not met within timeout")
      else
        Process.sleep(10)
        do_wait_until(fun, deadline)
      end
    end
  end

  test "a commit rejected for a missing dependency is queued and accepted once the dep lands",
       %{store: store} do
    {:ok, dep} = Agent.start_link(fn -> false end)
    # B validates only after its dependency has "landed" (flag flipped).
    validator = fn _c ->
      if Agent.get(dep, & &1), do: :ok, else: {:error, {:unknown_reference, "A"}}
    end

    b = commit("doc-b", <<2>>)
    a = commit("doc-a", <<1>>)

    # B arrives first; dependency unmet → rejected, and NOT yet stored.
    assert {:error, {:namespace_rejected, {:unknown_reference, "A"}}} =
             CommitStore.import_commit(store, b, validator: validator)

    assert :none = CommitStore.get_commit(store, b.id)

    # The dependency lands. Importing A (now valid) triggers an async
    # retry of the pending queue (PendingImports.notify_landed, a cast),
    # which re-validates B — now satisfied — and stores it.
    Agent.update(dep, fn _ -> true end)
    assert :ok = CommitStore.import_commit(store, a, validator: validator)

    wait_until(fn -> match?({:ok, _}, CommitStore.get_commit(store, b.id)) end)
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
    # stored → C stored. One import, whole chain — asynchronously (each hop
    # is a cast bouncing through PendingImports' mailbox), so poll for it.
    assert :ok = CommitStore.import_commit(store, a)
    wait_until(fn -> match?({:ok, _}, CommitStore.get_commit(store, b.id)) end)
    wait_until(fn -> match?({:ok, _}, CommitStore.get_commit(store, c.id)) end)
  end
end
