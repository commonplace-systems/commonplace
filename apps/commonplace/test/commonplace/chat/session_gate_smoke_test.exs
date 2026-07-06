defmodule Commonplace.Chat.SessionGateSmokeTest do
  @moduledoc """
  CX-qat5.2 acceptance pin 5 (spec §2.5, the qat5.3 payoff): with
  `accept_unsigned: false` + a pinned player identity + the local-write
  gate in `:enforce`, a logged-in player's chat post LANDS and an
  anonymous (unsigned) post is REJECTED with the trust-gate error a
  LiveView would translate into the permission flash.

  Mirrors `Commonplace.Store.LocalWriteGateTest`'s setup shape (full
  `Store.Supervisor` trio, same `strict!`/`enforce!` config toggles) but
  exercises the seam THIS bead adds: a player identity minted via
  `Commonplace.Invites` + redeemed, its `SigningContext` resolved via
  `Commonplace.Crypto.AgentKeys.signing_context/2` — exactly what
  `CommonplaceWebWeb.SessionIdentity.resolve/1` does at a LiveView
  mount — posting a chat message through `Commonplace.Chat.Actions`,
  the SAME action seam `ChatRoomLive` dispatches through.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Chat.{Actions, Messages}
  alias Commonplace.Crypto.{AgentKeys, Signing}
  alias Commonplace.Invites
  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.Schema

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_session_gate_smoke_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    n = :rand.uniform(1_000_000_000)
    name = :"sgs_store_#{n}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: dir,
       name: :"sgs_sup_#{n}",
       commit_store_name: name,
       trust_side_store_name: :"sgs_tss_#{n}",
       pending_imports_name: :"sgs_pi_#{n}"}
    )

    old_trust = Application.get_env(:commonplace, :trust)
    old_knob = Application.get_env(:commonplace, :local_write_gate)

    on_exit(fn ->
      case old_trust do
        nil -> Application.delete_env(:commonplace, :trust)
        v -> Application.put_env(:commonplace, :trust, v)
      end

      case old_knob do
        nil -> Application.delete_env(:commonplace, :local_write_gate)
        v -> Application.put_env(:commonplace, :local_write_gate, v)
      end

      File.rm_rf!(dir)
    end)

    root_uuid = UUID.uuid4()
    root_doc = Schema.new_schema()
    root_update = Yelixer.Encoding.encode_update(root_doc)
    CommitStore.create_commit(name, root_uuid, root_update, nil)

    messages_uuid = UUID.uuid4()
    messages_update = Yelixer.Encoding.encode_update(Messages.new())
    CommitStore.create_commit(name, messages_uuid, messages_update, nil)

    %{store: name, root: root_uuid, messages_uuid: messages_uuid}
  end

  test "a logged-in player's post lands; an anonymous post is rejected", %{
    store: store,
    root: root,
    messages_uuid: messages_uuid
  } do
    # Mint + redeem exactly as the invite-login flow does — this gives
    # us the same {identity_uuid, SigningContext} pair
    # `SessionIdentity.resolve/1` would hand a mounted LiveView.
    {:ok, %{identity_uuid: identity_uuid, token: token}} =
      Invites.mint("kate", root, store)

    assert {:ok, ^identity_uuid} = Invites.redeem(token)
    assert {:ok, ctx} = AgentKeys.signing_context(identity_uuid)

    signer_id = Signing.signer_id(identity_uuid, ctx.public_key)

    Application.put_env(:commonplace, :trust, %{
      accept_unsigned: false,
      trusted_identities: %{identity_uuid => Signing.encode_key(ctx.public_key)}
    })

    Application.put_env(:commonplace, :local_write_gate, :enforce)

    # The logged-in player's signed post lands.
    assert {:ok, %{message_id: id}} =
             Actions.post_message(messages_uuid, "hi from a real player",
               room: "general",
               signer_id: signer_id,
               author_path: "kate.usr",
               signing_context: ctx,
               store: store
             )

    assert is_binary(id)

    # An anonymous (unsigned) post is rejected — the same trust-gate
    # error a browser LiveView would surface as the permission flash.
    assert {:error, {:trust_rejected, :unsigned}} =
             Actions.post_message(messages_uuid, "anonymous post",
               room: "general",
               signer_id: "anonymous@local",
               author_path: "web-user.usr",
               store: store
             )
  end
end
