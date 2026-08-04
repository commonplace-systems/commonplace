defmodule Commonplace.DerivationRecordTest do
  @moduledoc """
  CX-vt9l.2 acceptance tests for the derivation-record convention.

  Three properties, per the bead's TEST FIRST section:

    (a) ROUND-TRIP — an artifact regenerated from a record's
        `sources_pin` alone byte-matches the original.
    (b) STRUCTURE — `witness?/1` is true for a well-formed record and
        false the moment computed state rides along.
    (c) STALENESS DECIDABLE — mutating a pinned source is detected
        exactly (named, not "something changed"); an unmutated record
        reads `:current`; an UNREADABLE source reads `{:unknown, _}`,
        never a silent `:current` (the load-bearing case — this is the
        failure class the arc keeps hitting).
  """

  use ExUnit.Case, async: false

  alias Commonplace.DerivationRecord
  alias Commonplace.Store.CommitStore
  alias Commonplace.Document.ContentType

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_derivation_record_test_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    store_name = :"commit_store_derivation_record_#{:rand.uniform(1_000_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store_name})
    on_exit(fn -> File.rm_rf!(dir) end)
    %{store: store_name}
  end

  defp create_text_doc(store, content) do
    uuid = UUID.uuid4()
    doc = Yelixer.Doc.new()
    doc = ContentType.create(doc, :text, "seed")
    doc = if content != "", do: ContentType.insert_text(doc, 0, content), else: doc
    update = Yelixer.Encoding.encode_update(doc)
    commit = CommitStore.create_commit(store, uuid, update, nil)
    {uuid, commit.id}
  end

  defp read_content(store, uuid) do
    case Commonplace.Tree.DocBuilder.reconstruct_snapshot(store, uuid) do
      {:ok, doc} -> ContentType.get_content(doc)
      :none -> nil
    end
  end

  # A toy transform: uppercase-concatenate the content of every source
  # in the pin, in uuid-sorted order. Deterministic and regenerable
  # from nothing but (store, sources_pin) — exactly what "regenerable
  # from the record alone" requires.
  defp run_transform(store, sources_pin) do
    sources_pin
    |> Enum.sort_by(fn {uuid, _cid} -> uuid end)
    |> Enum.map_join(fn {uuid, _commit_id} -> String.upcase(read_content(store, uuid) || "") end)
  end

  describe "round-trip (a)" do
    test "regenerating the artifact from the record's sources_pin alone byte-matches the original", %{
      store: store
    } do
      {u1, c1} = create_text_doc(store, "hello")
      {u2, c2} = create_text_doc(store, "world")

      sources_pin = %{u1 => c1, u2 => c2}
      original_artifact = run_transform(store, sources_pin)

      record = DerivationRecord.new(sources_pin, "toy-transform-v1", "artifact-not-a-doc")

      # Regenerate using ONLY what the record carries — no side channel.
      regenerated = run_transform(store, record["sources_pin"])

      assert regenerated == original_artifact
      # Sanity: both sources really made it into the artifact (order
      # depends on uuid sort, which is random per-run — not asserted).
      assert regenerated in ["HELLOWORLD", "WORLDHELLO"]
    end
  end

  describe "structure (b)" do
    test "witness?/1 is true for a well-formed record" do
      record =
        DerivationRecord.new(
          %{"uuid-1" => <<1, 2, 3>>},
          "transform-ref",
          {"out-uuid", <<9, 9, 9>>},
          signer: "node-a"
        )

      assert DerivationRecord.witness?(record)
    end

    test "witness?/1 is false when the record carries computed state" do
      record =
        DerivationRecord.new(%{"uuid-1" => <<1, 2, 3>>}, "transform-ref", {"out-uuid", <<9>>})

      # Computed state riding alongside the refs — e.g. a materialized
      # row count or index byte size presented as part of the record.
      tainted = Map.put(record, "row_count", 42)

      refute DerivationRecord.witness?(tainted)
    end

    test "witness?/1 is false for non-map input" do
      refute DerivationRecord.witness?("not a record")
      refute DerivationRecord.witness?(nil)
    end
  end

  describe "staleness decidable (c)" do
    test "unmutated sources read :current", %{store: store} do
      {u1, c1} = create_text_doc(store, "hello")
      record = DerivationRecord.new(%{u1 => c1}, "t", "o")

      assert DerivationRecord.stale?(record, store) == :current
    end

    test "mutating a pinned source is detected and named exactly", %{store: store} do
      {u1, c1} = create_text_doc(store, "hello")
      {u2, c2} = create_text_doc(store, "world")
      record = DerivationRecord.new(%{u1 => c1, u2 => c2}, "t", "o")

      # Mutate only u1 — append a new commit so its latest commit id
      # no longer matches the pin.
      doc = Yelixer.Doc.new()
      doc = ContentType.create(doc, :text, "seed")
      doc = ContentType.insert_text(doc, 0, "hello-mutated")
      update = Yelixer.Encoding.encode_update(doc)
      _new_commit = CommitStore.create_commit(store, u1, update, c1)

      assert DerivationRecord.stale?(record, store) == {:stale, [u1]}
    end

    test "an unreadable source reads {:unknown, _}, never :current", %{store: store} do
      {u1, c1} = create_text_doc(store, "hello")
      record = DerivationRecord.new(%{u1 => c1}, "t", "o")

      # Point stale?/2 at a store that isn't running at all — the
      # "unreadable source" case. A dead GenServer name must never be
      # silently reported as :current.
      dead_store = :"nonexistent_derivation_record_store_#{:rand.uniform(1_000_000_000)}"

      result = DerivationRecord.stale?(record, dead_store)

      assert match?({:unknown, _}, result)
      refute result == :current
    end

    test "a source with no commits at all reads {:unknown, _}", %{store: store} do
      never_written_uuid = UUID.uuid4()
      record = DerivationRecord.new(%{never_written_uuid => <<0, 0, 0>>}, "t", "o")

      assert {:unknown, [{:unknown, ^never_written_uuid, :no_current_commit}]} =
               DerivationRecord.stale?(record, store)
    end
  end
end
