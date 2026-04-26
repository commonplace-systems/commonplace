defmodule Commonplace.Tree.ForkDirectorySyntheticTest do
  @moduledoc """
  CX-6e92 (sub-bead iv of CX-jfwv M4): non-chat synthetic anchor for
  `Tree.Fork.fork_directory/2`.

  Anchor G from the M4 spec. Proves the substrate primitive is
  domain-agnostic — it works on arbitrary directory trees, not just
  chat-rooms.

  Per plan-bot's heads-up (msg 3259), the synthetic uses 4 sub-doc
  envelope types mirroring chat's (Yelixer YArray, ContentType :map,
  RedLog seed, ContentType :text) to prove all 4 fork-types in one
  anchor. Free upgrade vs. single-envelope synthetic.

  Round-1 audit finding (I) re RedLog client_id: `RedLog.new(uuid)`
  derives a stable client_id from uuid via :erlang.phash2. Forking copies
  the YDoc state including the encoded client_id; the new doc has the
  source's client_id baked in. For EMPTY seeds (M4's case + this
  anchor), the state vector under the source client_id has no events
  → harmless. Non-empty fork is M5 substrate-followup (RedLog
  fork-with-new-identity primitive).
  """
  use ExUnit.Case, async: false

  alias Commonplace.Dataflow.RedLog
  alias Commonplace.Document.ContentType
  alias Commonplace.Store.{CommitStore, CommitStoreClient}
  alias Commonplace.Tree.{DocBuilder, Fork, Lookup, Schema}
  alias Yelixer.Encoding

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_fork_synthetic_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    Application.put_env(:commonplace, :data_dir, dir)

    sup = Commonplace.Store.CommitStoreSupervisor
    _ = Supervisor.terminate_child(sup, Commonplace.Store.CommitStore)
    _ = Supervisor.delete_child(sup, Commonplace.Store.CommitStore)

    {:ok, _pid} =
      Supervisor.start_child(sup, {Commonplace.Store.CommitStore, data_dir: dir})

    Commonplace.Tree.DocCache.clear()

    on_exit(fn ->
      _ = Supervisor.terminate_child(sup, Commonplace.Store.CommitStore)
      _ = Supervisor.delete_child(sup, Commonplace.Store.CommitStore)
      Application.put_env(:commonplace, :data_dir, "tmp/test_data")

      {:ok, _pid} =
        Supervisor.start_child(sup, {Commonplace.Store.CommitStore, data_dir: "tmp/test_data"})

      Commonplace.Tree.DocCache.clear()
      File.rm_rf!(dir)
    end)

    :ok
  end

  defp mint_template do
    # Synthetic non-chat template: a "project workspace" shape with 4
    # sub-docs mirroring chat's envelope types but in a non-chat domain.
    data_uuid = mint_doc(fn -> Yelixer.Doc.new() |> ContentType.create(:array, "_data") end)
    state_uuid = mint_doc(fn -> Yelixer.Doc.new() |> ContentType.create(:map, "_state") end)
    audit_uuid = mint_red_log()
    view_uuid = mint_doc(fn -> Yelixer.Doc.new() |> ContentType.create(:text, "_view.xml") end)

    template_dir_uuid = UUID.uuid4()
    schema = Schema.new_schema()
    schema = Schema.add_file(schema, "_data", data_uuid)
    schema = Schema.add_file(schema, "_state", state_uuid)
    schema = Schema.add_file(schema, "_audit", audit_uuid)
    schema = Schema.add_file(schema, "_view.xml", view_uuid)
    update = Encoding.encode_update(schema)
    CommitStore.create_commit(Commonplace.Store.CommitStore, template_dir_uuid, update, nil)

    %{
      template_dir_uuid: template_dir_uuid,
      data_uuid: data_uuid,
      state_uuid: state_uuid,
      audit_uuid: audit_uuid,
      view_uuid: view_uuid
    }
  end

  defp mint_doc(builder) do
    uuid = UUID.uuid4()
    doc = builder.()
    update = Encoding.encode_update(doc)
    CommitStore.create_commit(Commonplace.Store.CommitStore, uuid, update, nil)
    uuid
  end

  defp mint_red_log do
    uuid = UUID.uuid4()
    doc = RedLog.new(uuid).doc
    update = Encoding.encode_update(doc)
    CommitStore.create_commit(Commonplace.Store.CommitStore, uuid, update, nil)
    uuid
  end

  defp load(uuid) do
    {:ok, doc} = DocBuilder.reconstruct_snapshot(CommitStoreClient, uuid)
    doc
  end

  describe "fork_directory/2 — Anchor G (substrate domain-agnosticism)" do
    test "forks a non-chat 4-envelope directory; new UUIDs; content preserved" do
      template = mint_template()

      forked_uuid = Fork.fork_directory(template.template_dir_uuid)

      assert is_binary(forked_uuid)
      assert forked_uuid != template.template_dir_uuid

      # Tree.Lookup pulls the forked sub-doc UUIDs from the new schema.
      {:ok, forked_children} =
        Lookup.extract_named_children(forked_uuid, [
          "_data",
          "_state",
          "_audit",
          "_view.xml"
        ])

      # Each child has a new UUID (deep-copy semantic).
      assert forked_children["_data"] != template.data_uuid
      assert forked_children["_state"] != template.state_uuid
      assert forked_children["_audit"] != template.audit_uuid
      assert forked_children["_view.xml"] != template.view_uuid
    end

    test "ContentType :array envelope survives fork" do
      template = mint_template()
      forked_uuid = Fork.fork_directory(template.template_dir_uuid)
      {:ok, %{"_data" => forked_data}} = Lookup.extract_named_children(forked_uuid, ["_data"])

      original = load(template.data_uuid)
      forked = load(forked_data)

      assert ContentType.get_type(original) == :array
      assert ContentType.get_type(forked) == :array
      assert ContentType.get_content(original) == ContentType.get_content(forked)
    end

    test "ContentType :map envelope survives fork" do
      template = mint_template()
      forked_uuid = Fork.fork_directory(template.template_dir_uuid)
      {:ok, %{"_state" => forked_state}} = Lookup.extract_named_children(forked_uuid, ["_state"])

      original = load(template.state_uuid)
      forked = load(forked_state)

      assert ContentType.get_type(original) == :map
      assert ContentType.get_type(forked) == :map
      assert ContentType.get_content(original) == ContentType.get_content(forked)
    end

    test "RedLog seed envelope survives fork (empty-seed case is harmless)" do
      template = mint_template()
      forked_uuid = Fork.fork_directory(template.template_dir_uuid)
      {:ok, %{"_audit" => forked_audit}} = Lookup.extract_named_children(forked_uuid, ["_audit"])

      original = load(template.audit_uuid)
      forked = load(forked_audit)

      # Both should have the "events" YArray type and be empty.
      assert Yelixer.Types.Array.to_list(original, "events") == []
      assert Yelixer.Types.Array.to_list(forked, "events") == []
    end

    test "ContentType :text envelope survives fork" do
      template = mint_template()

      # Seed the text doc with content first so we can verify preservation.
      view_doc = load(template.view_uuid)
      view_doc = ContentType.insert_text(view_doc, 0, "<view>seed content</view>")
      update = Encoding.encode_update(view_doc)
      CommitStoreClient.create_chained_commit(template.view_uuid, update)

      forked_uuid = Fork.fork_directory(template.template_dir_uuid)

      {:ok, %{"_view.xml" => forked_view}} =
        Lookup.extract_named_children(forked_uuid, ["_view.xml"])

      original_content = ContentType.get_content(load(template.view_uuid))
      forked_content = ContentType.get_content(load(forked_view))

      assert original_content == forked_content
      assert original_content == "<view>seed content</view>"
    end

    test "schema entries point at new UUIDs (deep-copy structural correctness)" do
      template = mint_template()
      forked_uuid = Fork.fork_directory(template.template_dir_uuid)

      forked_doc = load(forked_uuid)
      entries = Schema.list_entries(forked_doc) |> Enum.map(& &1.node_id) |> MapSet.new()

      original_uuids =
        MapSet.new([
          template.data_uuid,
          template.state_uuid,
          template.audit_uuid,
          template.view_uuid
        ])

      assert MapSet.disjoint?(entries, original_uuids),
             "forked schema must reference new UUIDs, not original child UUIDs"
    end
  end

  describe "fork_directory + Tree.Lookup compose cleanly" do
    test "instantiate-then-lookup workflow on synthetic template" do
      template = mint_template()

      # Simulate M4 (iii)'s chat-room flow on a non-chat template:
      # 1. Fork the template
      # 2. Use Tree.Lookup.extract_named_children to pull sub-doc UUIDs
      forked_uuid = Fork.fork_directory(template.template_dir_uuid)

      assert {:ok, children} =
               Lookup.extract_named_children(forked_uuid, [
                 "_data",
                 "_state",
                 "_audit",
                 "_view.xml"
               ])

      # Sanity: all 4 forked sub-docs are present and distinct from original.
      assert map_size(children) == 4
      Enum.each(children, fn {_, uuid} -> assert is_binary(uuid) end)
    end
  end
end
