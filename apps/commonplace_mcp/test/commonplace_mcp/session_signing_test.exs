defmodule Commonplace.MCP.SessionSigningTest do
  @moduledoc """
  CX-88mw(iii): the placeholder swap, end to end at the MCP session
  level. A session whose presence bootstrap exposes a registered agent
  identity gets a REAL per-agent SigningContext minted at init; a chat
  post through `tools/call invoke_view_action` then produces a commit
  signed with the agent's key (`signer_id = "<identity_uuid>@<fp>"`),
  and the audit broadcast no longer says `"mcp-agent@local"`.
  """
  use ExUnit.Case, async: false

  alias Anubis.Server.Frame
  alias Commonplace.Chat.Rooms
  alias Commonplace.Crypto.Signing
  alias Commonplace.Dataflow.Magenta
  alias Commonplace.MCP.AnubisServer
  alias Commonplace.Presence.Identity
  alias Commonplace.Store.{CommitStore, CommitStoreClient}
  alias Commonplace.Tree.Schema

  setup do
    # Per-test scratch dir + global CommitStore restart (the MCP tool
    # path reads/writes through CommitStoreClient → the global store).
    # Pattern from invoke_view_action_chat_integration_test.exs.
    dir = Path.join(System.tmp_dir!(), "cp_session_signing_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    Application.put_env(:commonplace, :data_dir, dir)

    sup = Commonplace.Store.CommitStoreSupervisor
    _ = Supervisor.terminate_child(sup, Commonplace.Store.CommitStore)
    _ = Supervisor.delete_child(sup, Commonplace.Store.CommitStore)

    {:ok, _pid} =
      Supervisor.start_child(sup, {Commonplace.Store.CommitStore, data_dir: dir})

    Commonplace.Tree.DocCache.clear()

    on_exit(fn ->
      :persistent_term.erase({AnubisServer, :presence_starter})
      :persistent_term.erase({AnubisServer, :presence_stopper})

      _ = Supervisor.terminate_child(sup, Commonplace.Store.CommitStore)
      _ = Supervisor.delete_child(sup, Commonplace.Store.CommitStore)
      Application.put_env(:commonplace, :data_dir, "tmp/test_data")

      {:ok, _pid} =
        Supervisor.start_child(
          sup,
          {Commonplace.Store.CommitStore, data_dir: "tmp/test_data"}
        )

      Commonplace.Tree.DocCache.clear()
      File.rm_rf!(dir)
    end)

    root_uuid = UUID.uuid4()
    root_doc = Schema.new_schema()
    update = Yelixer.Encoding.encode_update(root_doc)
    CommitStore.create_commit(Commonplace.Store.CommitStore, root_uuid, update, nil)

    Commonplace.Test.WorkspaceFixture.complete_workspace!(dir,
      store: Commonplace.Store.CommitStore
    )

    File.write!(Path.join(dir, "root"), root_uuid)

    {:ok, room} = Rooms.create(root_uuid, "general")

    %{root: root_uuid, room: room}
  end

  test "a session-posted chat message lands as a commit SIGNED with the agent's key",
       %{root: root, room: room} do
    Magenta.subscribe("view_actions")

    # Real-shaped presence bootstrap: a registered cold identity whose
    # uuid the starter exposes as :identity_uuid (CX-88mw iii).
    {:ok, identity_uuid} = Identity.register("poster", :bot, root)

    AnubisServer.config(
      presence_starter: fn name, _type ->
        {:ok,
         %{pid: self(), name: name <> ".bot", uuid: "hot-uuid", identity_uuid: identity_uuid}}
      end
    )

    {:ok, frame} = AnubisServer.init(%{"name" => "poster"}, Frame.new())
    assert %Commonplace.Crypto.SigningContext{} = frame.assigns[:signing_context]

    request = %{
      "method" => "tools/call",
      "params" => %{
        "name" => "invoke_view_action",
        "arguments" => %{
          "view_uuid" => room.view_uuid,
          "action" => "post_message",
          "view_path" => "/chat/general/_view.xml",
          "args" => %{"text" => "signed by the session key"}
        }
      }
    }

    assert {:reply, _result, _frame} = AnubisServer.handle_request(request, frame)

    # The commit on the messages doc is signed by the AGENT's key.
    {:ok, commit} = CommitStoreClient.latest_commit(CommitStore, room.messages_uuid)
    refute is_nil(commit.signature), "chat commit must be signed by the session key"

    {:ok, agent_ctx} = Commonplace.Crypto.AgentKeys.signing_context_for(identity_uuid)
    expected_signer = Signing.signer_id(identity_uuid, agent_ctx.public_key)
    assert commit.signer_id == expected_signer
    assert :ok = Signing.verify_commit(commit, agent_ctx.public_key)

    # The audit payload carries the real signer, not the placeholder.
    assert_receive {:magenta, "view_actions", %Magenta{type: "view_action_invoked"} = msg},
                   1000

    assert msg.payload["signer_id"] == expected_signer
    refute msg.payload["signer_id"] == "mcp-agent@local"
  end
end
