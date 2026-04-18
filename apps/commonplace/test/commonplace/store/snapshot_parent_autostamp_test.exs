defmodule Commonplace.Store.SnapshotParentAutostampTest do
  @moduledoc """
  CX-a04 (Build 4): auto-stamp `snapshot_parent` on new regular commits
  and tighten the validator to reject `:regular` commits that don't
  carry one. Legacy pre-umbrella commits (metadata == %{}) remain
  accepted and are never auto-stamped.
  """
  use ExUnit.Case

  alias Commonplace.Store.{CommitStore, Commit, Namespace}

  setup do
    dir = Path.join(System.tmp_dir!(), "snapshot_parent_autostamp_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    name = :"autostamp_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: name})
    on_exit(fn -> File.rm_rf!(dir) end)
    %{store: name}
  end

  defp update_from(client_id, content) do
    doc = Yelixer.Doc.new(client_id: client_id)
    {doc, _} = Yelixer.Doc.get_or_create_type(doc, "t", :text)
    doc = Yelixer.Types.Text.insert(doc, "t", 0, content)
    Yelixer.Encoding.encode_update(doc)
  end

  describe "Namespace.current_namespace/1 helper" do
    test "returns commit.id for :genesis" do
      genesis = Commit.genesis("uuid-a")
      assert Namespace.current_namespace(genesis) == genesis.id
    end

    test "returns commit.id for :snapshot" do
      snap = Commit.new("uuid-a", <<1, 2, 3>>, "parent-id", %{kind: :snapshot})
      assert Namespace.current_namespace(snap) == snap.id
    end

    test "returns metadata.snapshot_parent for :regular" do
      reg = Commit.new("uuid-a", <<1, 2, 3>>, "parent-id", %{
        kind: :regular,
        snapshot_parent: "trust-root"
      })
      assert Namespace.current_namespace(reg) == "trust-root"
    end

    test "returns metadata.snapshot_parent for :merge" do
      m = Commit.new("uuid-a", <<1, 2, 3>>, "parent-id", %{
        kind: :merge,
        snapshot_parent: "trust-root"
      })
      assert Namespace.current_namespace(m) == "trust-root"
    end

    test "returns nil for legacy (%{}) commits" do
      legacy = Commit.new("uuid-a", <<1, 2, 3>>, "parent-id")
      assert Namespace.current_namespace(legacy) == nil
    end
  end

  describe "auto-stamp snapshot_parent on create_commit" do
    test "stamps genesis.id on first :regular commit of a fresh doc", %{store: store} do
      uuid = "autostamp-happy"

      # Pass nil parent — maybe_stamp_genesis will wire up the genesis.
      commit = CommitStore.create_commit(store, uuid, update_from(1, "a"), nil, %{kind: :regular})

      {:ok, genesis} = CommitStore.ensure_genesis(store, uuid)
      assert commit.metadata[:snapshot_parent] == genesis.id
      assert commit.metadata[:kind] == :regular
    end

    test "stamps snapshot.id when latest is a :snapshot", %{store: store} do
      uuid = "autostamp-snapshot-rooted"

      # Seed with a legacy commit then a snapshot. A subsequent :regular
      # commit should stamp snapshot_parent = snapshot.id.
      legacy = CommitStore.create_commit(store, uuid, update_from(1, "pre"), nil)
      snap = CommitStore.create_snapshot_commit(store, uuid, update_from(1, "snap"))

      refute legacy.metadata[:kind] == :snapshot
      assert snap.metadata[:kind] == :snapshot

      reg = CommitStore.create_chained_commit(store, uuid, update_from(1, "after"), %{kind: :regular})
      assert reg.metadata[:snapshot_parent] == snap.id
    end

    test "inherits snapshot_parent from parent regular commit", %{store: store} do
      uuid = "autostamp-inherit"

      c1 = CommitStore.create_commit(store, uuid, update_from(1, "a"), nil, %{kind: :regular})
      {:ok, genesis} = CommitStore.ensure_genesis(store, uuid)
      assert c1.metadata[:snapshot_parent] == genesis.id

      c2 = CommitStore.create_chained_commit(store, uuid, update_from(1, "b"), %{kind: :regular})
      assert c2.metadata[:snapshot_parent] == genesis.id
    end

    test "does not overwrite an explicit caller-supplied snapshot_parent", %{store: store} do
      uuid = "autostamp-override"

      # Caller sets an (artificial) snapshot_parent — auto-stamp must not
      # overwrite it.
      commit = CommitStore.create_commit(store, uuid, update_from(1, "a"), nil, %{
        kind: :regular,
        snapshot_parent: "explicit-parent"
      })

      assert commit.metadata[:snapshot_parent] == "explicit-parent"
    end

    test "does not auto-stamp legacy (%{}) commits", %{store: store} do
      uuid = "autostamp-legacy"

      commit = CommitStore.create_commit(store, uuid, update_from(1, "a"), nil, %{})

      # Legacy empty-metadata must stay empty — no :kind, no :snapshot_parent.
      assert commit.metadata == %{}
    end

    test "does not auto-stamp :snapshot commits", %{store: store} do
      uuid = "autostamp-snapshot"

      snap = CommitStore.create_snapshot_commit(store, uuid, update_from(1, "a"))

      # Snapshots are trust roots themselves — they don't carry a snapshot_parent.
      refute Map.has_key?(snap.metadata, :snapshot_parent)
    end
  end

  describe "validator tightening" do
    test "rejects a :regular commit without snapshot_parent", %{store: store} do
      uuid = "tighten-no-sp"
      {:ok, _genesis} = CommitStore.ensure_genesis(store, uuid)

      # Hand-craft a commit whose metadata is `%{kind: :regular}` but
      # lacks `:snapshot_parent`. Post-umbrella this is malformed.
      bad = Commit.new(uuid, update_from(1, "a"), nil, %{kind: :regular})

      assert {:error, {:namespace_rejected, :missing_snapshot_parent}} =
               CommitStore.import_commit(store, bad)
    end

    test "legacy (%{}) commits still accepted without snapshot_parent", %{store: store} do
      uuid = "legacy-still-ok"

      legacy = Commit.new(uuid, <<1, 2, 3>>, nil)
      assert legacy.metadata == %{}
      assert :ok = CommitStore.import_commit(store, legacy)
    end

    test "a :regular commit WITH snapshot_parent and bootstrap-empty namespace still accepts", %{store: store} do
      uuid = "bootstrap-still-ok"
      {:ok, genesis} = CommitStore.ensure_genesis(store, uuid)

      good = Commit.new(uuid, update_from(7, "first"), genesis.id, %{
        kind: :regular,
        snapshot_parent: genesis.id
      })

      assert :ok = CommitStore.import_commit(store, good)
    end
  end
end
