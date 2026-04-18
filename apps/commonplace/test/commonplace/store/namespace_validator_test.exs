defmodule Commonplace.Store.NamespaceValidatorTest do
  @moduledoc """
  End-to-end tests for the swap: the real namespace validator replaces
  CX-bv3's pass-through stub as the default for `import_commit/3`.

  Covers the five cases mandated by CX-ch5:
  1. Happy path — a regular commit whose clientIDs are in the namespace.
  2. Bootstrap — the first regular commit after a fresh genesis.
  3. Mismatch — a regular commit whose clientID isn't in the namespace.
  4. Validator swap — injected validators still win over the default.
  5. Legacy — pre-umbrella commits (metadata == %{}) still accept.
  """
  use ExUnit.Case

  alias Commonplace.Store.{CommitStore, Commit, Namespace}

  setup do
    dir = Path.join(System.tmp_dir!(), "namespace_validator_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    name = :"validator_store_#{:rand.uniform(1_000_000)}"
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

  describe "default validator is the namespace check (CX-ch5 swap)" do
    test "accepts a regular commit whose clientID is already in the namespace", %{store: store} do
      uuid = "happy"
      {:ok, genesis} = CommitStore.ensure_genesis(store, uuid)

      # First commit binds clientID 1 into the namespace (bootstrap).
      c1 = CommitStore.create_commit(store, uuid, update_from(1, "a"), genesis.id, %{
        kind: :regular,
        snapshot_parent: genesis.id
      })

      # Import a second commit from the same clientID — should accept.
      c2 = Commit.new(uuid, update_from(1, "b"), c1.id, %{
        kind: :regular,
        snapshot_parent: genesis.id
      })

      assert :ok = CommitStore.import_commit(store, c2)
    end

    test "bootstrap: accepts the first regular commit after a fresh genesis", %{store: store} do
      uuid = "bootstrap"
      {:ok, genesis} = CommitStore.ensure_genesis(store, uuid)

      commit = Commit.new(uuid, update_from(7, "first"), genesis.id, %{
        kind: :regular,
        snapshot_parent: genesis.id
      })

      # Namespace walks to an empty set; validator must accept to let
      # clientID 7 bind into the namespace as the seed.
      assert :ok = CommitStore.import_commit(store, commit)
    end

    test "rejects a regular commit whose clientID is outside the namespace", %{store: store} do
      uuid = "mismatch"
      {:ok, genesis} = CommitStore.ensure_genesis(store, uuid)

      # Seed the namespace with clientID 1.
      c1 = CommitStore.create_commit(store, uuid, update_from(1, "a"), genesis.id, %{
        kind: :regular,
        snapshot_parent: genesis.id
      })

      # Try to import a commit from clientID 999 extending the chain — must reject.
      bad = Commit.new(uuid, update_from(999, "evil"), c1.id, %{
        kind: :regular,
        snapshot_parent: genesis.id
      })

      assert {:error, {:namespace_rejected, {:client_ids_outside_namespace, ids}}} =
               CommitStore.import_commit(store, bad)

      assert 999 in ids
    end

    test "rejected import does not persist the commit", %{store: store} do
      uuid = "mismatch-nopersist"
      {:ok, genesis} = CommitStore.ensure_genesis(store, uuid)

      c1 = CommitStore.create_commit(store, uuid, update_from(1, "a"), genesis.id, %{
        kind: :regular,
        snapshot_parent: genesis.id
      })

      bad = Commit.new(uuid, update_from(999, "evil"), c1.id, %{
        kind: :regular,
        snapshot_parent: genesis.id
      })

      assert {:error, _} = CommitStore.import_commit(store, bad)
      assert :none = CommitStore.get_commit(store, bad.id)
    end

    test "legacy pre-umbrella commit (metadata == %{}) accepts without walking", %{store: store} do
      uuid = "legacy-incoming"

      # No genesis stamped; legacy commit has empty metadata. Must accept.
      legacy = Commit.new(uuid, <<1, 2, 3>>, nil)
      assert :ok = CommitStore.import_commit(store, legacy)
    end
  end

  describe "validator swap (injected validator wins)" do
    test "injected validator overrides the default namespace check", %{store: store} do
      parent = self()

      validator = fn commit ->
        send(parent, {:injected_called, commit.id})
        :ok
      end

      uuid = "swap-doc"
      # No genesis — injected validator accepts anything, including a commit
      # that would otherwise be caught by the default (no snapshot_parent
      # path is fine, but this shape is also fine for the swap check).
      commit = Commit.new(uuid, <<9, 9, 9>>, nil)

      assert :ok = CommitStore.import_commit(store, commit, validator: validator)
      assert_receive {:injected_called, id} when id == commit.id
    end

    test "injected {:error, reason} still maps to {:namespace_rejected, reason}", %{store: store} do
      validator = fn _commit -> {:error, :custom_reject} end
      commit = Commit.new("swap-doc-2", <<1>>, nil)

      assert {:error, {:namespace_rejected, :custom_reject}} =
               CommitStore.import_commit(store, commit, validator: validator)
    end
  end

  describe "rejection telemetry" do
    test "emits :commit_rejected_namespace_mismatch event on rejection", %{store: store} do
      ref = make_ref()
      parent = self()

      :telemetry.attach(
        {:test_handler, ref},
        [:commonplace, :commit, :rejected, :namespace_mismatch],
        fn _event, measurements, meta, _config ->
          send(parent, {:telemetry_fired, ref, measurements, meta})
        end,
        nil
      )

      uuid = "telemetry-doc"
      {:ok, genesis} = CommitStore.ensure_genesis(store, uuid)

      c1 = CommitStore.create_commit(store, uuid, update_from(1, "a"), genesis.id, %{
        kind: :regular,
        snapshot_parent: genesis.id
      })

      bad = Commit.new(uuid, update_from(42, "evil"), c1.id, %{
        kind: :regular,
        snapshot_parent: genesis.id
      })

      assert {:error, _} = CommitStore.import_commit(store, bad)
      assert_receive {:telemetry_fired, ^ref, _, meta}
      assert meta.doc_uuid == uuid
      assert meta.commit_id == bad.id

      :telemetry.detach({:test_handler, ref})
    end

    test "does not emit rejection telemetry on successful import", %{store: store} do
      ref = make_ref()
      parent = self()

      :telemetry.attach(
        {:test_handler_ok, ref},
        [:commonplace, :commit, :rejected, :namespace_mismatch],
        fn _event, _m, _meta, _config -> send(parent, {:false_positive, ref}) end,
        nil
      )

      uuid = "telemetry-ok"
      {:ok, genesis} = CommitStore.ensure_genesis(store, uuid)

      commit = Commit.new(uuid, update_from(1, "a"), genesis.id, %{
        kind: :regular,
        snapshot_parent: genesis.id
      })

      assert :ok = CommitStore.import_commit(store, commit)
      refute_receive {:false_positive, ^ref}, 100

      :telemetry.detach({:test_handler_ok, ref})
    end
  end

  describe "namespace walk integration" do
    test "namespace grows across multiple regular commits", %{store: store} do
      uuid = "multi-client"
      {:ok, genesis} = CommitStore.ensure_genesis(store, uuid)

      # clientID 1 seeds (bootstrap)
      c1 = CommitStore.create_commit(store, uuid, update_from(1, "a"), genesis.id, %{
        kind: :regular,
        snapshot_parent: genesis.id
      })

      # A subsequent commit from clientID 2 attempts to join — should be
      # rejected because clientID 2 is not in the namespace (which is {1}).
      c2 = Commit.new(uuid, update_from(2, "b"), c1.id, %{
        kind: :regular,
        snapshot_parent: genesis.id
      })

      assert {:error, {:namespace_rejected, _}} = CommitStore.import_commit(store, c2)

      # But a commit from clientID 1 continuing the chain is fine.
      c2b = Commit.new(uuid, update_from(1, "b"), c1.id, %{
        kind: :regular,
        snapshot_parent: genesis.id
      })

      assert :ok = CommitStore.import_commit(store, c2b)
    end
  end

  describe "primitive via public API" do
    test "Namespace.clientID_in_namespace?/3 reflects the validator's view", %{store: store} do
      uuid = "primitive"
      {:ok, genesis} = CommitStore.ensure_genesis(store, uuid)

      c1 = CommitStore.create_commit(store, uuid, update_from(3, "hi"), genesis.id, %{
        kind: :regular,
        snapshot_parent: genesis.id
      })

      assert Namespace.clientID_in_namespace?(store, c1.id, 3)
      refute Namespace.clientID_in_namespace?(store, c1.id, 4)
    end
  end
end
