defmodule Commonplace.OutlineActionsTest do
  @moduledoc """
  CX-2qjd: outline actions on the MCP surface. `_view.xml` DECLARES the
  actions (agent discovery); ViewActionDispatch routes them to the SAME
  `Commonplace.Outline.*` functions the LiveView keybinds call — one
  mutation implementation, two entry points (outliner.md §5). An agent's
  mutations are SIGNED with its per-agent key (CX-88mw composing in).
  """
  use ExUnit.Case, async: false

  alias Commonplace.Crypto.{Signing, SigningContext}
  alias Commonplace.Outline
  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.Schema
  alias Commonplace.ViewActionDispatch

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_outline_act_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    store = :"outline_act_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store})

    root = UUID.uuid4()
    CommitStore.create_commit(store, root, Yelixer.Encoding.encode_update(Schema.new_schema()), nil)
    {:ok, uuid} = Outline.create("agentboard", root, store)
    {:ok, a} = Outline.add_item(store, uuid, %{text: "First"})
    {:ok, b} = Outline.add_item(store, uuid, %{text: "Second", after: a})

    {agent_pub, agent_priv} = Signing.generate_keypair()
    agent = %SigningContext{identity_uuid: "agent-ol", private_key: agent_priv, public_key: agent_pub}

    on_exit(fn -> File.rm_rf!(dir) end)
    %{store: store, root: root, uuid: uuid, a: a, b: b, agent: agent, agent_pub: agent_pub}
  end

  defp ctx(store, agent, args) do
    %{args: args, store: store, signing_context: agent}
  end

  test "_view.xml declares the outline actions for agent discovery", %{store: store, root: root} do
    # The room dir holds _view.xml next to _outline.
    {:ok, view_xml} = Outline.view_xml("agentboard", root, store)
    for action <- ~w(add_item set_text indent_item outdent_item reorder_item toggle_collapse delete_item) do
      assert view_xml =~ ~s(<action name="#{action}"), "missing declaration for #{action}"
    end

    assert view_xml =~ ~s(from="../_outline")
  end

  test "indent_item via dispatch reparents, SIGNED by the agent",
       %{store: store, uuid: uuid, a: a, b: b, agent: agent, agent_pub: agent_pub} do
    assert {:ok, :tree_mutation, %{action: "indent_item"}} =
             ViewActionDispatch.dispatch(
               "indent_item",
               ctx(store, agent, %{"outline_uuid" => uuid, "id" => b})
             )

    by_id = Map.new(Outline.items(store, uuid), &{&1.id, &1})
    assert by_id[b].parent == a

    {:ok, head} = CommitStore.latest_commit(store, uuid)
    assert head.signer_id == Signing.signer_id("agent-ol", agent_pub)
  end

  test "add_item via dispatch", %{store: store, uuid: uuid, agent: agent} do
    assert {:ok, :tree_mutation, %{action: "add_item", id: new_id}} =
             ViewActionDispatch.dispatch(
               "add_item",
               ctx(store, agent, %{"outline_uuid" => uuid, "text" => "From the agent"})
             )

    assert Enum.find(Outline.items(store, uuid), &(&1.id == new_id)).text == "From the agent"
  end

  test "set_text / reorder_item / toggle_collapse / delete_item via dispatch",
       %{store: store, uuid: uuid, a: a, b: b, agent: agent} do
    assert {:ok, :tree_mutation, _} =
             ViewActionDispatch.dispatch(
               "set_text",
               ctx(store, agent, %{"outline_uuid" => uuid, "id" => a, "text" => "First!"})
             )

    assert {:ok, :tree_mutation, _} =
             ViewActionDispatch.dispatch(
               "reorder_item",
               ctx(store, agent, %{"outline_uuid" => uuid, "id" => b, "direction" => "up"})
             )

    assert {:ok, :tree_mutation, _} =
             ViewActionDispatch.dispatch(
               "toggle_collapse",
               ctx(store, agent, %{"outline_uuid" => uuid, "id" => a})
             )

    by_id = Map.new(Outline.items(store, uuid), &{&1.id, &1})
    assert by_id[a].text == "First!"
    assert by_id[a].collapsed == true
    assert by_id[b].order < by_id[a].order

    assert {:ok, :tree_mutation, _} =
             ViewActionDispatch.dispatch(
               "delete_item",
               ctx(store, agent, %{"outline_uuid" => uuid, "id" => b})
             )

    refute Enum.any?(Outline.items(store, uuid), &(&1.id == b))
  end

  test "missing args → readable error", %{store: store, agent: agent} do
    assert {:error, msg} = ViewActionDispatch.dispatch("indent_item", ctx(store, agent, %{}))
    assert msg =~ "outline_uuid"
  end
end
