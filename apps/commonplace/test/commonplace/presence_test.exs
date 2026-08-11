defmodule Commonplace.PresenceTest do
  @moduledoc """
  Tests for presence files — actor business cards in the document tree.
  """
  use ExUnit.Case

  alias Commonplace.Presence
  alias Commonplace.Tree.Schema
  alias Commonplace.Store.CommitStore

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_presence_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    store_name = :"commit_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store_name})
    on_exit(fn -> File.rm_rf!(dir) end)

    # Create a root schema
    root_uuid = UUID.uuid4()
    root_doc = Schema.new_schema()
    update = Yelixer.Encoding.encode_update(root_doc)
    CommitStore.create_commit(store_name, root_uuid, update, nil)

    %{store: store_name, root: root_uuid}
  end

  describe "honorific extensions" do
    test "parses actor types" do
      assert Presence.parse_honorific("sync.exe") == {:ok, "sync", :exe}
      assert Presence.parse_honorific("jes.usr") == {:ok, "jes", :usr}
      assert Presence.parse_honorific("bartleby.bot") == {:ok, "bartleby", :bot}
      assert Presence.parse_honorific("unknown.who") == {:ok, "unknown", :who}
    end

    test "rejects invalid extensions" do
      assert Presence.parse_honorific("file.txt") == :error
      assert Presence.parse_honorific("noext") == :error
    end

    test "builds filename from name and type" do
      assert Presence.filename("sync", :exe) == "sync.exe"
      assert Presence.filename("jes", :usr) == "jes.usr"
      assert Presence.filename("claude", :bot) == "claude.bot"
    end
  end

  describe "creating presence" do
    test "creates a presence document in the schema", %{store: store, root: root} do
      {:ok, uuid} = Presence.create("myprocess", :exe, root, store)

      # Verify schema entry exists
      root_doc = load_schema(root, store)
      {:ok, entry} = Schema.get_entry(root_doc, "myprocess.exe")
      assert entry.type == :doc
      assert entry.node_id == uuid

      # Verify presence doc content
      {:ok, commit} = CommitStore.latest_commit(store, uuid)
      doc = Yelixer.Doc.new()
      {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)
      content = Commonplace.Document.ContentType.get_content(doc)
      assert content["name"] == "myprocess"
      assert content["type"] == "exe"
      assert content["status"] == "starting"
      assert is_binary(content["started_at"])
      assert content["lease_version"] == "1"
      assert content["lease_ttl_ms"] == Presence.default_lease_ttl_ms(:exe)
    end

    test "declares interactive and service TTL classes and honors an explicit owner term", %{
      store: store,
      root: root
    } do
      assert Presence.lease_class(:usr) == :interactive
      assert Presence.lease_class(:who) == :interactive
      assert Presence.default_lease_ttl_ms(:usr) == 30_000
      assert Presence.default_lease_ttl_ms(:who) == 30_000

      assert Presence.lease_class(:exe) == :service
      assert Presence.lease_class(:bot) == :service
      assert Presence.default_lease_ttl_ms(:exe) == 120_000
      assert Presence.default_lease_ttl_ms(:bot) == 120_000

      {:ok, uuid} = Presence.create("custom", :bot, root, store, lease_ttl_ms: 175_000)
      assert Presence.read(uuid, store)["lease_ttl_ms"] == 175_000
    end

    test "legacy-absent lease fields receive the declared temporal class default", %{
      store: store,
      root: root
    } do
      {:ok, uuid} = Presence.create("pre-v1", :bot, root, store)
      doc = load_doc(uuid, store)

      doc =
        doc
        |> Commonplace.Document.ContentType.delete_key("lease_version")
        |> Commonplace.Document.ContentType.delete_key("lease_ttl_ms")

      assert %Commonplace.Store.Commit{} =
               CommitStore.create_chained_commit(store, uuid, Yelixer.Encoding.encode_update(doc))

      assert {:ok, %{source: :temporal_default, class: :service, ttl_ms: 120_000}} =
               uuid |> Presence.read(store) |> Presence.lease_terms()
    end

    test "handles name collision with hash suffix", %{store: store, root: root} do
      {:ok, _uuid1} = Presence.create("sync", :exe, root, store)
      {:ok, _uuid2} = Presence.create("sync", :exe, root, store)

      root_doc = load_schema(root, store)
      entries = Schema.list_entries(root_doc)
      exe_entries = Enum.filter(entries, &String.ends_with?(&1.name, ".exe"))

      assert length(exe_entries) == 2
      names = Enum.map(exe_entries, & &1.name) |> Enum.sort()
      # One should be "sync.exe", the other "sync-XXX.exe"
      assert Enum.any?(names, &(&1 == "sync.exe"))
      assert Enum.any?(names, &(&1 != "sync.exe" and String.starts_with?(&1, "sync-")))
    end
  end

  describe "reading presence" do
    test "reads presence status", %{store: store, root: root} do
      {:ok, uuid} = Presence.create("agent", :bot, root, store)

      status = Presence.read(uuid, store)
      assert status["name"] == "agent"
      assert status["type"] == "bot"
      assert status["status"] == "starting"
    end

    test "updates presence status", %{store: store, root: root} do
      {:ok, uuid} = Presence.create("worker", :exe, root, store)

      Presence.update_status(uuid, "running", store)

      status = Presence.read(uuid, store)
      assert status["status"] == "running"
    end

    test "updates heartbeat", %{store: store, root: root} do
      {:ok, uuid} = Presence.create("worker", :exe, root, store)

      initial = Presence.read(uuid, store)
      Process.sleep(10)
      Presence.heartbeat(uuid, store)

      updated = Presence.read(uuid, store)
      assert updated["heartbeat"] != initial["heartbeat"]
    end
  end

  describe "discovery" do
    test "discover actors by type", %{store: store, root: root} do
      Presence.create("alpha", :exe, root, store)
      Presence.create("beta", :exe, root, store)
      Presence.create("jes", :usr, root, store)

      root_doc = load_schema(root, store)

      exes = Presence.discover(root_doc, :exe)
      assert length(exes) == 2

      usrs = Presence.discover(root_doc, :usr)
      assert length(usrs) == 1
      assert hd(usrs).name == "jes.usr"

      all = Presence.discover(root_doc, :all)
      assert length(all) == 3
    end
  end

  describe "cleanup" do
    test "removes presence from schema", %{store: store, root: root} do
      {:ok, _uuid} = Presence.create("temp", :exe, root, store)

      root_doc = load_schema(root, store)
      assert {:ok, _} = Schema.get_entry(root_doc, "temp.exe")

      Presence.remove("temp.exe", root, store)

      root_doc = load_schema(root, store)
      assert :error = Schema.get_entry(root_doc, "temp.exe")
    end
  end

  describe "set_activity/3" do
    test "writes the activity field and read returns it", %{store: store, root: root} do
      {:ok, uuid} = Presence.create("doer", :bot, root, store)

      Presence.set_activity(uuid, "writing tests", store)

      content = Presence.read(uuid, store)
      assert content["activity"] == "writing tests"
    end

    test "overwrites previous activity on subsequent calls", %{store: store, root: root} do
      {:ok, uuid} = Presence.create("doer", :bot, root, store)
      Presence.set_activity(uuid, "first task", store)
      Presence.set_activity(uuid, "second task", store)

      assert Presence.read(uuid, store)["activity"] == "second task"
    end

    test "stores empty string for nil activity", %{store: store, root: root} do
      {:ok, uuid} = Presence.create("doer", :bot, root, store)
      Presence.set_activity(uuid, nil, store)
      assert Presence.read(uuid, store)["activity"] == ""
    end
  end

  describe "set_attributes/3" do
    test "writes owner, cwd, and capabilities", %{store: store, root: root} do
      {:ok, uuid} = Presence.create("agent", :bot, root, store)

      Presence.set_attributes(
        uuid,
        %{owner: "jes", cwd: "/tmp/proj", capabilities: ["fs", "irc"]},
        store
      )

      content = Presence.read(uuid, store)
      assert content["owner"] == "jes"
      assert content["cwd"] == "/tmp/proj"
      # capabilities stored as JSON-encoded string
      assert {:ok, ["fs", "irc"]} = Jason.decode(content["capabilities"])
    end

    test "accepts a partial attribute map without clobbering others",
         %{store: store, root: root} do
      {:ok, uuid} = Presence.create("partial", :exe, root, store)
      Presence.set_attributes(uuid, %{owner: "alice"}, store)
      Presence.set_attributes(uuid, %{cwd: "/srv/x"}, store)

      content = Presence.read(uuid, store)
      assert content["owner"] == "alice"
      assert content["cwd"] == "/srv/x"
    end

    test "ignores unknown keys without crashing", %{store: store, root: root} do
      {:ok, uuid} = Presence.create("ignore", :exe, root, store)
      # should not raise
      Presence.set_attributes(uuid, %{owner: "bob", bogus: "ignored"}, store)
      assert Presence.read(uuid, store)["owner"] == "bob"
    end

    test "accepts a keyword list", %{store: store, root: root} do
      {:ok, uuid} = Presence.create("kw", :usr, root, store)
      Presence.set_attributes(uuid, [owner: "carol", cwd: "/home/carol"], store)
      content = Presence.read(uuid, store)
      assert content["owner"] == "carol"
      assert content["cwd"] == "/home/carol"
    end

    test "accepts string-keyed attrs (CX-rlv: from JSON / RPC boundaries)",
         %{store: store, root: root} do
      {:ok, uuid} = Presence.create("strkeys", :exe, root, store)

      Presence.set_attributes(
        uuid,
        %{"owner" => "dana", "cwd" => "/srv/d", "capabilities" => ["fs", "git"]},
        store
      )

      content = Presence.read(uuid, store)
      assert content["owner"] == "dana"
      assert content["cwd"] == "/srv/d"
      assert {:ok, ["fs", "git"]} = Jason.decode(content["capabilities"])
    end
  end

  describe "presence GenServer" do
    test "starts and creates presence doc", %{store: store, root: root} do
      {:ok, pid} =
        Presence.Server.start_link(
          name: "liveprocess",
          type: :exe,
          dir_uuid: root,
          store: store,
          heartbeat_interval: 100
        )

      assert Process.alive?(pid)

      # Presence should be in the schema
      root_doc = load_schema(root, store)
      entries = Schema.list_entries(root_doc)
      exe_names = Enum.filter(entries, &String.ends_with?(&1.name, ".exe")) |> Enum.map(& &1.name)
      assert "liveprocess.exe" in exe_names

      GenServer.stop(pid)
    end

    test "heartbeats update the presence doc", %{store: store, root: root} do
      {:ok, pid} =
        Presence.Server.start_link(
          name: "heartbeater",
          type: :exe,
          dir_uuid: root,
          store: store,
          heartbeat_interval: 50
        )

      uuid = Presence.Server.uuid(pid)
      initial = Presence.read(uuid, store)

      # Wait for at least one heartbeat
      Process.sleep(100)

      updated = Presence.read(uuid, store)
      assert updated["heartbeat"] != initial["heartbeat"]

      GenServer.stop(pid)
    end

    test "clean shutdown removes presence", %{store: store, root: root} do
      {:ok, pid} =
        Presence.Server.start_link(
          name: "cleanstop",
          type: :exe,
          dir_uuid: root,
          store: store,
          heartbeat_interval: 1000
        )

      GenServer.stop(pid)
      Process.sleep(50)

      root_doc = load_schema(root, store)
      assert :error = Schema.get_entry(root_doc, "cleanstop.exe")
    end
  end

  describe "stable client_id (CX-6g6)" do
    test "100 heartbeats produce a state vector with exactly 1 client_id",
         %{store: store, root: root} do
      {:ok, uuid} = Presence.create("steady", :exe, root, store)

      for _ <- 1..100 do
        Presence.heartbeat(uuid, store)
      end

      {:ok, commit} = CommitStore.latest_commit(store, uuid)
      doc = Yelixer.Doc.new()
      {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)

      sv = Yelixer.BlockStore.state_vector(doc.store)

      assert map_size(sv.clocks) == 1,
             "expected single stable client_id in state vector, got #{map_size(sv.clocks)} entries: #{inspect(Map.keys(sv.clocks))}"

      # The stable client_id must match phash2(uuid)
      expected_client_id = :erlang.phash2(uuid, 0xFFFF_FFFF)

      assert Map.has_key?(sv.clocks, expected_client_id),
             "state vector should contain phash2-derived client_id #{expected_client_id}"

      # Most recent heartbeat content survives
      content = Commonplace.Document.ContentType.get_content(doc)
      assert is_binary(content["heartbeat"])
      assert content["status"] == "starting"
      assert content["name"] == "steady"
    end

    test "heartbeat content reflects the latest write", %{store: store, root: root} do
      {:ok, uuid} = Presence.create("freshness", :exe, root, store)

      Presence.heartbeat(uuid, store)
      first_hb = Presence.read(uuid, store)["heartbeat"]

      Process.sleep(10)
      Presence.heartbeat(uuid, store)
      second_hb = Presence.read(uuid, store)["heartbeat"]

      assert first_hb != second_hb
      assert second_hb > first_hb
    end

    test "update_status and heartbeat share the same stable client_id",
         %{store: store, root: root} do
      {:ok, uuid} = Presence.create("mixed", :exe, root, store)

      Presence.update_status(uuid, "running", store)
      Presence.heartbeat(uuid, store)
      Presence.update_status(uuid, "idle", store)
      Presence.heartbeat(uuid, store)

      {:ok, commit} = CommitStore.latest_commit(store, uuid)
      doc = Yelixer.Doc.new()
      {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)

      sv = Yelixer.BlockStore.state_vector(doc.store)
      assert map_size(sv.clocks) == 1
    end
  end

  describe "CX-0a9a presence-carve (W6): signed create/heartbeat/remove threading" do
    alias Commonplace.Crypto.{Signing, SigningContext}

    test "create/5 without opts stays unsigned and omits bound_identity (back-compat)", %{
      store: store,
      root: root
    } do
      {:ok, uuid} = Presence.create("legacy", :bot, root, store)

      {:ok, commit} = CommitStore.latest_commit(store, uuid)
      assert commit.signature == nil

      content = Presence.read(uuid, store)
      refute Map.has_key?(content, "bound_identity")
    end

    test "create/5 with a signing_context + signer_id signs both commits and sets bound_identity",
         %{store: store, root: root} do
      {pub, priv} = Signing.generate_keypair()
      ctx = %SigningContext{identity_uuid: "bot-identity", private_key: priv, public_key: pub}
      signer_id = Signing.signer_id(ctx.identity_uuid, ctx.public_key)

      {:ok, uuid} =
        Presence.create("signed-bot", :bot, root, store,
          signing_context: ctx,
          signer_id: signer_id
        )

      # The presence-doc commit is signed.
      {:ok, doc_commit} = CommitStore.latest_commit(store, uuid)
      assert doc_commit.signer_id == signer_id
      assert doc_commit.signature != nil

      # The parent-schema entry commit is ALSO signed.
      {:ok, dir_commit} = CommitStore.latest_commit(store, root)
      assert dir_commit.signer_id == signer_id

      # bound_identity landed on the presence doc — and it is the BARE
      # identity uuid (the {:presence, id} cert subject / W3's compare
      # target), NOT the composite signer_id.
      content = Presence.read(uuid, store)
      assert content["bound_identity"] == ctx.identity_uuid
      assert content["lease_version"] == Presence.lease_version()
      assert content["lease_ttl_ms"] == Presence.default_lease_ttl_ms(:bot)
      refute content["bound_identity"] == signer_id
    end

    test "create/5 binds bound_identity to the signing_context identity, independent of signer_id",
         %{store: store, root: root} do
      {pub, priv} = Signing.generate_keypair()
      ctx = %SigningContext{identity_uuid: "bot-identity", private_key: priv, public_key: pub}

      # No :signer_id supplied — bound_identity must STILL be set, from
      # the signing context's bare identity uuid (W3's compare target).
      {:ok, uuid} = Presence.create("signed-no-bind", :bot, root, store, signing_context: ctx)

      {:ok, doc_commit} = CommitStore.latest_commit(store, uuid)
      assert doc_commit.signature != nil

      content = Presence.read(uuid, store)
      assert content["bound_identity"] == "bot-identity"
    end

    test "heartbeat/3 without opts stays unsigned (back-compat)", %{store: store, root: root} do
      {:ok, uuid} = Presence.create("hb-legacy", :bot, root, store)
      commit = Presence.heartbeat(uuid, store)
      assert commit.signature == nil
    end

    test "heartbeat/3 with a signing_context signs the commit", %{store: store, root: root} do
      {:ok, uuid} = Presence.create("hb-signed", :bot, root, store)

      {pub, priv} = Signing.generate_keypair()
      ctx = %SigningContext{identity_uuid: "bot-identity", private_key: priv, public_key: pub}

      commit = Presence.heartbeat(uuid, store, signing_context: ctx)
      assert commit.signature != nil
    end

    test "remove/4 without opts stays unsigned (back-compat)", %{store: store, root: root} do
      {:ok, _uuid} = Presence.create("rm-legacy", :bot, root, store)
      commit = Presence.remove("rm-legacy.bot", root, store)
      assert commit.signature == nil
    end
  end

  defp load_schema(uuid, store) do
    case CommitStore.latest_commit(store, uuid) do
      {:ok, commit} ->
        doc = Schema.new_schema()
        {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)
        doc

      :none ->
        Schema.new_schema()
    end
  end

  defp load_doc(uuid, store) do
    {:ok, commit} = CommitStore.latest_commit(store, uuid)
    doc = Yelixer.Doc.new()
    {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)
    doc
  end
end
