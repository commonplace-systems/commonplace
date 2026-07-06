defmodule Commonplace.Chat.ActionsTest do
  @moduledoc """
  CX-487i (V1+V2 merged of CX-p2qp): post_message action handler.

  Tests the seam from `Commonplace.Chat.Actions.post_message/3` —
  appending a JSON entry to a `_messages` doc, committing via the chain,
  broadcasting magenta on `chat:{room}:events`, returning the new
  message_id. The dispatcher integration (ViewActionDispatch clause) is
  tested separately in view_action_dispatch_test.exs.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Chat.{Actions, Messages}
  alias Commonplace.Dataflow.Magenta
  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.DocBuilder

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_chat_actions_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    name = :"chat_actions_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: name})
    on_exit(fn -> File.rm_rf!(dir) end)

    # Seed an empty _messages doc.
    messages_uuid = UUID.uuid4()
    doc = Messages.new()
    update = Yelixer.Encoding.encode_update(doc)
    CommitStore.create_commit(name, messages_uuid, update, nil)

    %{store: name, messages_uuid: messages_uuid}
  end

  describe "post_message/3" do
    test "appends a JSON entry to the messages doc and returns {:ok, %{message_id, ts}}",
         %{store: store, messages_uuid: uuid} do
      assert {:ok, %{message_id: id, ts: ts}} =
               Actions.post_message(uuid, "hello world",
                 room: "general",
                 signer_id: "alice@aaaaaaaa",
                 author_path: "alice.usr",
                 store: store
               )

      assert is_binary(id)
      assert is_binary(ts)

      # Reload the doc and verify the entry landed.
      {:ok, reloaded} = DocBuilder.reconstruct_snapshot(store, uuid)
      [entry] = Messages.list(reloaded)

      assert entry["id"] == id
      assert entry["text"] == "hello world"
      assert entry["author_signer_id"] == "alice@aaaaaaaa"
      assert entry["author_path"] == "alice.usr"
      assert entry["ts"] == ts
      refute Map.has_key?(entry, "edit_of")
      refute Map.has_key?(entry, "tombstone_of")
    end

    test "includes reply_to when provided", %{store: store, messages_uuid: uuid} do
      {:ok, %{message_id: m1}} =
        Actions.post_message(uuid, "first",
          room: "general",
          signer_id: "alice@aaaaaaaa",
          author_path: "alice.usr",
          store: store
        )

      {:ok, _} =
        Actions.post_message(uuid, "thread reply",
          room: "general",
          signer_id: "bob@bbbbbbbb",
          author_path: "bob.usr",
          reply_to: m1,
          store: store
        )

      {:ok, reloaded} = DocBuilder.reconstruct_snapshot(store, uuid)
      [_, second] = Messages.list(reloaded)

      assert second["reply_to"] == m1
    end

    test "broadcasts magenta on chat:{room}:events with verb='post'",
         %{store: store, messages_uuid: uuid} do
      Magenta.subscribe("chat:general:events")

      {:ok, %{message_id: id}} =
        Actions.post_message(uuid, "hi",
          room: "general",
          signer_id: "alice@aaaaaaaa",
          author_path: "alice.usr",
          store: store
        )

      assert_receive {:magenta, "chat:general:events", %Magenta{type: "post"} = msg}, 500
      assert msg.payload["message_id"] == id
      assert msg.payload["author_signer_id"] == "alice@aaaaaaaa"
      assert msg.source == "chat"
    end

    test "two consecutive posts both land in array order",
         %{store: store, messages_uuid: uuid} do
      {:ok, %{message_id: m1}} =
        Actions.post_message(uuid, "one",
          room: "general",
          signer_id: "alice@aaaaaaaa",
          author_path: "alice.usr",
          store: store
        )

      {:ok, %{message_id: m2}} =
        Actions.post_message(uuid, "two",
          room: "general",
          signer_id: "alice@aaaaaaaa",
          author_path: "alice.usr",
          store: store
        )

      {:ok, reloaded} = DocBuilder.reconstruct_snapshot(store, uuid)
      ids = Messages.list(reloaded) |> Enum.map(& &1["id"])

      assert ids == [m1, m2]
    end

    test "missing required opts return {:error, reason}",
         %{store: store, messages_uuid: uuid} do
      # author_path is required so the verifier knows whose presence
      # to look up. Missing it must surface, not silently default.
      assert {:error, reason} =
               Actions.post_message(uuid, "x", room: "general", store: store)

      assert reason =~ "author_path" or reason =~ "signer_id"
    end

    test "post_message on a missing messages doc returns {:error, :not_found}",
         %{store: store} do
      assert {:error, :not_found} =
               Actions.post_message(UUID.uuid4(), "lost",
                 room: "general",
                 signer_id: "alice@aaaaaaaa",
                 author_path: "alice.usr",
                 store: store
               )
    end
  end

  describe "edit_message/4 (CX-ybhb / V3)" do
    setup %{store: store, messages_uuid: uuid} do
      # Seed an original message so edits/tombstones have something to chain to.
      {:ok, %{message_id: m1}} =
        Actions.post_message(uuid, "v1",
          room: "general",
          signer_id: "alice@aaaaaaaa",
          author_path: "alice.usr",
          store: store
        )

      %{m1: m1}
    end

    test "appends an edit-entry with edit_of pointing at target",
         %{store: store, messages_uuid: uuid, m1: m1} do
      assert {:ok, %{message_id: edit_id, ts: _ts}} =
               Actions.edit_message(uuid, m1, "v2",
                 room: "general",
                 signer_id: "alice@aaaaaaaa",
                 author_path: "alice.usr",
                 store: store
               )

      assert is_binary(edit_id)
      refute edit_id == m1, "edit must mint a new id, not reuse the target's"

      {:ok, reloaded} = DocBuilder.reconstruct_snapshot(store, uuid)
      [original, edit] = Messages.list(reloaded)

      assert original["id"] == m1
      assert original["text"] == "v1"
      assert edit["id"] == edit_id
      assert edit["text"] == "v2"
      assert edit["edit_of"] == m1
    end

    test "broadcasts magenta verb='edit' on chat:{room}:events",
         %{store: store, messages_uuid: uuid, m1: m1} do
      Magenta.subscribe("chat:general:events")

      {:ok, %{message_id: edit_id}} =
        Actions.edit_message(uuid, m1, "v2",
          room: "general",
          signer_id: "alice@aaaaaaaa",
          author_path: "alice.usr",
          store: store
        )

      assert_receive {:magenta, "chat:general:events", %Magenta{type: "edit"} = msg}, 500
      assert msg.payload["message_id"] == edit_id
      assert msg.payload["edit_of"] == m1
      assert msg.source == "chat"
    end

    test "missing required opts return {:error, reason}",
         %{store: store, messages_uuid: uuid, m1: m1} do
      assert {:error, _} = Actions.edit_message(uuid, m1, "v2", room: "general", store: store)
    end

    test "edit on a missing messages doc returns {:error, :not_found}", %{store: store} do
      assert {:error, :not_found} =
               Actions.edit_message(UUID.uuid4(), "ghost", "x",
                 room: "general",
                 signer_id: "a",
                 author_path: "a.usr",
                 store: store
               )
    end

    test "materialize/1 reflects the edit (text replaced, edited?=true)",
         %{store: store, messages_uuid: uuid, m1: m1} do
      {:ok, _} =
        Actions.edit_message(uuid, m1, "v2-after-edit",
          room: "general",
          signer_id: "alice@aaaaaaaa",
          author_path: "alice.usr",
          store: store
        )

      {:ok, reloaded} = DocBuilder.reconstruct_snapshot(store, uuid)
      [m] = Messages.materialize(reloaded)

      assert m["id"] == m1
      assert m["text"] == "v2-after-edit"
      assert m["edited?"] == true
      assert m["deleted?"] == false
    end
  end

  describe "delete_message/3 (CX-ybhb / V3)" do
    setup %{store: store, messages_uuid: uuid} do
      {:ok, %{message_id: m1}} =
        Actions.post_message(uuid, "secret",
          room: "general",
          signer_id: "alice@aaaaaaaa",
          author_path: "alice.usr",
          store: store
        )

      %{m1: m1}
    end

    test "appends a tombstone-entry with tombstone_of pointing at target",
         %{store: store, messages_uuid: uuid, m1: m1} do
      assert {:ok, %{message_id: tomb_id, ts: _ts}} =
               Actions.delete_message(uuid, m1,
                 room: "general",
                 signer_id: "alice@aaaaaaaa",
                 author_path: "alice.usr",
                 store: store
               )

      refute tomb_id == m1

      {:ok, reloaded} = DocBuilder.reconstruct_snapshot(store, uuid)
      [original, tomb] = Messages.list(reloaded)

      assert original["id"] == m1
      assert tomb["id"] == tomb_id
      assert tomb["tombstone_of"] == m1
      refute Map.has_key?(tomb, "text"),
             "tombstone has no text — deletion is the act, not a content edit"
    end

    test "broadcasts magenta verb='delete' on chat:{room}:events",
         %{store: store, messages_uuid: uuid, m1: m1} do
      Magenta.subscribe("chat:general:events")

      {:ok, %{message_id: tomb_id}} =
        Actions.delete_message(uuid, m1,
          room: "general",
          signer_id: "alice@aaaaaaaa",
          author_path: "alice.usr",
          store: store
        )

      assert_receive {:magenta, "chat:general:events", %Magenta{type: "delete"} = msg}, 500
      assert msg.payload["message_id"] == tomb_id
      assert msg.payload["tombstone_of"] == m1
    end

    test "concurrent deletes converge — materialize/1 still shows deleted?=true",
         %{store: store, messages_uuid: uuid, m1: m1} do
      {:ok, _} =
        Actions.delete_message(uuid, m1,
          room: "general",
          signer_id: "alice@aaaaaaaa",
          author_path: "alice.usr",
          store: store
        )

      {:ok, _} =
        Actions.delete_message(uuid, m1,
          room: "general",
          signer_id: "bob@bbbbbbbb",
          author_path: "bob.usr",
          store: store
        )

      {:ok, reloaded} = DocBuilder.reconstruct_snapshot(store, uuid)
      [m] = Messages.materialize(reloaded)

      assert m["deleted?"] == true,
             "monotone deletion: two tombstones still produce one deleted message"
    end

    test "delete on a missing messages doc returns {:error, :not_found}", %{store: store} do
      assert {:error, :not_found} =
               Actions.delete_message(UUID.uuid4(), "ghost",
                 room: "general",
                 signer_id: "a",
                 author_path: "a.usr",
                 store: store
               )
    end

    test "missing required opts return {:error, reason}",
         %{store: store, messages_uuid: uuid, m1: m1} do
      assert {:error, _} = Actions.delete_message(uuid, m1, room: "general", store: store)
    end
  end

  describe "writer identity — stable per-(doc, actor) hand (CX-41qg.3)" do
    # Before this fix, `load_messages_doc` reconstructed the `_messages`
    # doc via `DocBuilder.reconstruct_snapshot/2` with no client_id — a
    # fresh random one every call — so N chat actions minted N distinct
    # Yjs client ids into the doc's state vector. The fix pins the
    # reconstruction to `WriterHand.for_doc_actor(messages_uuid,
    # signer_id)`: one stable slot per actor per room. Per-ACTOR, not
    # the plain per-doc funnel hand, because chat writers are
    # genuinely-concurrent distinct processes (LiveView sessions, MCP,
    # LoomBridge, bots) with no serializing funnel — see the cross-actor
    # tests below for the collision this avoids.
    defp sv_client_ids(doc) do
      Yelixer.BlockStore.state_vector(doc.store).clocks
      |> Map.keys()
      |> MapSet.new()
    end

    test "20 post_message calls keep the state vector's client-id set bounded",
         %{store: store, messages_uuid: uuid} do
      Enum.each(1..20, fn n ->
        assert {:ok, _} =
                 Actions.post_message(uuid, "message #{n}",
                   room: "general",
                   signer_id: "alice@aaaaaaaa",
                   author_path: "alice.usr",
                   store: store
                 )
      end)

      {:ok, doc} = DocBuilder.reconstruct_snapshot(store, uuid)
      client_ids = sv_client_ids(doc)

      assert MapSet.size(client_ids) <= 2,
             "expected a bounded (<=2) set of client ids after 20 posts, " <>
               "got #{MapSet.size(client_ids)}: #{inspect(client_ids)} " <>
               "(pre-fix behavior would show one new client id per write, i.e. ~20)"
    end

    test "mixed post/edit/delete traffic still keeps the client-id set bounded",
         %{store: store, messages_uuid: uuid} do
      opts = [room: "general", signer_id: "alice@aaaaaaaa", author_path: "alice.usr", store: store]

      ids =
        Enum.map(1..10, fn n ->
          {:ok, %{message_id: id}} = Actions.post_message(uuid, "msg #{n}", opts)
          id
        end)

      Enum.each(ids, fn id ->
        assert {:ok, _} = Actions.edit_message(uuid, id, "edited", opts)
      end)

      Enum.each(ids, fn id ->
        assert {:ok, _} = Actions.delete_message(uuid, id, opts)
      end)

      {:ok, doc} = DocBuilder.reconstruct_snapshot(store, uuid)
      client_ids = sv_client_ids(doc)

      assert MapSet.size(client_ids) <= 2,
             "expected a bounded (<=2) set of client ids after 30 mixed writes, " <>
               "got #{MapSet.size(client_ids)}: #{inspect(client_ids)}"
    end

    test "distinct actors write under distinct hands (cross-actor collision guard)",
         %{store: store, messages_uuid: uuid} do
      # Two actors sharing one hand can mint colliding (client_id, clock)
      # ops when they reconstruct the same base concurrently — and the
      # loser's ops are silently skipped as duplicates on replay
      # (reproduced during CX-41qg.3 review). Distinct hands per actor is
      # the guard; this pins the derivation actually differing.
      alice = Commonplace.WriterHand.for_doc_actor(uuid, "alice@aaaaaaaa")
      bob = Commonplace.WriterHand.for_doc_actor(uuid, "bob@bbbbbbbb")
      refute alice == bob

      for {signer, path} <- [{"alice@aaaaaaaa", "alice.usr"}, {"bob@bbbbbbbb", "bob.usr"}] do
        assert {:ok, _} =
                 Actions.post_message(uuid, "hello from #{path}",
                   room: "general",
                   signer_id: signer,
                   author_path: path,
                   store: store
                 )
      end

      {:ok, doc} = DocBuilder.reconstruct_snapshot(store, uuid)
      client_ids = sv_client_ids(doc)

      assert MapSet.member?(client_ids, alice)
      assert MapSet.member?(client_ids, bob)
    end

    test "concurrent-style divergent appends from two actors both survive replay",
         %{store: store, messages_uuid: uuid} do
      # The repro that motivated per-(doc, actor) hands, pinned: both
      # writers reconstruct the SAME base (neither sees the other's
      # post), append, and their commits land in chain order. With a
      # shared hand the second writer's entry vanishes on replay; with
      # per-actor hands both survive.
      {:ok, base} = DocBuilder.reconstruct_snapshot(store, uuid)
      base_update = Yelixer.Encoding.encode_update(base)

      entries =
        for {actor, text} <- [{"alice@aaaaaaaa", "from A"}, {"bob@bbbbbbbb", "from B"}] do
          hand = Commonplace.WriterHand.for_doc_actor(uuid, actor)
          doc = Yelixer.Doc.new(client_id: hand)
          {:ok, doc} = Yelixer.Encoding.apply_update(doc, base_update)
          doc = Commonplace.Chat.Messages.append(doc, %{"id" => actor, "text" => text})
          Yelixer.Encoding.encode_update(doc)
        end

      replay = Yelixer.Doc.new()

      replay =
        Enum.reduce([base_update | entries], replay, fn u, d ->
          {:ok, d} = Yelixer.Encoding.apply_update(d, u)
          d
        end)

      ids = Commonplace.Chat.Messages.list(replay) |> Enum.map(& &1["id"])
      assert "alice@aaaaaaaa" in ids
      assert "bob@bbbbbbbb" in ids
    end
  end

  describe "session hand override (CX-qat5.2 §2.4 — opts[:client_id])" do
    # A logged-in browser session resolves its OWN stable W4 hand once
    # at login (WriterHand.for_session/2) and threads it down as
    # opts[:client_id] via ViewActionDispatch's :hand context key. When
    # present, it wins over the per-(doc, actor) funnel derivation this
    # module falls back to for hand-less callers.
    test "opts[:client_id], when present, is used as the reconstruction client_id instead of the per-actor fallback",
         %{store: store, messages_uuid: uuid} do
      session_hand = Commonplace.WriterHand.for_session(:crypto.strong_rand_bytes(32), "nonce-1")
      fallback_hand = Commonplace.WriterHand.for_doc_actor(uuid, "alice@aaaaaaaa")
      refute session_hand == fallback_hand

      assert {:ok, _} =
               Actions.post_message(uuid, "hi from a session",
                 room: "general",
                 signer_id: "alice@aaaaaaaa",
                 author_path: "alice.usr",
                 client_id: session_hand,
                 store: store
               )

      {:ok, doc} = DocBuilder.reconstruct_snapshot(store, uuid)
      client_ids = sv_client_ids(doc)

      assert MapSet.member?(client_ids, session_hand)
      refute MapSet.member?(client_ids, fallback_hand)
    end

    test "absent opts[:client_id] keeps the pre-existing per-actor fallback (no regression)",
         %{store: store, messages_uuid: uuid} do
      fallback_hand = Commonplace.WriterHand.for_doc_actor(uuid, "alice@aaaaaaaa")

      assert {:ok, _} =
               Actions.post_message(uuid, "no session hand here",
                 room: "general",
                 signer_id: "alice@aaaaaaaa",
                 author_path: "alice.usr",
                 store: store
               )

      {:ok, doc} = DocBuilder.reconstruct_snapshot(store, uuid)
      assert MapSet.member?(sv_client_ids(doc), fallback_hand)
    end
  end

  describe "signed session posts (CX-qat5.2 acceptance pins 1 + 2)" do
    alias Commonplace.Crypto.{Signing, SigningContext}

    test "a post with a resolved signing_context lands signed as that player's signer_id, with zero ambient_signed telemetry",
         %{store: store, messages_uuid: uuid} do
      {pub, priv} = Signing.generate_keypair()
      identity_uuid = UUID.uuid4()
      signer_id = Signing.signer_id(identity_uuid, pub)
      ctx = %SigningContext{identity_uuid: identity_uuid, private_key: priv, public_key: pub}

      ref = make_ref()
      parent = self()

      :telemetry.attach(
        {:actions_test_ambient_signed, ref},
        [:commonplace, :commit, :ambient_signed],
        fn _event, meas, meta, _cfg -> send(parent, {:ambient_signed, ref, meas, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach({:actions_test_ambient_signed, ref}) end)

      assert {:ok, %{message_id: id}} =
               Actions.post_message(uuid, "signed as a real player",
                 room: "general",
                 signer_id: signer_id,
                 author_path: "alice.usr",
                 signing_context: ctx,
                 store: store
               )

      assert is_binary(id)
      refute_receive {:ambient_signed, ^ref, _meas, _meta}, 100

      {:ok, commit} = CommitStore.latest_commit(store, uuid)
      assert commit.signer_id == signer_id
      assert commit.signature != nil
    end
  end
end
