defmodule Commonplace.Store.CapabilityEnvelopeTest do
  @moduledoc """
  CX-tdkq.22e (phase 3): the capability envelope at Gate A. A commit
  carries `metadata.capability_proof: <leaf CID>` (binds into the content
  address — tamper-evident). When the authorizing cert isn't present yet,
  the import is DEFERRED via the R11 pending queue (`:awaiting_capability`),
  not hard-rejected — and lands once the cert arrives. Crucially, the
  retry re-runs the FULL trust check (cert path included), so a deferred
  commit never bypasses capability verification.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Crypto.{Signing, SigningContext}
  alias Commonplace.Store.{Commit, CommitStore}
  alias Commonplace.Trust.Capability

  # R4c carve-out: store_capability/2 now delegates to TrustSideStore, and
  # the retry it triggers (PendingImports.notify_capability, a cast) is
  # ASYNCHRONOUS — landing is no longer guaranteed by the time
  # `store_capability/2` returns. Tests that assert on the retry's effect
  # poll via `wait_until/2` instead of asserting immediately.
  setup do
    dir = Path.join(System.tmp_dir!(), "capenv_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    n = :rand.uniform(1_000_000)
    name = :"capenv_store_#{n}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: dir,
       name: :"capenv_sup_#{n}",
       commit_store_name: name,
       trust_side_store_name: :"capenv_tss_#{n}",
       pending_imports_name: :"capenv_pi_#{n}"}
    )

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

    {:ok, leaf} =
      Capability.issue(root_ctx, {"alice", alice_pub}, %{
        verbs: [:write],
        scope: {:docs, ["doc-x"]},
        caveats: %{not_before: nil, not_after: nil}
      })

    commit =
      Commit.new("doc-x", "payload", nil, %{kind: :regular, capability_proof: leaf.id})
      |> Signing.sign_commit(alice_priv, alice_signer)

    on_exit(fn -> Application.delete_env(:commonplace, :trust) end)
    %{store: name, leaf: leaf, commit: commit}
  end

  test "a commit whose cert is absent is DEFERRED, not hard-rejected", %{
    store: store,
    commit: commit
  } do
    assert {:error, {:trust_rejected, :awaiting_capability}} =
             CommitStore.import_commit(store, commit, validator: fn _ -> :ok end)

    # Not stored — held pending.
    assert :none = CommitStore.get_commit(store, commit.id)
  end

  test "deferred commit lands once its cert is stored (retry re-runs the cert check)",
       %{store: store, leaf: leaf, commit: commit} do
    assert {:error, {:trust_rejected, :awaiting_capability}} =
             CommitStore.import_commit(store, commit, validator: fn _ -> :ok end)

    assert :none = CommitStore.get_commit(store, commit.id)

    # The cert arrives — which retries the pending queue. The retry itself
    # is an async cast (PendingImports.notify_capability), so poll for it.
    :ok = CommitStore.store_capability(store, leaf)

    wait_until(fn -> match?({:ok, _}, CommitStore.get_commit(store, commit.id)) end)
  end

  test "a commit with a present, valid cert imports straight away",
       %{store: store, leaf: leaf, commit: commit} do
    :ok = CommitStore.store_capability(store, leaf)
    assert :ok = CommitStore.import_commit(store, commit, validator: fn _ -> :ok end)
    assert {:ok, _} = CommitStore.get_commit(store, commit.id)
  end

  test "capability_proof in metadata binds into the content address (tamper-evident)",
       %{commit: commit} do
    tampered = %{commit | metadata: %{kind: :regular, capability_proof: <<0::256>>}}
    assert {:error, {:id_mismatch, _, _}} = Commit.verify_id(tampered)
  end

  test "a hard-untrusted commit (no cert) is NOT queued — stays rejected", %{store: store} do
    {_pub, priv} = Signing.generate_keypair()
    stranger = Signing.signer_id("stranger", elem(Signing.generate_keypair(), 0))
    commit = Commit.new("doc-x", "p", nil) |> Signing.sign_commit(priv, stranger)

    assert {:error, {:trust_rejected, {:untrusted_signer, "stranger"}}} =
             CommitStore.import_commit(store, commit, validator: fn _ -> :ok end)

    # A later successful import must not resurrect it.
    :ok = CommitStore.store_capability(store, %Commonplace.Trust.Capability{id: <<1::256>>})
    assert :none = CommitStore.get_commit(store, commit.id)
  end

  # Poll `fun` (returns boolean) until it's true or `timeout_ms` elapses.
  # The R4c carve-out made PendingImports' retry notifications async casts,
  # so a handful of tests here need to wait for a retry to land rather than
  # asserting immediately after the triggering call returns.
  defp wait_until(fun, timeout_ms \\ 500) do
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
