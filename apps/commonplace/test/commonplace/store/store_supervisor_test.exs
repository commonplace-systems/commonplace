defmodule Commonplace.Store.StoreSupervisorTest do
  @moduledoc """
  R4c carve-out: `Commonplace.Store.Supervisor` supervises the CommitStore
  trio with `:rest_for_one` specifically so a CommitStore restart also
  restarts its TrustSideStore/PendingImports companions, forcing them to
  re-resolve their handle/reference rather than keep running against
  whatever the OLD CommitStore instance handed them at their own `init/1`.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Crypto.{Signing, SigningContext}
  alias Commonplace.Store.{CommitStore, Supervisor, TrustSideStore}
  alias Commonplace.Trust.Capability

  setup do
    n = :rand.uniform(1_000_000_000)
    dir = Path.join(System.tmp_dir!(), "store_sup_#{n}")
    File.mkdir_p!(dir)

    commit_store = :"store_sup_cs_#{n}"
    trust_side_store = :"store_sup_tss_#{n}"
    pending_imports = :"store_sup_pi_#{n}"
    sup_name = :"store_sup_sup_#{n}"

    sup_pid =
      start_supervised!(
        {Supervisor,
         data_dir: dir,
         name: sup_name,
         commit_store_name: commit_store,
         trust_side_store_name: trust_side_store,
         pending_imports_name: pending_imports}
      )

    on_exit(fn -> File.rm_rf!(dir) end)

    %{
      sup: sup_name,
      sup_pid: sup_pid,
      commit_store: commit_store,
      trust_side_store: trust_side_store,
      pending_imports: pending_imports
    }
  end

  defp issue_cap do
    {root_pub, root_priv} = Signing.generate_keypair()

    root_ctx = %SigningContext{
      identity_uuid: "root",
      private_key: root_priv,
      public_key: root_pub
    }

    {alice_pub, _} = Signing.generate_keypair()

    {:ok, cap} =
      Capability.issue(root_ctx, {"alice", alice_pub}, %{
        verbs: [:write],
        scope: {:docs, ["d1"]},
        caveats: %{not_before: nil, not_after: nil}
      })

    cap
  end

  test ":rest_for_one — killing CommitStore restarts TrustSideStore and PendingImports too",
       %{
         sup: sup,
         commit_store: commit_store,
         trust_side_store: trust_side_store,
         pending_imports: pending_imports
       } do
    cs_pid_before = Process.whereis(commit_store)
    tss_pid_before = Process.whereis(trust_side_store)
    pi_pid_before = Process.whereis(pending_imports)

    assert is_pid(cs_pid_before)
    assert is_pid(tss_pid_before)
    assert is_pid(pi_pid_before)

    # Kill CommitStore hard. Under :rest_for_one this must take down (and
    # the supervisor must restart) TrustSideStore and PendingImports too —
    # NOT just CommitStore in isolation.
    ref_cs = Process.monitor(cs_pid_before)
    ref_tss = Process.monitor(tss_pid_before)
    ref_pi = Process.monitor(pi_pid_before)
    Process.exit(cs_pid_before, :kill)

    assert_receive {:DOWN, ^ref_cs, :process, ^cs_pid_before, _}, 2000
    assert_receive {:DOWN, ^ref_tss, :process, ^tss_pid_before, _}, 2000
    assert_receive {:DOWN, ^ref_pi, :process, ^pi_pid_before, _}, 2000

    # Wait for the supervisor to bring the trio back up under the same
    # registered names.
    wait_until(fn ->
      is_pid(Process.whereis(commit_store)) and Process.whereis(commit_store) != cs_pid_before
    end)

    wait_until(fn ->
      is_pid(Process.whereis(trust_side_store)) and
        Process.whereis(trust_side_store) != tss_pid_before
    end)

    wait_until(fn ->
      is_pid(Process.whereis(pending_imports)) and
        Process.whereis(pending_imports) != pi_pid_before
    end)

    # All still under the same Supervisor.
    assert %{active: 3} = Elixir.Supervisor.count_children(sup)

    # Capability store+read still works post-restart, and reads don't
    # crash referencing a stale handle — TrustSideStore re-resolved
    # CommitStore.db_handle/1 in its OWN fresh init/1.
    cap = issue_cap()
    assert :ok = CommitStore.store_capability(commit_store, cap)
    assert {:ok, fetched} = CommitStore.get_capability(commit_store, cap.id)
    assert fetched.id == cap.id

    # And directly through TrustSideStore too.
    assert {:ok, fetched2} = TrustSideStore.get_capability(trust_side_store, cap.id)
    assert fetched2.id == cap.id
  end

  defp wait_until(fun, timeout_ms \\ 2000) do
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
end
