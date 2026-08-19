defmodule Commonplace.Presence.IdentityTest do
  @moduledoc """
  Tests for cold identity — permanent actor records in __identities/.
  """
  use ExUnit.Case

  alias Commonplace.Presence.Identity
  alias Commonplace.Tree.Schema
  alias Commonplace.Store.CommitStore

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_identity_#{:rand.uniform(1_000_000)}")
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

  describe "ensure_identities_dir" do
    test "creates __identities__ entry in root schema", %{store: store, root: root} do
      {:ok, dir_uuid} = Identity.ensure_identities_dir(root, store)

      root_doc = load_schema(root, store)
      {:ok, entry} = Schema.get_entry(root_doc, "__identities__")
      assert entry.type == :dir
      assert entry.node_id == dir_uuid
    end

    test "returns existing dir if already created", %{store: store, root: root} do
      {:ok, uuid1} = Identity.ensure_identities_dir(root, store)
      {:ok, uuid2} = Identity.ensure_identities_dir(root, store)
      assert uuid1 == uuid2
    end
  end

  describe "register" do
    test "creates a new cold identity", %{store: store, root: root} do
      {:ok, identity_uuid} = Identity.register("sync", :exe, root, store)

      identity = Identity.read(identity_uuid, store)
      assert identity["name"] == "sync"
      assert identity["type"] == "exe"
      assert is_binary(identity["first_seen"])
      assert is_binary(identity["last_seen"])
    end

    test "identity appears in __identities__ schema", %{store: store, root: root} do
      {:ok, _uuid} = Identity.register("sync", :exe, root, store)

      {:ok, id_dir_uuid} = Identity.ensure_identities_dir(root, store)
      id_doc = load_schema(id_dir_uuid, store)
      {:ok, entry} = Schema.get_entry(id_doc, "sync.exe")
      assert entry.type == :doc
    end

    test "returns existing identity on re-register", %{store: store, root: root} do
      {:ok, uuid1} = Identity.register("sync", :exe, root, store)
      Process.sleep(10)
      {:ok, uuid2} = Identity.register("sync", :exe, root, store)

      assert uuid1 == uuid2

      # last_seen should be updated
      identity = Identity.read(uuid2, store)
      assert identity["name"] == "sync"
    end

    test "updates last_seen on re-register", %{store: store, root: root} do
      {:ok, uuid} = Identity.register("sync", :exe, root, store)
      first = Identity.read(uuid, store)

      Process.sleep(10)
      {:ok, ^uuid} = Identity.register("sync", :exe, root, store)
      second = Identity.read(uuid, store)

      assert second["first_seen"] == first["first_seen"]
      assert second["last_seen"] != first["last_seen"]
    end
  end

  describe "lookup" do
    test "finds a registered identity", %{store: store, root: root} do
      {:ok, uuid} = Identity.register("agent", :bot, root, store)

      assert {:ok, ^uuid} = Identity.lookup("agent", :bot, root, store)
    end

    test "returns :error for unregistered identity", %{store: store, root: root} do
      assert :error = Identity.lookup("ghost", :exe, root, store)
    end
  end

  describe "list" do
    test "lists all cold identities", %{store: store, root: root} do
      Identity.register("alpha", :exe, root, store)
      Identity.register("beta", :bot, root, store)
      Identity.register("jes", :usr, root, store)

      identities = Identity.list(root, store)
      assert length(identities) == 3
      names = Enum.map(identities, & &1.name) |> Enum.sort()
      assert names == ["alpha.exe", "beta.bot", "jes.usr"]
    end

    test "returns empty list when no identities", %{store: store, root: root} do
      assert Identity.list(root, store) == []
    end
  end

  describe "in-memory Yjs merge with distinct client_ids (CX-6g6 codex P1 round 1)" do
    # SCOPE: these tests exercise ONLY the in-memory Yjs merge path —
    # Yelixer.Encoding.apply_update/2 on two concurrent updates from writers
    # with distinct client_ids. They do NOT exercise the CommitStore write
    # path (`latest_commit -> mutate -> create_chained_commit`), where two
    # nodes racing on the same identity UUID still produce sibling commits
    # and only one becomes `:latest`. Full multi-writer correctness through
    # the commit-chain layer (sibling-commit merge / :latest reconciliation)
    # is tracked as a separate P1 follow-up bead; see the docstring on
    # `stable_client_id/1` in identity.ex for the detailed scope note.
    #
    # What this describe block verifies is the *prerequisite* for that
    # follow-up: if identity writes from different nodes ever reach the
    # same in-memory Yelixer.Doc — whether via a future sibling-commit
    # merge, a catch-up sync, or a snapshot rebuild — their updates carry
    # distinct (client_id, clock) pairs and both survive. A previous
    # implementation hashed the identity UUID alone, giving every node the
    # same client_id and silently collapsing concurrent writes even at
    # this in-memory layer.
    test "in-memory apply_update with distinct client_ids merges both writers",
         %{store: store, root: root} do
      alias Commonplace.Document.ContentType
      alias Commonplace.Store.CommitStoreClient

      # Register a shared identity doc and fetch its base state.
      {:ok, identity_uuid} = Identity.register("shared", :exe, root, store)
      {:ok, base_commit} = CommitStoreClient.latest_commit(store, identity_uuid)

      # Simulate writer A (e.g. node alpha) — distinct explicit client_id.
      doc_a = Yelixer.Doc.new(client_id: 100_001)
      {:ok, doc_a} = Yelixer.Encoding.apply_update(doc_a, base_commit.update)
      doc_a = ContentType.set_key(doc_a, "written_by_a", "alpha_value")
      update_a = Yelixer.Encoding.encode_update(doc_a)

      # Simulate writer B (e.g. node beta) — different explicit client_id,
      # same base state, concurrent write to a different key.
      doc_b = Yelixer.Doc.new(client_id: 100_002)
      {:ok, doc_b} = Yelixer.Encoding.apply_update(doc_b, base_commit.update)
      doc_b = ContentType.set_key(doc_b, "written_by_b", "beta_value")
      update_b = Yelixer.Encoding.encode_update(doc_b)

      # Merge both updates into a fresh observer doc. With the fix, both
      # concurrent writes retain distinct (client_id, clock) pairs and both
      # survive. With the old phash2(uuid)-only derivation, writers A and B
      # would share a client_id, reuse the same clock, and one set would be
      # silently dropped here.
      observer = Yelixer.Doc.new()
      {:ok, observer} = Yelixer.Encoding.apply_update(observer, update_a)
      {:ok, observer} = Yelixer.Encoding.apply_update(observer, update_b)

      content = ContentType.get_content(observer)

      assert content["written_by_a"] == "alpha_value",
             "writer A's concurrent change was dropped — client_id collision regression"

      assert content["written_by_b"] == "beta_value",
             "writer B's concurrent change was dropped — client_id collision regression"

      # Ordering of apply should not matter: reverse the merge and verify.
      observer2 = Yelixer.Doc.new()
      {:ok, observer2} = Yelixer.Encoding.apply_update(observer2, update_b)
      {:ok, observer2} = Yelixer.Encoding.apply_update(observer2, update_a)

      content2 = ContentType.get_content(observer2)
      assert content2["written_by_a"] == "alpha_value"
      assert content2["written_by_b"] == "beta_value"
    end

    # CX-6g6 fix derived client_id from {node(), uuid} so distinct nodes
    # got distinct client_ids and concurrent in-memory merges preserved
    # both writes. CX-njf replaced node() with the workspace-scoped
    # persistent node-id (`Workspace.node_id/0`) because node() can
    # change across sname renames / IP reassignments and reintroduce
    # state-vector bloat at restart boundaries. Verify the published
    # client_id matches the new derivation.
    test "Identity writes derive client_id from {Workspace.node_id, uuid} (CX-njf)",
         %{store: store, root: root} do
      alias Commonplace.Store.CommitStoreClient

      {:ok, identity_uuid} = Identity.register("nodescoped", :exe, root, store)

      {:ok, commit} = CommitStoreClient.latest_commit(store, identity_uuid)
      doc = Yelixer.Doc.new()
      {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)
      sv = Yelixer.BlockStore.state_vector(doc.store)

      {:ok, node_id} = Commonplace.Workspace.node_id()
      post_fix_client_id = :erlang.phash2({node_id, identity_uuid}, 0xFFFF_FFFF)

      assert Map.has_key?(sv.clocks, post_fix_client_id),
             "state vector missing workspace-node-id-scoped client_id #{post_fix_client_id}: #{inspect(Map.keys(sv.clocks))}"
    end
  end

  describe "GenServer integration" do
    test "Presence.Server registers cold identity on start", %{store: store, root: root} do
      {:ok, pid} =
        Commonplace.Presence.Server.start_link(
          name: "coldtest",
          type: :exe,
          dir_uuid: root,
          store: store,
          heartbeat_interval: 10_000
        )

      # Cold identity should exist
      assert {:ok, _uuid} = Identity.lookup("coldtest", :exe, root, store)

      GenServer.stop(pid)
    end

    test "cold identity persists after clean shutdown", %{store: store, root: root} do
      {:ok, pid} =
        Commonplace.Presence.Server.start_link(
          name: "survivor",
          type: :exe,
          dir_uuid: root,
          store: store,
          heartbeat_interval: 10_000
        )

      GenServer.stop(pid)
      Process.sleep(50)

      # Hot presence is gone
      root_doc = load_schema(root, store)
      assert :error = Schema.get_entry(root_doc, "survivor.exe")

      # Cold identity persists
      assert {:ok, _uuid} = Identity.lookup("survivor", :exe, root, store)
    end

    test "cold identity last_seen updated on shutdown", %{store: store, root: root} do
      {:ok, pid} =
        Commonplace.Presence.Server.start_link(
          name: "timestamped",
          type: :exe,
          dir_uuid: root,
          store: store,
          heartbeat_interval: 10_000
        )

      identity_uuid = Commonplace.Presence.Server.identity_uuid(pid)
      before_stop = Identity.read(identity_uuid, store)

      Process.sleep(10)
      GenServer.stop(pid)
      Process.sleep(50)

      after_stop = Identity.read(identity_uuid, store)
      assert after_stop["last_seen"] != before_stop["last_seen"]
    end
  end

  describe "signing_context threading (CX-88mw ii / D9)" do
    alias Commonplace.Crypto.{Signing, SigningContext}

    defp creator_ctx do
      {pub, priv} = Signing.generate_keypair()
      ctx = %SigningContext{identity_uuid: "creator", private_key: priv, public_key: pub}
      {ctx, Signing.signer_id("creator", pub)}
    end

    defp latest!(store, uuid) do
      {:ok, commit} = CommitStore.latest_commit(store, uuid)
      commit
    end

    test "register signs the identity doc AND the schema commits with the creator's key",
         %{store: store, root: root} do
      {ctx, signer} = creator_ctx()

      {:ok, uuid} =
        Identity.register("scribe", :bot, root, store, signing_context: ctx)

      # The identity doc's birth commit carries the CREATOR's signature (D9).
      identity_commit = latest!(store, uuid)
      assert identity_commit.signer_id == signer
      assert :ok = Signing.verify_commit(identity_commit, ctx.public_key)

      # The __identities__ schema commit (add_file) is creator-signed too.
      {:ok, id_dir_uuid} = Identity.ensure_identities_dir(root, store)
      dir_commit = latest!(store, id_dir_uuid)
      assert dir_commit.signer_id == signer

      # ensure_identities_dir's root-schema commit (add_directory) — the
      # dir was created inside this register call, so its commits must
      # carry the same context.
      root_commit = latest!(store, root)
      assert root_commit.signer_id == signer
    end

    test "register without a context keeps the legacy unsigned behavior",
         %{store: store, root: root} do
      {:ok, uuid} = Identity.register("plain", :bot, root, store)
      assert latest!(store, uuid).signature == nil
    end

    test "add_public_key with signing_context signs the appended-key commit",
         %{store: store, root: root} do
      {ctx, signer} = creator_ctx()
      {:ok, uuid} = Identity.register("keyed", :bot, root, store)

      :ok =
        Identity.add_public_key(uuid, Base.encode64("fake-pub"), store, signing_context: ctx)

      commit = latest!(store, uuid)
      assert commit.signer_id == signer
      assert :ok = Signing.verify_commit(commit, ctx.public_key)
    end

    test "touch_last_seen with signing_context signs", %{store: store, root: root} do
      {ctx, signer} = creator_ctx()
      {:ok, uuid} = Identity.register("touched", :bot, root, store)

      Process.sleep(10)
      Identity.touch_last_seen(uuid, store, signing_context: ctx)

      assert latest!(store, uuid).signer_id == signer
    end
  end

  describe "register_agent (CX-88mw ii)" do
    alias Commonplace.Crypto.{AgentKeys, Signing, SigningContext}
    alias Commonplace.Store.SecretStore

    setup do
      dir = Path.join(System.tmp_dir!(), "cp_agent_secrets_#{:rand.uniform(1_000_000_000)}")
      File.mkdir_p!(dir)
      name = :"agent_secrets_#{:rand.uniform(1_000_000)}"
      {:ok, pid} = SecretStore.start_link(data_dir: dir, name: name)

      on_exit(fn ->
        if Process.alive?(pid),
          do:
            (try do
               GenServer.stop(pid)
             catch
               (:exit, _ -> :ok)
             end)

        File.rm_rf!(dir)
      end)

      %{secrets: name}
    end

    test "registers a :bot, mints its key, binds the pubkey into the identity doc",
         %{store: store, root: root, secrets: secrets} do
      {cpub, cpriv} = Signing.generate_keypair()
      ctx = %SigningContext{identity_uuid: "creator", private_key: cpriv, public_key: cpub}

      assert {:ok, uuid, pub} =
               Identity.register_agent("worker", root, store,
                 signing_context: ctx,
                 secret_store: secrets
               )

      # Registered as a :bot cold identity.
      assert {:ok, ^uuid} = Identity.lookup("worker", :bot, root, store)

      # Key custody landed in the SecretStore; context matches.
      assert {:ok, agent_ctx} = AgentKeys.signing_context_for(uuid, secrets)
      assert agent_ctx.public_key == pub

      # D6: convenience pubkey copy in the identity doc (authority stays
      # in the cert chain, not here).
      assert Base.encode64(pub) in Identity.get_public_keys(uuid, store)

      # D9: the registration commits are signed by the CREATOR.
      {:ok, commit} = CommitStore.latest_commit(store, uuid)
      assert commit.signer_id == Signing.signer_id("creator", cpub)
    end

    test "register_agent is idempotent on the identity and keeps the same key",
         %{store: store, root: root, secrets: secrets} do
      {:ok, uuid1, pub1} = Identity.register_agent("stable", root, store, secret_store: secrets)
      Process.sleep(10)
      {:ok, uuid2, pub2} = Identity.register_agent("stable", root, store, secret_store: secrets)

      assert uuid1 == uuid2
      assert pub1 == pub2
    end
  end

  describe "register_player (CX-qat5.2 §2.1)" do
    alias Commonplace.Crypto.{AgentKeys, Signing, SigningContext}
    alias Commonplace.Store.SecretStore

    setup do
      dir = Path.join(System.tmp_dir!(), "cp_player_secrets_#{:rand.uniform(1_000_000_000)}")
      File.mkdir_p!(dir)
      name = :"player_secrets_#{:rand.uniform(1_000_000)}"
      {:ok, pid} = SecretStore.start_link(data_dir: dir, name: name)

      on_exit(fn ->
        if Process.alive?(pid),
          do:
            (try do
               GenServer.stop(pid)
             catch
               (:exit, _ -> :ok)
             end)

        File.rm_rf!(dir)
      end)

      %{secrets: name}
    end

    test "registers a :usr (not :bot), mints its key, binds the pubkey into the identity doc",
         %{store: store, root: root, secrets: secrets} do
      {cpub, cpriv} = Signing.generate_keypair()
      ctx = %SigningContext{identity_uuid: "creator", private_key: cpriv, public_key: cpub}

      assert {:ok, uuid, pub} =
               Identity.register_player("alice", root, store,
                 signing_context: ctx,
                 secret_store: secrets
               )

      # Registered as a :usr cold identity — mirrors register_agent's
      # :bot shape exactly except for this kind (CX-qat5.2 §2.1).
      assert {:ok, ^uuid} = Identity.lookup("alice", :usr, root, store)
      refute Identity.lookup("alice", :bot, root, store) == {:ok, uuid}

      assert {:ok, agent_ctx} = AgentKeys.signing_context_for(uuid, secrets)
      assert agent_ctx.public_key == pub

      assert Base.encode64(pub) in Identity.get_public_keys(uuid, store)

      # D9: the registration commits are signed by the CREATOR.
      {:ok, commit} = CommitStore.latest_commit(store, uuid)
      assert commit.signer_id == Signing.signer_id("creator", cpub)
    end

    test "register_player is idempotent on the identity and keeps the same key",
         %{store: store, root: root, secrets: secrets} do
      {:ok, uuid1, pub1} = Identity.register_player("stable", root, store, secret_store: secrets)
      Process.sleep(10)
      {:ok, uuid2, pub2} = Identity.register_player("stable", root, store, secret_store: secrets)

      assert uuid1 == uuid2
      assert pub1 == pub2
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
end
