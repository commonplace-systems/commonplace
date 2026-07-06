defmodule Commonplace.GitBridge.ServerTest do
  use ExUnit.Case, async: false

  alias Commonplace.GitBridge.Server
  alias Commonplace.Tree.Schema
  alias Commonplace.Document.ContentType
  alias Commonplace.Store.CommitStore
  alias Commonplace.Presence
  alias Commonplace.Dataflow.PubSub
  alias Commonplace.Crypto.{Signing, SigningContext}
  alias Commonplace.GitBridge.CanonicalXml
  alias Yelixer.Types.{XMLFragment, XMLElement, XMLText}

  setup do
    store_dir = Path.join(System.tmp_dir!(), "cp_gb_server_store_#{:rand.uniform(1_000_000_000)}")
    repo_dir = Path.join(System.tmp_dir!(), "cp_gb_server_repo_#{:rand.uniform(1_000_000_000)}")
    workspace_dir = Path.join(System.tmp_dir!(), "cp_gb_server_ws_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(store_dir)
    File.mkdir_p!(repo_dir)
    File.mkdir_p!(workspace_dir)

    store_name = :"gb_server_store_#{:rand.uniform(1_000_000_000)}"
    start_supervised!({CommitStore, data_dir: store_dir, name: store_name})

    prev_data_dir = Application.get_env(:commonplace, :data_dir)

    on_exit(fn ->
      File.rm_rf!(store_dir)
      File.rm_rf!(repo_dir)
      File.rm_rf!(workspace_dir)

      if prev_data_dir do
        Application.put_env(:commonplace, :data_dir, prev_data_dir)
      else
        Application.delete_env(:commonplace, :data_dir)
      end
    end)

    %{store: store_name, repo_dir: repo_dir, workspace_dir: workspace_dir}
  end

  defp create_text(store, uuid, name, content) do
    doc = Yelixer.Doc.new()
    doc = ContentType.create(doc, :text, name)
    doc = ContentType.insert_text(doc, 0, content)
    update = Yelixer.Encoding.encode_update(doc)
    CommitStore.create_commit(store, uuid, update, nil)
  end

  defp create_map(store, uuid, name, map) do
    doc = Yelixer.Doc.new()
    doc = ContentType.create(doc, :map, name)
    doc = Enum.reduce(map, doc, fn {k, v}, acc -> ContentType.set_key(acc, k, v) end)
    update = Yelixer.Encoding.encode_update(doc)
    CommitStore.create_commit(store, uuid, update, nil)
  end

  # An outliner-shaped `:xml` doc: a flat bag of `<item>` elements each
  # carrying a map-ordering-hostile attribute set (CX-b0ow.5's canonical
  # XML render pin — attrs must sort byte-stably regardless of the
  # underlying map's enumeration order).
  defp create_xml_outline(store, uuid, name) do
    doc = Yelixer.Doc.new()
    doc = ContentType.create(doc, :xml, name)
    doc = XMLFragment.insert_child(doc, "content", 0, {:element, "item"})

    [{:element, _, item_name}] = XMLFragment.to_list(doc, "content")

    doc =
      Enum.reduce(
        [
          {"id", "1"},
          {"parent", "root"},
          {"order", "a0"},
          {"collapsed", "false"},
          {"a", "1"},
          {"b", "2"},
          {"c", "3"},
          {"d", "4"},
          {"e", "5"},
          {"f", "6"}
        ],
        doc,
        fn {k, v}, acc -> XMLElement.set_attribute(acc, item_name, k, v) end
      )

    doc = XMLElement.insert_child(doc, item_name, 0, :text)
    [{:text, text_name}] = XMLElement.children(doc, item_name)
    doc = XMLText.insert(doc, text_name, 0, "first bullet")

    update = Yelixer.Encoding.encode_update(doc)
    CommitStore.create_commit(store, uuid, update, nil)
  end

  defp create_signed_text(store, uuid, name, content) do
    {pub, priv} = Signing.generate_keypair()
    signer_id = Signing.signer_id("author-uuid", pub)

    ctx = %SigningContext{identity_uuid: "author-uuid", private_key: priv, public_key: pub}

    doc = Yelixer.Doc.new()
    doc = ContentType.create(doc, :text, name)
    doc = ContentType.insert_text(doc, 0, content)
    update = Yelixer.Encoding.encode_update(doc)
    CommitStore.create_commit(store, uuid, update, nil, %{}, signing_context: ctx)
    signer_id
  end

  defp create_schema(store, uuid, schema_doc) do
    update = Yelixer.Encoding.encode_update(schema_doc)
    CommitStore.create_commit(store, uuid, update, nil)
  end

  defp chain_schema(store, uuid, schema_doc) do
    update = Yelixer.Encoding.encode_update(schema_doc)
    CommitStore.create_chained_commit(store, uuid, update)
  end

  defp put_workspace_root(workspace_dir, root_uuid) do
    Application.put_env(:commonplace, :data_dir, workspace_dir)
    File.write!(Path.join(workspace_dir, "root"), root_uuid)
  end

  defp unique_name(prefix), do: :"#{prefix}_#{:rand.uniform(1_000_000_000)}"

  # Seeds: real workspace root -> "workspace" dir -> mount schema, with a
  # small tree under the mount: a text doc, a map doc, a nested dir with a
  # file, a __system entry, a nosync entry, and a human presence file.
  defp seed_tree(store, workspace_dir) do
    root_uuid = "root-uuid-#{:rand.uniform(1_000_000_000)}"
    mount_uuid = "mount-uuid-#{:rand.uniform(1_000_000_000)}"
    sub_uuid = "sub-uuid-#{:rand.uniform(1_000_000_000)}"

    create_text(store, "doc-a", "a.txt", "hello world")
    create_map(store, "doc-b", "b.json", %{"k" => "v"})
    signer_id = create_signed_text(store, "doc-signed", "signed.txt", "signed content")
    create_text(store, "doc-nosync", "nosync.txt", "should not appear")
    create_text(store, "doc-sys", "__system", "should not appear")
    create_text(store, "doc-nested", "nested.txt", "deep")
    create_xml_outline(store, "doc-outline", "_outline")

    {:ok, _presence_uuid} = Presence.create("alice", :usr, mount_uuid, store)

    sub_schema = Schema.new_schema() |> Schema.add_file("nested.txt", "doc-nested")
    create_schema(store, sub_uuid, sub_schema)

    mount_schema =
      Schema.new_schema()
      |> Schema.add_file("a.txt", "doc-a")
      |> Schema.add_file("b.json", "doc-b")
      |> Schema.add_file("signed.txt", "doc-signed")
      |> Schema.add_file("nosync.txt", "doc-nosync")
      |> Schema.set_sync("nosync.txt", false)
      |> Schema.add_file("__system", "doc-sys")
      |> Schema.add_file("_outline", "doc-outline")
      |> Schema.add_directory("nested", sub_uuid)

    create_schema(store, mount_uuid, mount_schema)

    root_schema = Schema.new_schema() |> Schema.add_directory("workspace", mount_uuid)
    create_schema(store, root_uuid, root_schema)

    put_workspace_root(workspace_dir, root_uuid)

    %{root_uuid: root_uuid, mount_uuid: mount_uuid, signer_id: signer_id}
  end

  test "full first cycle exports eligible files, sidecar, gitattributes, single signed commit", %{
    store: store,
    repo_dir: repo_dir,
    workspace_dir: workspace_dir
  } do
    %{mount_uuid: mount_uuid, signer_id: signer_id} = seed_tree(store, workspace_dir)

    name = unique_name("gb_server1")

    {:ok, _pid} =
      Server.start_link(
        mount_uuid: mount_uuid,
        repo_dir: repo_dir,
        store: store,
        interval_ms: 3_600_000,
        name: name
      )

    on_exit(fn -> if Process.whereis(name), do: GenServer.stop(name) end)

    {:ok, result} = Server.sync_now(name)
    assert result.committed == true

    # GitBridge G1.5 (CX-b0ow.4): the archive row count rides the same
    # :committed event metadata as sha/manifest_size/warnings.
    assert is_integer(result.archived_count)
    assert result.archived_count > 0
    assert File.exists?(Path.join(repo_dir, ".commonplace/archive/watermarks.json"))

    assert File.read!(Path.join(repo_dir, "a.txt")) == "hello world"
    assert Jason.decode!(File.read!(Path.join(repo_dir, "b.json"))) == %{"k" => "v"}
    assert File.read!(Path.join(repo_dir, "signed.txt")) == "signed content"
    assert File.read!(Path.join(repo_dir, "nested/nested.txt")) == "deep"

    # CX-b0ow.5: xml docs render as canonical XML text, not JSON-of-tree.
    outline_content = File.read!(Path.join(repo_dir, "_outline"))
    assert outline_content =~ ~r/^<item /
    assert outline_content =~ "first bullet"
    assert outline_content =~ ~s(a="1")
    refute outline_content =~ "\"tag\""
    assert result.warnings == []

    refute File.exists?(Path.join(repo_dir, "nosync.txt"))
    refute File.exists?(Path.join(repo_dir, "__system"))
    refute File.exists?(Path.join(repo_dir, "alice.usr"))
    refute File.exists?(Path.join(repo_dir, "git-bridge.bot"))

    assert File.exists?(Path.join(repo_dir, ".commonplace/a.txt.json"))
    assert File.exists?(Path.join(repo_dir, ".commonplace/mount.json"))
    assert File.read!(Path.join(repo_dir, ".gitattributes")) =~ ".commonplace/** -diff"

    {log, 0} = System.cmd("git", ["log", "--oneline"], cd: repo_dir)
    assert length(String.split(String.trim(log), "\n")) == 1

    {body, 0} = System.cmd("git", ["log", "-1", "--pretty=%B"], cd: repo_dir)
    assert body =~ "Commonplace-Authors:"
    assert body =~ signer_id

    {author, 0} = System.cmd("git", ["log", "-1", "--pretty=%an <%ae>"], cd: repo_dir)
    assert String.trim(author) == "commonplace-bridge <bridge@commonplace.local>"
  end

  test "phantom-diff pin: second sync_now with no store changes makes no new commit", %{
    store: store,
    repo_dir: repo_dir,
    workspace_dir: workspace_dir
  } do
    %{mount_uuid: mount_uuid} = seed_tree(store, workspace_dir)
    name = unique_name("gb_server2")

    {:ok, _pid} =
      Server.start_link(
        mount_uuid: mount_uuid,
        repo_dir: repo_dir,
        store: store,
        interval_ms: 3_600_000,
        name: name
      )

    on_exit(fn -> if Process.whereis(name), do: GenServer.stop(name) end)

    {:ok, _} = Server.sync_now(name)
    {log1, 0} = System.cmd("git", ["log", "--oneline"], cd: repo_dir)
    count1 = length(String.split(String.trim(log1), "\n"))
    assert count1 == 1

    {:ok, result2} = Server.sync_now(name)
    assert result2.committed == false

    {log2, 0} = System.cmd("git", ["log", "--oneline"], cd: repo_dir)
    count2 = length(String.split(String.trim(log2), "\n"))
    assert count2 == count1

    {status, 0} = System.cmd("git", ["status", "--porcelain"], cd: repo_dir)
    assert String.trim(status) == ""
  end

  test "incremental: content change and entry removal each yield exactly one new commit", %{
    store: store,
    repo_dir: repo_dir,
    workspace_dir: workspace_dir
  } do
    %{mount_uuid: mount_uuid} = seed_tree(store, workspace_dir)
    name = unique_name("gb_server3")

    {:ok, _pid} =
      Server.start_link(
        mount_uuid: mount_uuid,
        repo_dir: repo_dir,
        store: store,
        interval_ms: 3_600_000,
        name: name
      )

    on_exit(fn -> if Process.whereis(name), do: GenServer.stop(name) end)

    {:ok, _} = Server.sync_now(name)
    {log1, 0} = System.cmd("git", ["log", "--oneline"], cd: repo_dir)
    count1 = length(String.split(String.trim(log1), "\n"))

    # Change doc-a's content with a new chained commit, mutating the
    # SAME reconstructed doc (a brand new Yelixer.Doc would concurrently
    # merge its insert rather than replace the existing text).
    {:ok, doc} = Commonplace.Tree.DocBuilder.reconstruct_doc(store, "doc-a")
    existing = ContentType.get_content(doc) || ""
    doc = ContentType.delete_text(doc, 0, String.length(existing))
    doc = ContentType.insert_text(doc, 0, "updated content")
    update = Yelixer.Encoding.encode_update(doc)
    CommitStore.create_chained_commit(store, "doc-a", update)

    {:ok, result2} = Server.sync_now(name)
    assert result2.committed == true
    assert File.read!(Path.join(repo_dir, "a.txt")) == "updated content"

    {log2, 0} = System.cmd("git", ["log", "--oneline"], cd: repo_dir)
    count2 = length(String.split(String.trim(log2), "\n"))
    assert count2 == count1 + 1

    # Now remove b.json from the mount schema.
    {:ok, mount_doc} =
      Commonplace.Tree.DocBuilder.reconstruct_snapshot(store, mount_uuid)

    mount_doc = Schema.remove_entry(mount_doc, "b.json")
    chain_schema(store, mount_uuid, mount_doc)

    {:ok, result3} = Server.sync_now(name)
    assert result3.committed == true
    refute File.exists?(Path.join(repo_dir, "b.json"))
    refute File.exists?(Path.join(repo_dir, ".commonplace/b.json.json"))

    {log3, 0} = System.cmd("git", ["log", "--oneline"], cd: repo_dir)
    count3 = length(String.split(String.trim(log3), "\n"))
    assert count3 == count2 + 1
  end

  test "filters: __ / nosync / presence files never appear across two cycles", %{
    store: store,
    repo_dir: repo_dir,
    workspace_dir: workspace_dir
  } do
    %{mount_uuid: mount_uuid} = seed_tree(store, workspace_dir)
    name = unique_name("gb_server4")

    {:ok, _pid} =
      Server.start_link(
        mount_uuid: mount_uuid,
        repo_dir: repo_dir,
        store: store,
        interval_ms: 3_600_000,
        name: name
      )

    on_exit(fn -> if Process.whereis(name), do: GenServer.stop(name) end)

    {:ok, _} = Server.sync_now(name)
    refute File.exists?(Path.join(repo_dir, "nosync.txt"))
    refute File.exists?(Path.join(repo_dir, "__system"))
    refute File.exists?(Path.join(repo_dir, "alice.usr"))

    {:ok, _} = Server.sync_now(name)
    refute File.exists?(Path.join(repo_dir, "nosync.txt"))
    refute File.exists?(Path.join(repo_dir, "__system"))
    refute File.exists?(Path.join(repo_dir, "alice.usr"))
  end

  test "reachability halt: unlinking mount from parent halts the bridge with no new commit", %{
    store: store,
    repo_dir: repo_dir,
    workspace_dir: workspace_dir
  } do
    %{root_uuid: root_uuid, mount_uuid: mount_uuid} = seed_tree(store, workspace_dir)
    name = unique_name("gb_server5")

    {:ok, _pid} =
      Server.start_link(
        mount_uuid: mount_uuid,
        repo_dir: repo_dir,
        store: store,
        interval_ms: 3_600_000,
        name: name
      )

    on_exit(fn -> if Process.whereis(name), do: GenServer.stop(name) end)

    {:ok, result1} = Server.sync_now(name)
    assert result1.committed == true

    {log1, 0} = System.cmd("git", ["log", "--oneline"], cd: repo_dir)
    count1 = length(String.split(String.trim(log1), "\n"))

    {:ok, root_doc} = Commonplace.Tree.DocBuilder.reconstruct_snapshot(store, root_uuid)
    root_doc = Schema.remove_entry(root_doc, "workspace")
    chain_schema(store, root_uuid, root_doc)

    PubSub.subscribe_red(mount_uuid)

    {:ok, result2} = Server.sync_now(name)
    assert result2 == :halted

    assert_receive {"red:" <> _, {:git_bridge, :halted, _reason}}, 1_000

    {log2, 0} = System.cmd("git", ["log", "--oneline"], cd: repo_dir)
    count2 = length(String.split(String.trim(log2), "\n"))
    assert count2 == count1

    status = Server.status(name)
    assert status.halted == true
  end

  test "pause/resume: paused sync_now is a no-op, resumed sync_now works, both events broadcast", %{
    store: store,
    repo_dir: repo_dir,
    workspace_dir: workspace_dir
  } do
    %{mount_uuid: mount_uuid} = seed_tree(store, workspace_dir)
    name = unique_name("gb_server6")

    {:ok, _pid} =
      Server.start_link(
        mount_uuid: mount_uuid,
        repo_dir: repo_dir,
        store: store,
        interval_ms: 3_600_000,
        name: name
      )

    on_exit(fn -> if Process.whereis(name), do: GenServer.stop(name) end)

    PubSub.subscribe_red(mount_uuid)

    :ok = Server.pause(name)
    assert_receive {"red:" <> _, {:git_bridge, :paused, _}}, 1_000

    {:ok, result} = Server.sync_now(name)
    assert result == :paused
    refute File.exists?(Path.join(repo_dir, "a.txt"))

    :ok = Server.resume(name)
    assert_receive {"red:" <> _, {:git_bridge, :resumed, _}}, 1_000

    {:ok, result2} = Server.sync_now(name)
    assert result2.committed == true
    assert File.exists?(Path.join(repo_dir, "a.txt"))
  end

  test "push: succeeds against a real bare remote", %{
    store: store,
    repo_dir: repo_dir,
    workspace_dir: workspace_dir
  } do
    %{mount_uuid: mount_uuid} = seed_tree(store, workspace_dir)

    bare_dir = Path.join(System.tmp_dir!(), "cp_gb_bare_#{:rand.uniform(1_000_000_000)}")
    on_exit(fn -> File.rm_rf!(bare_dir) end)
    File.mkdir_p!(bare_dir)
    {_, 0} = System.cmd("git", ["init", "--bare", bare_dir])

    name = unique_name("gb_server7")

    {:ok, _pid} =
      Server.start_link(
        mount_uuid: mount_uuid,
        repo_dir: repo_dir,
        store: store,
        remote: bare_dir,
        branch: "main",
        interval_ms: 3_600_000,
        name: name
      )

    on_exit(fn -> if Process.whereis(name), do: GenServer.stop(name) end)

    PubSub.subscribe_red(mount_uuid)

    {:ok, result} = Server.sync_now(name)
    assert result.committed == true

    assert_receive {"red:" <> _, {:git_bridge, :pushed, _}}, 1_000

    # Name the ref explicitly: the bare repo's default HEAD branch is
    # host-config-dependent (master under a bare CI runner, main under
    # a configured dev box), and the bridge pushes "main".
    {log, 0} = System.cmd("git", ["log", "-1", "--pretty=%H", "main"], cd: bare_dir)
    assert String.trim(log) != ""
  end

  test "push: failure to an unreachable remote never crashes the server and retries", %{
    store: store,
    repo_dir: repo_dir,
    workspace_dir: workspace_dir
  } do
    %{mount_uuid: mount_uuid} = seed_tree(store, workspace_dir)
    name = unique_name("gb_server8")

    {:ok, pid} =
      Server.start_link(
        mount_uuid: mount_uuid,
        repo_dir: repo_dir,
        store: store,
        remote: "/nonexistent/path/repo.git",
        branch: "main",
        interval_ms: 3_600_000,
        name: name
      )

    on_exit(fn -> if Process.whereis(name), do: GenServer.stop(name) end)

    PubSub.subscribe_red(mount_uuid)

    {:ok, result} = Server.sync_now(name)
    assert result.committed == true
    assert_receive {"red:" <> _, {:git_bridge, :push_failed, _}}, 1_000
    assert Process.alive?(pid)

    # Second cycle: nothing changed, so no commit, but the server must
    # still tolerate a configured-but-unreachable remote without crashing.
    {:ok, result2} = Server.sync_now(name)
    assert result2.committed == false
    assert Process.alive?(pid)
  end
end
