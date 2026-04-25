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
end
