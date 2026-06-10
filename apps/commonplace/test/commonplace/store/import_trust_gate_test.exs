defmodule Commonplace.Store.ImportTrustGateTest do
  @moduledoc """
  CX-tdkq.1 (R1, Gate A): `import_commit` composes `Trust.authorized?`
  into the DEFAULT validation chain — after `verify_id` (nothing about
  the commit is trustworthy before the id matches), before the namespace
  validator (no point checking content integrity of a commit we won't
  accept). Behind the workspace-local `accept_unsigned` knob; trust
  rejections are hard rejects (NOT queued for out-of-order retry — a
  trust verdict doesn't change when other commits land).
  """
  # async: false — mutates the global :trust application env.
  use ExUnit.Case, async: false

  alias Commonplace.Crypto.Signing
  alias Commonplace.Store.{Commit, CommitStore}

  setup do
    dir = Path.join(System.tmp_dir!(), "trustgate_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    name = :"trustgate_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: name})

    {pub, priv} = Signing.generate_keypair()
    identity = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    signer_id = Signing.signer_id(identity, pub)

    on_exit(fn ->
      Application.delete_env(:commonplace, :trust)
      File.rm_rf!(dir)
    end)

    %{store: name, pub: pub, priv: priv, identity: identity, signer_id: signer_id}
  end

  defp strict!(trusted \\ %{}) do
    Application.put_env(:commonplace, :trust, %{
      accept_unsigned: false,
      trusted_identities: trusted
    })
  end

  test "permissive default: unsigned commits import as before", %{store: store} do
    commit = Commit.new("doc-permissive", <<1, 2, 3>>, nil)
    assert :ok = CommitStore.import_commit(store, commit)
    assert {:ok, _} = CommitStore.get_commit(store, commit.id)
  end

  test "strict: unsigned commit is rejected and not persisted", %{store: store} do
    strict!()
    commit = Commit.new("doc-strict-unsigned", <<1, 2, 3>>, nil)

    assert {:error, {:trust_rejected, :unsigned}} =
             CommitStore.import_commit(store, commit)

    assert :none = CommitStore.get_commit(store, commit.id)
  end

  test "strict: commit signed by a pinned identity imports",
       %{store: store, pub: pub, priv: priv, identity: identity, signer_id: signer_id} do
    strict!(%{identity => Signing.encode_key(pub)})

    commit =
      Commit.new("doc-strict-signed", <<1, 2, 3>>, nil)
      |> Signing.sign_commit(priv, signer_id)

    assert :ok = CommitStore.import_commit(store, commit)
    assert {:ok, _} = CommitStore.get_commit(store, commit.id)
  end

  test "strict: commit signed by an unknown identity is rejected",
       %{store: store, priv: priv, identity: identity, signer_id: signer_id} do
    strict!()

    commit =
      Commit.new("doc-strict-unknown", <<1, 2, 3>>, nil)
      |> Signing.sign_commit(priv, signer_id)

    assert {:error, {:trust_rejected, {:untrusted_signer, ^identity}}} =
             CommitStore.import_commit(store, commit)

    assert :none = CommitStore.get_commit(store, commit.id)
  end

  test "forged signature from a pinned identity rejects even in permissive mode",
       %{store: store, priv: priv, identity: identity, signer_id: signer_id} do
    {other_pub, _} = Signing.generate_keypair()

    Application.put_env(:commonplace, :trust, %{
      accept_unsigned: true,
      trusted_identities: %{identity => Signing.encode_key(other_pub)}
    })

    commit =
      Commit.new("doc-forged", <<1, 2, 3>>, nil)
      |> Signing.sign_commit(priv, signer_id)

    assert {:error, {:trust_rejected, :invalid_signature}} =
             CommitStore.import_commit(store, commit)
  end

  test "id verification still runs before the trust gate", %{store: store} do
    strict!()
    commit = Commit.new("doc-id-first", <<1, 2, 3>>, nil)
    tampered = %{commit | update: <<9, 9, 9>>}

    # A tampered commit must fail on id_mismatch, not trust — the trust
    # gate may only read fields verify_id has authenticated.
    assert {:error, {:id_mismatch, _, _}} = CommitStore.import_commit(store, tampered)
  end

  test "trust gate runs before the namespace validator", %{store: store} do
    strict!()
    commit = Commit.new("doc-trust-first", <<1, 2, 3>>, nil)

    validator_called = :counters.new(1, [:atomics])

    validator = fn _c ->
      :counters.add(validator_called, 1, 1)
      :ok
    end

    assert {:error, {:trust_rejected, :unsigned}} =
             CommitStore.import_commit(store, commit, validator: validator)

    assert :counters.get(validator_called, 1) == 0,
           "namespace validator must not run on trust-rejected commits"
  end

  test "trust rejection is not queued for out-of-order retry", %{store: store} do
    # The R11 pending queue exists for namespace references that resolve
    # when a dependency lands. A trust rejection doesn't resolve that way;
    # the commit must stay rejected after later successful imports.
    strict!()
    rejected = Commit.new("doc-noqueue", <<1, 2, 3>>, nil)

    assert {:error, {:trust_rejected, :unsigned}} =
             CommitStore.import_commit(store, rejected)

    # Land a successful import (genesis is unsigned-exempt? no — switch to
    # permissive briefly to land it, then back to strict).
    Application.put_env(:commonplace, :trust, %{
      accept_unsigned: true,
      trusted_identities: %{}
    })

    assert :ok = CommitStore.import_commit(store, Commit.new("doc-other", <<7>>, nil))
    strict!()

    # The retry fixpoint ran on that import; the rejected commit must not
    # have been resurrected.
    assert :none = CommitStore.get_commit(store, rejected.id)
  end

  test "emits [:commonplace, :commit, :rejected, :trust] telemetry", %{store: store} do
    strict!()
    ref = make_ref()
    parent = self()

    :telemetry.attach(
      {:trust_gate_handler, ref},
      [:commonplace, :commit, :rejected, :trust],
      fn _event, meas, meta, _cfg -> send(parent, {:trust_rejected_fired, ref, meas, meta}) end,
      nil
    )

    commit = Commit.new("doc-trust-telemetry", <<1, 2, 3>>, nil)
    assert {:error, _} = CommitStore.import_commit(store, commit)

    assert_receive {:trust_rejected_fired, ^ref, _meas, meta}, 500
    assert meta.doc_uuid == "doc-trust-telemetry"
    assert meta.commit_id == commit.id
    assert meta.reason == :unsigned

    :telemetry.detach({:trust_gate_handler, ref})
  end
end
