defmodule Commonplace.Chat.TemplateBootstrapTest do
  @moduledoc """
  CX-38fw (sub-bead i of CX-jfwv M4): tests for the chat-room template
  bootstrap.

  Per the M4 spec held position #2 + Q2: boot-time idempotent ensure
  mints `/chat/__template/` with the 4 canonical empty-seed sub-docs
  on first boot; subsequent boots no-op (idempotence).

  Per spec held position #7 + jes refinement: template lives at
  `/chat/__template/` (chat-tier per-app namespace, NOT centralized
  `/__templates/`). The `__template` name is already blocked by chat's
  existing `_`-prefix validation rule (no new rule code needed).
  """
  use ExUnit.Case, async: false

  alias Commonplace.Chat.{ChatViewBuilder, Rooms, TemplateBootstrap}
  alias Commonplace.Document.{ContentType, ViewXml}
  alias Commonplace.Store.{CommitStore, CommitStoreClient}
  alias Commonplace.Tree.{DocBuilder, Schema}

  setup do
    # Restore to test-config default in on_exit per the race fix
    # (commit 90f9832 — captured-prior is racy under parallel async:false).
    dir = Path.join(System.tmp_dir!(), "cp_template_bootstrap_#{:rand.uniform(1_000_000_000)}")
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

    root_uuid = UUID.uuid4()
    root_doc = Schema.new_schema()
    update = Yelixer.Encoding.encode_update(root_doc)
    CommitStore.create_commit(Commonplace.Store.CommitStore, root_uuid, update, nil)

    Commonplace.Test.WorkspaceFixture.complete_workspace!(dir,
      store: Commonplace.Store.CommitStore
    )

    File.write!(Path.join(dir, "root"), root_uuid)

    %{root: root_uuid}
  end

  defp load_schema(uuid) do
    case DocBuilder.reconstruct_snapshot(CommitStoreClient, uuid) do
      {:ok, doc} -> doc
      :none -> Schema.new_schema()
    end
  end

  defp lookup_template(root_uuid) do
    chat_doc = load_schema_for_path(root_uuid, "chat")
    Schema.get_entry(chat_doc, "__template")
  end

  defp load_schema_for_path(root_uuid, name) do
    root_doc = load_schema(root_uuid)

    case Schema.get_entry(root_doc, name) do
      {:ok, entry} -> load_schema(entry.node_id)
      :error -> Schema.new_schema()
    end
  end

  describe "ensure_template/2 — first boot mints the template" do
    test "creates /chat/__template/ with all 4 canonical sub-docs", %{root: root} do
      assert :ok = TemplateBootstrap.ensure_template(root)

      # /chat dir minted
      root_doc = load_schema(root)
      assert {:ok, chat_entry} = Schema.get_entry(root_doc, "chat")

      # __template under /chat
      chat_doc = load_schema(chat_entry.node_id)
      assert {:ok, template_entry} = Schema.get_entry(chat_doc, "__template")

      # 4 canonical sub-docs under /chat/__template/
      template_doc = load_schema(template_entry.node_id)
      assert {:ok, _} = Schema.get_entry(template_doc, "_messages")
      assert {:ok, _} = Schema.get_entry(template_doc, "_reactions")
      assert {:ok, _} = Schema.get_entry(template_doc, "_messages.log")
      assert {:ok, _} = Schema.get_entry(template_doc, "_view.xml")
    end

    test "_view.xml content matches ChatViewBuilder.build_view_xml([], '__template')",
         %{root: root} do
      :ok = TemplateBootstrap.ensure_template(root)

      {:ok, template_entry} = lookup_template(root)
      template_doc = load_schema(template_entry.node_id)
      {:ok, view_entry} = Schema.get_entry(template_doc, "_view.xml")

      {:ok, view_doc} = DocBuilder.reconstruct_snapshot(CommitStoreClient, view_entry.node_id)
      content = ContentType.get_content(view_doc) || ""

      assert content == ChatViewBuilder.build_view_xml([], "__template")
      assert {:ok, %ViewXml.Node{tag: :view}} = ViewXml.parse(content)
    end
  end

  describe "ensure_template/2 — Anchor I idempotence" do
    test "second call is a no-op (no new commits to template)", %{root: root} do
      assert :ok = TemplateBootstrap.ensure_template(root)

      {:ok, template_entry_1} = lookup_template(root)
      template_uuid = template_entry_1.node_id

      latest_before =
        CommitStoreClient.latest_commit(CommitStoreClient, template_uuid)

      assert :ok = TemplateBootstrap.ensure_template(root)

      {:ok, template_entry_2} = lookup_template(root)

      assert template_entry_2.node_id == template_uuid,
             "template UUID must not change across boots"

      latest_after =
        CommitStoreClient.latest_commit(CommitStoreClient, template_uuid)

      assert latest_after == latest_before,
             "template's latest commit must not change on idempotent re-ensure"
    end

    test "N calls produce 1 set of commits", %{root: root} do
      for _ <- 1..5, do: :ok = TemplateBootstrap.ensure_template(root)

      {:ok, template_entry} = lookup_template(root)
      template_doc = load_schema(template_entry.node_id)

      # 4 sub-docs total — no duplicates from re-ensures
      assert {:ok, _} = Schema.get_entry(template_doc, "_messages")
      assert {:ok, _} = Schema.get_entry(template_doc, "_reactions")
      assert {:ok, _} = Schema.get_entry(template_doc, "_messages.log")
      assert {:ok, _} = Schema.get_entry(template_doc, "_view.xml")
    end
  end

  describe "ensure_template/2 — name validation already blocks __template as a room" do
    test "Chat.Rooms.create('__template') is rejected by existing _-prefix rule",
         %{root: root} do
      :ok = TemplateBootstrap.ensure_template(root)

      assert {:error, :invalid_name} = Rooms.create(root, "__template")
    end
  end

  # CX-qbhb (M5 sub-bead i): _compute spec doc lives in the template
  # alongside the existing 4 sub-docs. Carries chain rules + render-fn
  # reference for the substrate ComputeSpec interpreter (sub-bead ii).
  describe "ensure_template/2 — _compute spec doc (M5 sub-bead i)" do
    test "mints _compute alongside the existing 4 sub-docs", %{root: root} do
      assert :ok = TemplateBootstrap.ensure_template(root)

      {:ok, template_entry} = lookup_template(root)
      template_doc = load_schema(template_entry.node_id)

      assert {:ok, compute_entry} = Schema.get_entry(template_doc, "_compute")
      assert is_binary(compute_entry.node_id)
    end

    test "_compute content carries chain rules + render-fn reference (M7 Elixir shape)",
         %{root: root} do
      :ok = TemplateBootstrap.ensure_template(root)

      {:ok, template_entry} = lookup_template(root)
      template_doc = load_schema(template_entry.node_id)
      {:ok, compute_entry} = Schema.get_entry(template_doc, "_compute")

      {:ok, compute_doc} =
        DocBuilder.reconstruct_snapshot(CommitStoreClient, compute_entry.node_id)

      content = ContentType.get_content(compute_doc) || ""

      # CX-9tj0 (M7 sub-bead iv): _compute body is Elixir source. Chain
      # rules expressed as author-friendly tuple form via Compute stdlib.
      assert content =~ "defmodule Commonplace.UserCode.Chat.Compute"
      assert content =~ "def compute(raw, ctx)"
      assert content =~ "Compute.decode_json_array"
      assert content =~ "Compute.materialize"

      # Chain rules — M7 author-facing tuple form
      assert content =~ "{:edit_of, :latest_replaces}"
      assert content =~ "{:tombstone_of, :marks_deleted}"

      # Render-fn called by name (chat-tier ChatViewBuilder)
      assert content =~ "Commonplace.Chat.ChatViewBuilder.build_view_xml"
      assert content =~ "ctx.room_name"
    end

    test "idempotence: re-ensure with existing template + _compute is a no-op",
         %{root: root} do
      :ok = TemplateBootstrap.ensure_template(root)

      {:ok, template_entry} = lookup_template(root)
      template_doc = load_schema(template_entry.node_id)
      {:ok, compute_entry_1} = Schema.get_entry(template_doc, "_compute")

      :ok = TemplateBootstrap.ensure_template(root)

      {:ok, template_entry_2} = lookup_template(root)
      template_doc_2 = load_schema(template_entry_2.node_id)
      {:ok, compute_entry_2} = Schema.get_entry(template_doc_2, "_compute")

      assert compute_entry_2.node_id == compute_entry_1.node_id,
             "idempotent re-ensure must not re-mint _compute"
    end
  end
end
