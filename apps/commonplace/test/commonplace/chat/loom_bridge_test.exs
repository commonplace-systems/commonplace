defmodule Commonplace.Chat.LoomBridgeTest do
  @moduledoc """
  CX-6sf2.2 (A2): `Commonplace.Chat.LoomBridge` — offline bidirectional
  loom <-> external mirror, driven entirely through a fake transport
  (`FakeTransport` below). NO IRC client, NO network socket, anywhere
  in this test file — that's the point of the injected-transport seam.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Chat.{Actions, LoomBridge, Messages}
  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.DocBuilder

  # A transport that just forwards every relay_to_external call to the
  # test process as a message, and never touches a socket. Implements
  # Commonplace.Chat.LoomBridge.Transport.
  defmodule FakeTransport do
    @behaviour Commonplace.Chat.LoomBridge.Transport

    @impl true
    def relay_to_external(test_pid, message) do
      send(test_pid, {:relayed, message})
      {:ok, test_pid}
    end
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_loom_bridge_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    store_name = :"loom_bridge_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store_name})
    on_exit(fn -> File.rm_rf!(dir) end)

    secret_dir =
      Path.join(System.tmp_dir!(), "cp_loom_bridge_secrets_#{:rand.uniform(1_000_000)}")

    File.mkdir_p!(secret_dir)
    secret_store_name = :"loom_bridge_secrets_#{:rand.uniform(1_000_000)}"

    start_supervised!(
      {Commonplace.Store.SecretStore, data_dir: secret_dir, name: secret_store_name}
    )

    on_exit(fn -> File.rm_rf!(secret_dir) end)

    messages_uuid = UUID.uuid4()
    doc = Messages.new()
    update = Yelixer.Encoding.encode_update(doc)
    CommitStore.create_commit(store_name, messages_uuid, update, nil)

    {:ok, bridge} =
      LoomBridge.start_link(
        room: "loom",
        messages_uuid: messages_uuid,
        store: store_name,
        secret_store: secret_store_name,
        transport_mod: FakeTransport,
        transport_state: self(),
        interval_ms: :infinity
      )

    %{
      bridge: bridge,
      store: store_name,
      messages_uuid: messages_uuid
    }
  end

  defp post(store, messages_uuid, text, author_path \\ "alice.usr") do
    {:ok, %{message_id: id}} =
      Actions.post_message(messages_uuid, text,
        room: "loom",
        signer_id: "alice@aaaaaaaa",
        author_path: author_path,
        store: store
      )

    id
  end

  defp reload(store, messages_uuid) do
    {:ok, doc} = DocBuilder.reconstruct_snapshot(store, messages_uuid)
    Messages.materialize(doc)
  end

  describe "outbound (loom -> external)" do
    test "relays new messages in order, then nothing on a tick with no new messages", %{
      bridge: bridge,
      store: store,
      messages_uuid: uuid
    } do
      post(store, uuid, "hello")
      post(store, uuid, "world")

      assert {:ok, %{relayed: 2}} = LoomBridge.tick_now(bridge)

      assert_received {:relayed, %{author: "alice.usr", text: "hello"}}
      assert_received {:relayed, %{author: "alice.usr", text: "world"}}
      refute_received {:relayed, _}

      assert {:ok, %{relayed: 0}} = LoomBridge.tick_now(bridge)
      refute_received {:relayed, _}
    end
  end

  describe "inbound (external -> loom)" do
    test "an external message is posted to loom, attributed to the nick, signed by the bridge",
         %{bridge: bridge, store: store, messages_uuid: uuid} do
      send(bridge, {:external_message, %{nick: "eve", text: "hi from irc"}})

      # Sync up with the bridge's mailbox before asserting.
      _ = LoomBridge.status(bridge)

      materialized = reload(store, uuid)
      assert [entry] = materialized
      assert entry["text"] == "hi from irc"
      assert entry["author_path"] =~ "eve"
      refute entry["author_signer_id"] == "alice@aaaaaaaa"
    end
  end

  describe "echo prevention" do
    test "inbound then outbound: a bridge-posted message is not relayed back out", %{
      bridge: bridge,
      store: store,
      messages_uuid: uuid
    } do
      send(bridge, {:external_message, %{nick: "eve", text: "hi from irc"}})
      _ = LoomBridge.status(bridge)

      # A genuine loom-authored message should still relay.
      post(store, uuid, "genuine loom message")

      assert {:ok, %{relayed: 1}} = LoomBridge.tick_now(bridge)
      assert_received {:relayed, %{text: "genuine loom message"}}
      refute_received {:relayed, %{text: "hi from irc"}}
    end

    test "outbound reflection: a relayed loom message reflected back as external is deduped", %{
      bridge: bridge,
      store: store,
      messages_uuid: uuid
    } do
      post(store, uuid, "reflected message", "alice.usr")
      assert {:ok, %{relayed: 1}} = LoomBridge.tick_now(bridge)
      assert_received {:relayed, %{author: "alice.usr", text: "reflected message"}}

      # IRC reflects our own relayed message back in.
      send(bridge, {:external_message, %{nick: "alice.usr", text: "reflected message"}})
      _ = LoomBridge.status(bridge)

      materialized = reload(store, uuid)
      assert length(materialized) == 1
      assert hd(materialized)["text"] == "reflected message"
    end
  end

  describe "kill-switch" do
    test "paused bridge relays nothing either way; resume restores", %{
      bridge: bridge,
      store: store,
      messages_uuid: uuid
    } do
      :ok = LoomBridge.pause(bridge)
      assert %{paused: true} = LoomBridge.status(bridge)

      post(store, uuid, "while paused")
      send(bridge, {:external_message, %{nick: "eve", text: "also while paused"}})

      assert {:ok, :paused} = LoomBridge.tick_now(bridge)
      refute_received {:relayed, _}

      materialized = reload(store, uuid)
      assert length(materialized) == 1
      assert hd(materialized)["text"] == "while paused"

      :ok = LoomBridge.resume(bridge)
      assert %{paused: false} = LoomBridge.status(bridge)

      assert {:ok, %{relayed: 1}} = LoomBridge.tick_now(bridge)
      assert_received {:relayed, %{text: "while paused"}}
    end
  end
end
