defmodule Commonplace.MUD.CxSfj8PresenceCertReproTest do
  @moduledoc """
  CX-sfj8 / CX-jicn — REPRODUCE-FIRST (plan review pending). The unsigned-session
  gap: under :enforce a session's presence write (add on connect, remove on quit)
  is authorized ONLY by a node-signed `{:presence, id}` `:write` cert (the CX-0a9a
  Model-A carve: cert scope AND `bound_identity == signer`). CITIZENS get that
  cert from `Citizenship.ensure`; a raw bot/MCP/web session does NOT (cert_cids
  == []), so under enforce:
    * its presence remove on quit is DENIED → the `.usr` never retracts →
      accumulating GHOSTS (CX-3xwu), and
    * its own presence write is refused → {:trust_rejected} floods the pane
      (CX-jicn).

  This test isolates that gap: an identity-holding session with NO presence cert
  is refused; provisioning the SAME node-signed `{:presence}` cert
  (`issue_presence_starter_cert` — the mechanism §9 lifts to every session at
  bootstrap) lets it add AND retract. RED on the missing-cert path; the fix makes
  bootstrap provision the cert (+ an ephemeral identity when the session has none)
  so every session — citizen, bot, MCP, web — signs its own presence.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Crypto.{NodeIdentity, Signing, SigningContext}
  alias Commonplace.MUD.{Citizenship, Schemas}
  alias Commonplace.Presence
  alias Commonplace.Tree.Schema

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_sfj8_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    n = :rand.uniform(1_000_000_000)
    store = :"sfj8_store_#{n}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: dir,
       name: :"sfj8_sup_#{n}",
       commit_store_name: store,
       trust_side_store_name: :"sfj8_tss_#{n}",
       pending_imports_name: :"sfj8_pi_#{n}"}
    )

    old_trust = Application.get_env(:commonplace, :trust)
    old_knob = Application.get_env(:commonplace, :local_write_gate)
    Application.put_env(:commonplace, :trust, %{accept_unsigned: false, trusted_identities: %{}})
    Application.put_env(:commonplace, :local_write_gate, :enforce)

    on_exit(fn ->
      restore = fn key, v ->
        if is_nil(v), do: Application.delete_env(:commonplace, key), else: Application.put_env(:commonplace, key, v)
      end

      restore.(:trust, old_trust)
      restore.(:local_write_gate, old_knob)
      File.rm_rf!(dir)
    end)

    {:ok, node_ctx} = NodeIdentity.signing_context()

    # A curated room (node-signed) to host presence.
    {:ok, room} =
      Schemas.create_dir_with_meta(
        Schemas.room_filename(),
        Schemas.encode_room(%Schemas.Room{name: "Start", description: "a plain room"}),
        store,
        signing_context: node_ctx
      )

    %{store: store, room: room}
  end

  defp session_identity do
    {pub, priv} = Signing.generate_keypair()
    id = "sess-#{:rand.uniform(1_000_000_000)}"
    {id, pub, %SigningContext{identity_uuid: id, public_key: pub, private_key: priv}}
  end

  defp present?(store, room, fname) do
    {:ok, schema} = Schemas.load_dir_schema(room, store)
    match?({:ok, _}, Schema.get_entry(schema, fname))
  end

  test "an uncertified session's presence is refused; provisioning the {:presence} cert lets it add AND retract",
       %{store: store, room: room} do
    {id, pub, ctx} = session_identity()
    fname = Presence.filename("bot1", :usr)

    # (BUG) No presence cert (a raw bot/MCP/web session) → under enforce the
    # signed-but-uncertified presence write is refused → nothing lands.
    _ = Presence.create("bot1", :usr, room, store, signing_context: ctx, cert_cids: [])
    refute present?(store, room, fname), "uncertified presence write must be refused under enforce"

    # (FIX MECHANISM) Provision the node-signed {:presence, id} cert — exactly
    # what §9 lifts to every session at bootstrap.
    cids = Citizenship.issue_presence_starter_cert(id, pub, store)
    assert cids != [], "node must provision a {:presence} cert"

    # Now the session signs its own presence ADD → lands under enforce.
    assert {:ok, _} = Presence.create("bot1", :usr, room, store, signing_context: ctx, cert_cids: cids)
    assert present?(store, room, fname), "certified presence add must land"

    # ...and its own presence REMOVE on quit → retracts (no ghost).
    removed = Presence.remove(fname, room, store, signing_context: ctx, cert_cids: cids)
    refute match?({:error, _}, removed), "certified presence remove must not be trust-rejected"
    refute present?(store, room, fname), "certified presence remove must retract (no ghost)"
  end
end
