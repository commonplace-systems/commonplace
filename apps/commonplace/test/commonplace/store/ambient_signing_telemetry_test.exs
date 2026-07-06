defmodule Commonplace.Store.AmbientSigningTelemetryTest do
  @moduledoc """
  CX-hoj: identity flows from the authenticated ingress to every effect;
  it is never re-asserted mid-path. The global SecretStore
  (`signing_key:default`) slot is AMBIENT identity — a fallback that
  signs a commit with whatever key happens to be loaded in the process,
  regardless of which caller/session actually produced the update.

  This does NOT remove the ambient fallback (a later bead, once the
  demotion worklist below is empty) — it makes every remaining
  un-threaded caller ENUMERABLE via telemetry:

    * `[:commonplace, :commit, :ambient_signed]` fires whenever the nil
      `signing_context` branch of `maybe_sign_commit/2` actually signs a
      commit with the global key (metadata: `doc_uuid`, `commit_id`).
    * The same event (with `via: :cas`) fires — plus a `Logger.warning`
      — if a non-system-kind commit (kind not in `[:snapshot, :merge]`)
      reaches the bare `maybe_sign_commit/1` calls on the CAS write
      paths, which are meant only for node-signed system commits.

  Also pins the CX-tdkq.32/CX-hoj regression: `signing_context: :unsigned`
  must NEVER be overridden by the global key, even when one is loaded —
  this is the shape MCP write-MVP callers rely on.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Store.{Commit, CommitStore, SecretStore}
  alias Commonplace.Crypto.Signing
  alias Yelixer.{Doc, Encoding}
  alias Yelixer.Types.Text

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_ambient_sign_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    old = Application.get_env(:commonplace, :data_dir)
    Application.put_env(:commonplace, :data_dir, dir)

    name = :"ambient_sign_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: name})

    on_exit(fn ->
      if old, do: Application.put_env(:commonplace, :data_dir, old),
        else: Application.delete_env(:commonplace, :data_dir)

      File.rm_rf!(dir)
    end)

    {global_pub, global_priv} = Signing.generate_keypair()
    SecretStore.set("signing_key:default", Base.encode64(global_priv))
    SecretStore.set("signing_pub:default", Base.encode64(global_pub))
    SecretStore.set("signing_identity", "human-uuid")

    on_exit(fn ->
      SecretStore.delete("signing_key:default")
      SecretStore.delete("signing_pub:default")
      SecretStore.delete("signing_identity")
    end)

    %{store: name, dir: dir, global_pub: global_pub}
  end

  defp text_doc(s) do
    doc = Doc.new(client_id: 1)
    {doc, _} = Doc.get_or_create_type(doc, "t", :text)
    doc = Text.insert(doc, "t", 0, s)
    Encoding.encode_update(doc)
  end

  defp attach(event) do
    test_pid = self()
    ref = make_ref()

    :telemetry.attach(
      "#{inspect(event)}-#{inspect(ref)}",
      event,
      fn ^event, measurements, metadata, _config ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach("#{inspect(event)}-#{inspect(ref)}") end)
  end

  test "ambient_signed telemetry fires when a nil-context non-system commit is signed via the global key",
       %{store: store} do
    attach([:commonplace, :commit, :ambient_signed])

    uuid = "ambient-#{:rand.uniform(1_000_000)}"
    commit = CommitStore.create_commit(store, uuid, text_doc("plain"), nil, %{kind: :regular})

    # Global key IS loaded, so the nil-context fallback signs it (legacy
    # behavior, unchanged) — but now it's observable.
    assert commit.signature != nil

    assert_receive {:telemetry, [:commonplace, :commit, :ambient_signed], _meas, metadata}
    assert metadata.doc_uuid == uuid
    assert metadata.commit_id == commit.id
  end

  test "no ambient signing regression: signing_context: :unsigned always yields an unsigned commit, even with a global key loaded",
       %{store: store} do
    attach([:commonplace, :commit, :ambient_signed])

    uuid = "unsigned-#{:rand.uniform(1_000_000)}"

    commit =
      CommitStore.create_commit(store, uuid, text_doc("mvp"), nil, %{kind: :regular},
        signing_context: :unsigned
      )

    assert commit.signature == nil
    assert commit.signer_id == nil

    # Scope the refute to THIS test's doc: the telemetry event is
    # node-global, and under a concurrent full-suite run another test's
    # ambient-signed commit otherwise lands in this mailbox and trips
    # the refute (observed as a load-only CI flake, run 28800700931 —
    # same class as local_write_gate_test's pin-2 fix).
    refute_receive {:telemetry, [:commonplace, :commit, :ambient_signed], _, %{doc_uuid: ^uuid}},
                   100
  end

  test "a non-system-kind commit reaching write_prebuilt_commit_cas ambient-signs with via: :cas telemetry",
       %{store: store} do
    attach([:commonplace, :commit, :ambient_signed])

    uuid = "cas-#{:rand.uniform(1_000_000)}"

    # A non-system kind (:regular) prebuilt commit — CAS paths are meant
    # only for node-signed system kinds (:snapshot / :merge) today.
    # No prior commit for this uuid, so :latest is nil — parent_id nil
    # matches the CAS check.
    commit = Commit.new(uuid, text_doc("via-cas"), nil, %{kind: :regular})

    assert {:ok, stored} = CommitStore.write_prebuilt_commit_cas(store, commit)

    assert_receive {:telemetry, [:commonplace, :commit, :ambient_signed], _meas, metadata}
    assert metadata.via == :cas
    assert metadata.doc_uuid == uuid
    assert metadata.commit_id == stored.id
  end
end
