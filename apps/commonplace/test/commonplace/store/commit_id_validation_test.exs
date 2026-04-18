defmodule Commonplace.Store.CommitIdValidationTest do
  @moduledoc """
  CX-gwz: `CommitStore.import_commit/3` must recompute the content
  address of an incoming commit and reject any commit whose claimed
  `id` does not match the hash of `(parent_id || <<>>) <> update <>
  canonical_metadata(metadata) <> canonical_merge_parents(merge_parents)`.

  Without this check, a buggy or hostile peer can retag an ordinary
  delta as `%{kind: :snapshot}` and make `DocBuilder.reconstruct_doc/2`
  skip all earlier history, or flip `parent_id`/`update`/`merge_parents`
  to forge history. The round-2 metadata-in-content-address fix
  (CX-u7p) bound metadata into the id for LOCALLY-created commits but
  `import_commit` accepts remote commits verbatim — this bead closes
  that gap.

  The verification runs BEFORE the namespace validator because nothing
  about the commit's fields (including those the validator reads) is
  trustworthy until the id matches.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Store.{Commit, CommitStore}

  setup do
    dir = Path.join(System.tmp_dir!(), "cidval_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    name = :"cidval_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: name})
    on_exit(fn -> File.rm_rf!(dir) end)
    %{store: name}
  end

  # ---------- Commit.verify_id/1 primitive ----------

  describe "Commit.verify_id/1" do
    test "accepts a legitimately-constructed commit" do
      commit = Commit.new("doc-1", <<1, 2, 3>>, nil)
      assert :ok = Commit.verify_id(commit)
    end

    test "accepts a commit with metadata bound into the id" do
      commit = Commit.new("doc-1", <<1, 2, 3>>, nil, %{kind: :snapshot})
      assert :ok = Commit.verify_id(commit)
    end

    test "accepts a commit with merge_parents bound into the id" do
      commit =
        Commit.new("doc-1", <<1, 2, 3>>, <<0::256>>, %{kind: :merge}, [<<1::256>>])

      assert :ok = Commit.verify_id(commit)
    end

    test "accepts the deterministic genesis commit" do
      genesis = Commit.genesis("doc-1")
      assert :ok = Commit.verify_id(genesis)
    end

    test "rejects a commit whose id does not match its fields" do
      commit = Commit.new("doc-1", <<1, 2, 3>>, nil)
      tampered = %{commit | update: <<9, 9, 9>>}

      assert {:error, {:id_mismatch, computed, claimed}} = Commit.verify_id(tampered)
      assert claimed == commit.id
      assert computed != commit.id
      assert is_binary(computed)
    end

    test "rejects a commit whose metadata was retagged without rehashing" do
      commit = Commit.new("doc-1", <<1, 2, 3>>, nil)
      tampered = %{commit | metadata: %{kind: :snapshot}}

      assert {:error, {:id_mismatch, _, _}} = Commit.verify_id(tampered)
    end

    test "rejects a commit whose parent_id was flipped" do
      commit = Commit.new("doc-1", <<1, 2, 3>>, <<0::256>>, %{kind: :regular})
      tampered = %{commit | parent_id: <<1::256>>}

      assert {:error, {:id_mismatch, _, _}} = Commit.verify_id(tampered)
    end

    test "rejects a commit whose merge_parents list was flipped" do
      commit =
        Commit.new("doc-1", <<1, 2, 3>>, <<0::256>>, %{kind: :merge}, [<<1::256>>])

      tampered = %{commit | merge_parents: [<<2::256>>]}

      assert {:error, {:id_mismatch, _, _}} = Commit.verify_id(tampered)
    end
  end

  # ---------- import_commit integration ----------

  describe "import_commit/3 — id verification gate" do
    test "accepts a valid commit (baseline)", %{store: store} do
      commit = Commit.new("doc-ok", <<1, 2, 3>>, nil)
      assert :ok = CommitStore.import_commit(store, commit)
    end

    test "rejects a commit whose update was tampered with", %{store: store} do
      commit = Commit.new("doc-tamper-update", <<1, 2, 3>>, nil)
      tampered = %{commit | update: <<9, 9, 9>>}

      assert {:error, {:id_mismatch, _computed, _claimed}} =
               CommitStore.import_commit(store, tampered)
    end

    test "rejects a retag-as-snapshot attack", %{store: store} do
      # Hostile peer: take an ordinary delta and retag it as a snapshot
      # to force DocBuilder.reconstruct_doc to skip earlier history.
      commit = Commit.new("doc-retag", <<4, 5, 6>>, <<0::256>>, %{kind: :regular})
      tampered = %{commit | metadata: %{kind: :snapshot}}

      assert {:error, {:id_mismatch, _, _}} =
               CommitStore.import_commit(store, tampered)
    end

    test "rejected commit is not persisted", %{store: store} do
      commit = Commit.new("doc-nopersist", <<1, 2, 3>>, nil)
      tampered = %{commit | update: <<9, 9, 9>>}

      assert {:error, _} = CommitStore.import_commit(store, tampered)
      # The claimed id is still `commit.id` — ensure NO entry was written
      # under that id.
      assert :none = CommitStore.get_commit(store, commit.id)
    end

    test "verification runs before the namespace validator", %{store: store} do
      # If verification ran AFTER the validator, an injected validator
      # that returns :ok would let a tampered commit through. Confirm
      # that a tampered commit is rejected BEFORE an always-pass
      # validator has a chance to accept it.
      commit = Commit.new("doc-order", <<1, 2, 3>>, nil)
      tampered = %{commit | update: <<9, 9, 9>>}

      validator_called = :counters.new(1, [:atomics])

      validator = fn _c ->
        :counters.add(validator_called, 1, 1)
        :ok
      end

      assert {:error, {:id_mismatch, _, _}} =
               CommitStore.import_commit(store, tampered, validator: validator)

      assert :counters.get(validator_called, 1) == 0,
             "namespace validator must not be invoked on id-mismatched commits"
    end

    test "emits [:commonplace, :commit, :rejected, :id_mismatch] telemetry",
         %{store: store} do
      ref = make_ref()
      parent = self()

      :telemetry.attach(
        {:cx_gwz_handler, ref},
        [:commonplace, :commit, :rejected, :id_mismatch],
        fn _event, meas, meta, _cfg ->
          send(parent, {:id_mismatch_fired, ref, meas, meta})
        end,
        nil
      )

      commit = Commit.new("doc-telemetry", <<1, 2, 3>>, nil)
      tampered = %{commit | metadata: %{kind: :snapshot}}

      assert {:error, _} = CommitStore.import_commit(store, tampered)

      assert_receive {:id_mismatch_fired, ^ref, _meas, meta}, 500
      assert meta.doc_uuid == "doc-telemetry"
      assert meta.claimed_id == commit.id
      assert is_binary(meta.computed_id)
      assert meta.computed_id != commit.id

      :telemetry.detach({:cx_gwz_handler, ref})
    end

    test "accepts the deterministic genesis commit", %{store: store} do
      genesis = Commit.genesis("doc-genesis-import")
      assert :ok = CommitStore.import_commit(store, genesis)
    end
  end
end
