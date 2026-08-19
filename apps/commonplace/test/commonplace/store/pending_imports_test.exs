defmodule Commonplace.Store.PendingImportsTest do
  @moduledoc """
  R4c carve-out: the R11 out-of-order-import retry queue, extracted out of
  `Commonplace.Store.CommitStore` into its own process
  (`Commonplace.Store.PendingImports`). These tests pin the properties the
  carve-out is required to preserve (and make more explicit):

    * Fixpoint retry — a held commit lands once its blocker resolves,
      whether the blocker is a missing namespace dependency or a missing
      capability cert.
    * NO-BYPASS — retries re-run the FULL gate pipeline, so a commit that
      becomes invalid for an UNRELATED reason by retry time is rejected,
      not silently landed.
    * The periodic sweep is a genuine liveness backstop, independent of any
      specific notification firing.
    * The bounded queue cap (1024) is preserved.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Crypto.{Signing, SigningContext}
  alias Commonplace.Store.{Commit, CommitStore, PendingImports}
  alias Commonplace.Trust.Capability

  defp start_trio(opts \\ []) do
    n = :rand.uniform(1_000_000_000)
    dir = Path.join(System.tmp_dir!(), "pending_imports_#{n}")
    File.mkdir_p!(dir)

    commit_store = :"pi_test_store_#{n}"
    trust_side_store = :"pi_test_tss_#{n}"
    pending_imports = :"pi_test_pi_#{n}"

    sup_opts =
      [
        data_dir: dir,
        name: :"pi_test_sup_#{n}",
        commit_store_name: commit_store,
        trust_side_store_name: trust_side_store,
        pending_imports_name: pending_imports
      ] ++ opts

    start_supervised!({Commonplace.Store.Supervisor, sup_opts})

    on_exit(fn -> File.rm_rf!(dir) end)

    %{store: commit_store, trust_side_store: trust_side_store, pending_imports: pending_imports}
  end

  defp commit(doc_uuid, bytes), do: Commit.new(doc_uuid, bytes, nil, %{})

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

  describe "fixpoint retry (namespace dependency)" do
    test "a commit held for a missing namespace dependency lands once the dependency lands" do
      %{store: store} = start_trio()

      {:ok, dep_flag} = Agent.start_link(fn -> false end)

      validator = fn _c ->
        if Agent.get(dep_flag, & &1), do: :ok, else: {:error, {:unknown_reference, "dep"}}
      end

      dependent = commit("doc-dependent", <<2>>)
      dependency = commit("doc-dependency", <<1>>)

      assert {:error, {:namespace_rejected, _}} =
               CommitStore.import_commit(store, dependent, validator: validator)

      assert :none = CommitStore.get_commit(store, dependent.id)

      Agent.update(dep_flag, fn _ -> true end)
      assert :ok = CommitStore.import_commit(store, dependency, validator: validator)

      wait_until(fn -> match?({:ok, _}, CommitStore.get_commit(store, dependent.id)) end)
      assert {:ok, fetched} = CommitStore.get_commit(store, dependent.id)
      assert fetched.id == dependent.id
    end
  end

  describe "fixpoint retry (capability-gated)" do
    test "a commit held for :awaiting_capability lands once the cert is stored" do
      %{store: store} = start_trio()

      {root_pub, root_priv} = Signing.generate_keypair()

      root_ctx = %SigningContext{
        identity_uuid: "root",
        private_key: root_priv,
        public_key: root_pub
      }

      {alice_pub, alice_priv} = Signing.generate_keypair()
      alice_signer = Signing.signer_id("alice", alice_pub)

      Application.put_env(:commonplace, :trust, %{
        accept_unsigned: false,
        trusted_identities: %{"root" => Signing.encode_key(root_pub)}
      })

      on_exit(fn -> Application.delete_env(:commonplace, :trust) end)

      {:ok, leaf} =
        Capability.issue(root_ctx, {"alice", alice_pub}, %{
          verbs: [:write],
          scope: {:docs, ["doc-cap"]},
          caveats: %{not_before: nil, not_after: nil}
        })

      commit =
        Commit.new("doc-cap", "payload", nil, %{kind: :regular, capability_proof: leaf.id})
        |> Signing.sign_commit(alice_priv, alice_signer)

      assert {:error, {:trust_rejected, :awaiting_capability}} =
               CommitStore.import_commit(store, commit, validator: fn _ -> :ok end)

      assert :none = CommitStore.get_commit(store, commit.id)

      :ok = CommitStore.store_capability(store, leaf)

      wait_until(fn -> match?({:ok, _}, CommitStore.get_commit(store, commit.id)) end)
    end
  end

  describe "NO-BYPASS: retries re-run the full gate pipeline" do
    test "a commit held for a missing capability, but that has since become invalid for an UNRELATED reason, is rejected on retry — not landed" do
      %{store: store} = start_trio()

      {root_pub, root_priv} = Signing.generate_keypair()

      root_ctx = %SigningContext{
        identity_uuid: "root",
        private_key: root_priv,
        public_key: root_pub
      }

      {alice_pub, alice_priv} = Signing.generate_keypair()
      alice_signer = Signing.signer_id("alice", alice_pub)

      # Strict trust config, root pinned — this is what makes the commit
      # deferred with :awaiting_capability on first arrival (a cert exists
      # in principle but hasn't been stored yet).
      Application.put_env(:commonplace, :trust, %{
        accept_unsigned: false,
        trusted_identities: %{"root" => Signing.encode_key(root_pub)}
      })

      on_exit(fn -> Application.delete_env(:commonplace, :trust) end)

      {:ok, leaf} =
        Capability.issue(root_ctx, {"alice", alice_pub}, %{
          verbs: [:write],
          scope: {:docs, ["doc-nobypass"]},
          caveats: %{not_before: nil, not_after: nil}
        })

      commit =
        Commit.new("doc-nobypass", "payload", nil, %{kind: :regular, capability_proof: leaf.id})
        |> Signing.sign_commit(alice_priv, alice_signer)

      assert {:error, {:trust_rejected, :awaiting_capability}} =
               CommitStore.import_commit(store, commit, validator: fn _ -> :ok end)

      assert :none = CommitStore.get_commit(store, commit.id)

      # Between enqueue and retry, trust config changes underneath it: root
      # is NO LONGER pinned — the commit is now trust-rejected for a
      # DIFFERENT, unrelated reason (:untrusted_signer), not merely still
      # awaiting the same cert.
      Application.put_env(:commonplace, :trust, %{
        accept_unsigned: false,
        trusted_identities: %{}
      })

      # Storing the cert still fires the notify_capability retry — but the
      # FULL pipeline (trust gate included) re-runs, and the trust gate now
      # rejects for a reason that has nothing to do with the cert.
      :ok = CommitStore.store_capability(store, leaf)

      # Give the async retry a moment to run, then assert it did NOT land.
      Process.sleep(200)
      assert :none = CommitStore.get_commit(store, commit.id)
    end
  end

  describe "lost-cast backstop (periodic sweep)" do
    test "a held commit lands via the periodic sweep even when the triggering notification never fires" do
      %{store: store, trust_side_store: tss} =
        start_trio(pending_imports_sweep_interval_ms: 100)

      {:ok, dep_flag} = Agent.start_link(fn -> false end)

      validator = fn _c ->
        if Agent.get(dep_flag, & &1), do: :ok, else: {:error, {:unknown_reference, "dep"}}
      end

      held = commit("doc-sweep-held", <<9>>)

      assert {:error, {:namespace_rejected, _}} =
               CommitStore.import_commit(store, held, validator: validator)

      assert :none = CommitStore.get_commit(store, held.id)

      # Flip the flag directly (bypassing any CommitStore/TrustSideStore
      # cast entirely) — no notify_landed / notify_capability cast is ever
      # sent for this change. Only the periodic sweep can discover it.
      Agent.update(dep_flag, fn _ -> true end)

      # `tss` unused by this path but kept in context to document that no
      # capability-side notification is involved in this scenario either.
      _ = tss

      wait_until(fn -> match?({:ok, _}, CommitStore.get_commit(store, held.id)) end, 2000)
    end
  end

  describe "bounded queue cap (1024)" do
    test "enqueuing past the cap does not grow the queue unboundedly" do
      %{store: store, pending_imports: pending_imports} = start_trio()

      validator = fn _c -> {:error, {:unknown_reference, "never-lands"}} end

      for i <- 1..1100 do
        c = commit("doc-cap-#{i}", <<i::16>>)
        assert {:error, _} = CommitStore.import_commit(store, c, validator: validator)
      end

      # Give any async enqueue casts a moment to be processed.
      wait_until(fn -> PendingImports.pending_count(pending_imports) > 0 end)
      count = PendingImports.pending_count(pending_imports)
      assert count <= 1024
    end
  end
end
