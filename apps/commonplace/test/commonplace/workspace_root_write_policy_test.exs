defmodule Commonplace.WorkspaceRootWritePolicyTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Commonplace.Bd.Workspace, as: BdWorkspace
  alias Commonplace.Chat.TemplateBootstrap
  alias Commonplace.Scheduler.Agent, as: SchedulerAgent
  alias Commonplace.Store.{CommitStore, CommitStoreClient}
  alias Commonplace.Sync.Watcher
  alias Commonplace.Tree.{DocBuilder, Schema}
  alias Commonplace.Workspace
  alias Yelixer.Encoding

  setup do
    data_dir =
      Path.join(System.tmp_dir!(), "cp_root_policy_#{System.unique_integer([:positive])}")

    checkout_dir = Path.join(data_dir, "checkout")
    File.mkdir_p!(checkout_dir)

    store = :"root_policy_store_#{System.unique_integer([:positive])}"
    start_supervised!({CommitStore, data_dir: data_dir, name: store})

    prior_data_dir = Application.get_env(:commonplace, :data_dir)
    Application.put_env(:commonplace, :data_dir, data_dir)

    on_exit(fn ->
      Application.put_env(:commonplace, :data_dir, prior_data_dir || "tmp/test_data")
      File.rm_rf!(data_dir)
    end)

    %{data_dir: data_dir, checkout_dir: checkout_dir, store: store}
  end

  test "minimal refuses boot chat and lazy bd for its lifetime", ctx do
    root = initialize!(ctx, :minimal)
    prior_log_level = Logger.level()
    Logger.configure(level: :info)

    log =
      try do
        capture_log([level: :info], fn ->
          assert :ok =
                   Commonplace.Application.ensure_chat_template_if_workspace_present(
                     store: ctx.store
                   )

          assert :ok =
                   Commonplace.Application.ensure_chat_template_if_workspace_present(
                     store: ctx.store
                   )

          for _ <- 1..2 do
            _ = BdWorkspace.ensure_bd_dir(root, ctx.store)
          end
        end)
      after
        Logger.configure(level: prior_log_level)
      end

    assert log =~ "workspace class 'minimal' does not accept root entry 'chat'"
    assert log =~ "workspace class 'minimal' does not accept root entry 'bd'"

    root_doc = load_schema(ctx.store, root)
    assert :error = Schema.get_entry(root_doc, "chat")
    assert :error = Schema.get_entry(root_doc, "bd")
    assert {:ok, :minimal} = Workspace.profile(root, ctx.store)
  end

  test "minimal chokepoint refuses scheduler mount without scheduler policy code", ctx do
    root = initialize!(ctx, :minimal)
    name = :"root_policy_scheduler_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      SchedulerAgent.start_link(store: ctx.store, root_uuid: root, name: name)

    on_exit(fn ->
      try do
        GenServer.stop(pid)
      catch
        :exit, _reason -> :ok
      end
    end)

    assert :error = Schema.get_entry(load_schema(ctx.store, root), "__system")
  end

  test "minimal refuses root __processes.json through the gated-write channel", ctx do
    root = initialize!(ctx, :minimal)
    process_uuid = UUID.uuid4()

    assert %Commonplace.Store.Commit{} =
             CommitStoreClient.create_chained_commit(
               ctx.store,
               process_uuid,
               Encoding.encode_update(Yelixer.Doc.new())
             )

    root_doc = load_schema(ctx.store, root)
    updated = Schema.add_file(root_doc, "__processes.json", process_uuid)

    assert {:error, {:trust_rejected, reason}} =
             CommitStoreClient.create_chained_commit(
               ctx.store,
               root,
               Encoding.encode_update(updated)
             )

    assert reason ==
             "workspace class 'minimal' does not accept root entry '__processes.json' — declared in profile"

    assert :error = Schema.get_entry(load_schema(ctx.store, root), "__processes.json")
  end

  test "sync-import lands a real cell-world root shape in a minimal workspace", ctx do
    root = initialize!(ctx, :minimal)
    world_dir = Path.join(ctx.checkout_dir, "cell-world")

    File.mkdir_p!(Path.join(world_dir, "apps/demo/lib"))
    File.write!(Path.join(world_dir, "mix.exs"), "defmodule Cell.MixProject do\nend\n")
    File.write!(Path.join(world_dir, "README.md"), "# Cell world\n")
    File.write!(Path.join(world_dir, "apps/demo/mix.exs"), "# nested app\n")
    File.write!(Path.join(world_dir, "apps/demo/lib/demo.ex"), "defmodule Demo do\nend\n")

    _report = Watcher.sync_recursive(root, world_dir, ctx.store)

    root_doc = load_schema(ctx.store, root)
    assert {:ok, mix_entry} = Schema.get_entry(root_doc, "mix.exs")
    assert {:ok, readme_entry} = Schema.get_entry(root_doc, "README.md")
    assert {:ok, apps_entry} = Schema.get_entry(root_doc, "apps")
    assert read_text(ctx.store, mix_entry.node_id) == "defmodule Cell.MixProject do\nend\n"
    assert read_text(ctx.store, readme_entry.node_id) == "# Cell world\n"

    apps_doc = load_schema(ctx.store, apps_entry.node_id)
    assert {:ok, demo_entry} = Schema.get_entry(apps_doc, "demo")
    demo_doc = load_schema(ctx.store, demo_entry.node_id)
    assert {:ok, nested_mix_entry} = Schema.get_entry(demo_doc, "mix.exs")
    assert {:ok, lib_entry} = Schema.get_entry(demo_doc, "lib")
    assert read_text(ctx.store, nested_mix_entry.node_id) == "# nested app\n"

    lib_doc = load_schema(ctx.store, lib_entry.node_id)
    assert {:ok, demo_source_entry} = Schema.get_entry(lib_doc, "demo.ex")
    assert read_text(ctx.store, demo_source_entry.node_id) == "defmodule Demo do\nend\n"
  end

  test "unregistered dunder root entries are refused for every workspace class", ctx do
    for profile <- [:default, :minimal] do
      root = initialize!(ctx, profile)

      assert {:error, {:trust_rejected, reason}} = attach_file(ctx.store, root, "__futurething")

      assert reason ==
               "workspace class '#{profile}' does not accept root entry '__futurething' — declared in profile"

      assert :error = Schema.get_entry(load_schema(ctx.store, root), "__futurething")
    end
  end

  test "minimal refuses a registered substrate name and names its class and entry", ctx do
    root = initialize!(ctx, :minimal)

    assert {:error, {:trust_rejected, reason}} = attach_file(ctx.store, root, "bd")

    assert reason ==
             "workspace class 'minimal' does not accept root entry 'bd' — declared in profile"

    assert :error = Schema.get_entry(load_schema(ctx.store, root), "bd")
  end

  test "minimal checks only entries added by this root commit", ctx do
    root = initialize!(ctx, :minimal)

    assert %Commonplace.Store.Commit{} = attach_file(ctx.store, root, "mix.exs")

    root_doc = load_schema(ctx.store, root)

    assert %Commonplace.Store.Commit{} =
             CommitStoreClient.create_chained_commit(
               ctx.store,
               root,
               Encoding.encode_update(root_doc)
             )

    assert {:ok, _entry} = Schema.get_entry(load_schema(ctx.store, root), "mix.exs")
  end

  test "default and legacy-absent workspaces retain the same root entries", ctx do
    default_root = initialize!(ctx, :default)
    assert {:ok, :default} = Workspace.profile(default_root, ctx.store)

    assert :ok = TemplateBootstrap.ensure_template(default_root, store: ctx.store)
    _bd_uuid = BdWorkspace.ensure_bd_dir(default_root, ctx.store)
    default_entries = Schema.entries(load_schema(ctx.store, default_root))
    assert {:ok, :default} = Workspace.profile(default_root, ctx.store)

    legacy_root = UUID.uuid4()

    assert %Commonplace.Store.Commit{} =
             CommitStoreClient.create_chained_commit(
               ctx.store,
               legacy_root,
               Encoding.encode_update(Schema.new_schema())
             )

    File.write!(Path.join(ctx.data_dir, "root"), legacy_root)
    assert :absent = Workspace.profile(legacy_root, ctx.store)
    assert :ok = TemplateBootstrap.ensure_template(legacy_root, store: ctx.store)
    _bd_uuid = BdWorkspace.ensure_bd_dir(legacy_root, ctx.store)
    assert :absent = Workspace.profile(legacy_root, ctx.store)

    assert entry_shape(Schema.entries(load_schema(ctx.store, legacy_root))) ==
             entry_shape(default_entries)
  end

  test "initialize records a readable profile for both workspace classes", ctx do
    minimal_root = initialize!(ctx, :minimal)
    assert {:ok, :minimal} = Workspace.profile(minimal_root, ctx.store)

    default_root = initialize!(ctx, :default)
    assert {:ok, :default} = Workspace.profile(default_root, ctx.store)
  end

  defp initialize!(ctx, profile) do
    checkout_dir =
      Path.join(ctx.checkout_dir, "#{profile}-#{System.unique_integer([:positive])}")

    File.mkdir_p!(checkout_dir)

    {:ok, initialized} =
      Workspace.initialize(ctx.data_dir,
        store: ctx.store,
        checkout_dir: checkout_dir,
        profile: profile
      )

    initialized.root_uuid
  end

  defp load_schema(store, uuid) do
    {:ok, doc} = DocBuilder.reconstruct_snapshot(store, uuid)
    doc
  end

  defp attach_file(store, root, name) do
    root_doc = load_schema(store, root)
    updated = Schema.add_file(root_doc, name, UUID.uuid4())

    CommitStoreClient.create_chained_commit(store, root, Encoding.encode_update(updated))
  end

  defp read_text(store, uuid) do
    {:ok, doc} = DocBuilder.reconstruct_snapshot(store, uuid)
    Commonplace.Document.ContentType.get_content(doc)
  end

  defp entry_shape(entries) do
    Map.new(entries, fn {name, entry} -> {name, Map.drop(entry, ["node_id"])} end)
  end
end
