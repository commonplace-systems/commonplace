defmodule Commonplace.MUD.CxSfj8SessionProvisionTest do
  @moduledoc """
  CX-sfj8 / CX-jicn — the session-identity chokepoint (plan #7808/#7812).

  Under :enforce, a session's presence add/remove needs a node-signed
  `{:presence, id}` cert. The fix makes PlayerSession's bootstrap the SINGLE
  guarantee point: resolve a durable identity first, else provision a
  NODE-GENERATED ephemeral keypair + presence cert — so EVERY session signs its
  own presence (appear + quit-retract), no ghost, no trust-flood.

  Session-lifecycle pins (the Presence-carve pins — least-privilege + cross-session
  spoof + fail-closed — are in CxSfj8PresenceCertReproTest):
    * PIN 1 — a fresh NO-IDENTITY session under enforce APPEARS (presence adds)
      AND retracts on quit (no ghost).
    * PIN 5 (CRUX) — a session supplying a client-claimed player_identity_uuid
      the node holds NO key for does NOT borrow that identity; it falls to a
      server-generated ephemeral one (durable identity is server-resolved, never
      fabricated from a bare claim).
  """
  use ExUnit.Case, async: false

  alias Commonplace.Crypto.NodeIdentity
  alias Commonplace.MUD.{PlayerSession, Schemas, SignedWrite}
  alias Commonplace.MUD.Schemas.Room
  alias Commonplace.Presence
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.Schema
  alias Yelixer.Encoding

  setup do
    Application.ensure_all_started(:phoenix_pubsub)

    case Phoenix.PubSub.Supervisor.start_link(name: Commonplace.PubSub) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    dir = Path.join(System.tmp_dir!(), "cp_sfj8s_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    n = :rand.uniform(1_000_000_000)
    store = :"sfj8s_store_#{n}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: dir,
       name: :"sfj8s_sup_#{n}",
       commit_store_name: store,
       trust_side_store_name: :"sfj8s_tss_#{n}",
       pending_imports_name: :"sfj8s_pi_#{n}"}
    )

    old_data_dir = Application.get_env(:commonplace, :data_dir)
    old_trust = Application.get_env(:commonplace, :trust)
    old_knob = Application.get_env(:commonplace, :local_write_gate)
    Application.put_env(:commonplace, :data_dir, dir)
    Application.put_env(:commonplace, :trust, %{accept_unsigned: false, trusted_identities: %{}})
    Application.put_env(:commonplace, :local_write_gate, :enforce)

    on_exit(fn ->
      restore = fn key, v ->
        if is_nil(v),
          do: Application.delete_env(:commonplace, key),
          else: Application.put_env(:commonplace, key, v)
      end

      restore.(:data_dir, old_data_dir)
      restore.(:trust, old_trust)
      restore.(:local_write_gate, old_knob)
      File.rm_rf!(dir)
    end)

    {:ok, node_ctx} = NodeIdentity.signing_context()

    # A world root + a node-signed "start" room (ensure_start_room creates
    # UNSIGNED, denied under enforce — so it must already exist node-owned).
    {:ok, root} = Schemas.create_dir_with_meta(nil, nil, store, signing_context: node_ctx)

    {:ok, start} =
      Schemas.create_dir_with_meta(
        Schemas.room_filename(),
        Schemas.encode_room(%Room{name: "The Start Room", description: "a plain room"}),
        store,
        signing_context: node_ctx
      )

    {:ok, root_schema} = Schemas.load_dir_schema(root, store)
    root_schema = Schema.add_directory(root_schema, "start", start)
    {metadata, commit_opts} = SignedWrite.opts_for(root, store: store, signing_context: node_ctx)

    _ =
      CommitStoreClient.create_chained_commit(
        store,
        root,
        Encoding.encode_update(root_schema),
        metadata,
        commit_opts
      )

    %{store: store, root: root, start: start}
  end

  defp start_session(opts) do
    parent = self()
    {:ok, session} = PlayerSession.start_link(Keyword.put_new(opts, :output_fn, fn _ -> :ok end))
    _ = parent
    session
  end

  defp presence_in_room?(room, fname, store) do
    {:ok, schema} = Schemas.load_dir_schema(room, store)
    match?({:ok, _}, Schema.get_entry(schema, fname))
  end

  test "PIN 1: a fresh no-identity session under enforce APPEARS and retracts on quit (no ghost)",
       %{store: store, root: root, start: start} do
    session = start_session(player_name: "wanderer", root_uuid: root, store: store)

    fname = Presence.filename("wanderer", :usr)
    # It got a node-generated ephemeral identity + presence cert → it can write
    # its own presence under enforce → it APPEARS.
    assert presence_in_room?(start, fname, store),
           "an ephemeral session must appear (provisioned presence cert lets it sign its add)"

    st = :sys.get_state(session)
    assert st.signing_context != nil
    assert String.starts_with?(st.signing_context.identity_uuid, "session:")
    assert st.cert_cids != []
    # presence-only: no durable home / inventory.
    assert st.inventory_uuid == nil

    # Quit runs terminate/2 synchronously → the session signs its own remove.
    PlayerSession.stop(session)

    refute presence_in_room?(start, fname, store),
           "the ephemeral session must retract its own presence on quit (no ghost)"
  end

  test "PIN 5 (CRUX): a client-claimed player_identity_uuid the node has no key for does NOT borrow that identity — falls to ephemeral",
       %{store: store, root: root} do
    claimed = "victim-#{UUID.uuid4()}"

    session =
      start_session(
        player_name: "claimant",
        root_uuid: root,
        store: store,
        player_identity_uuid: claimed
      )

    st = :sys.get_state(session)

    # The bare claim is NOT fabricated into the claimed identity — the session
    # runs under a server-generated ephemeral identity instead.
    refute st.signing_context.identity_uuid == claimed
    assert String.starts_with?(st.signing_context.identity_uuid, "session:")

    PlayerSession.stop(session)
  end
end
