defmodule Commonplace.Projection.LegacyRowShapeTest do
  @moduledoc """
  CX-6scm: adding a struct field to `Commonplace.Store.Commit` is a
  MIGRATION, because the store holds serialised `%Commit{}` terms.

  `CubDB` values are `:erlang.term_to_binary/1` of the struct. A row
  written before `:post_state_hash` existed round-trips back as a map
  that simply **does not have that key** — `Map.has_key?/2` is false,
  `%Commit{post_state_hash: _} = row` fails to match, and `row.post_state_hash`
  raises `KeyError`.

  There are 64,651 such rows on the live serve. Every one of them is read
  by `Commonplace.Projection`. So this is not a hypothetical: without the
  `Map.get/3` reads that this test pins, the fix would `KeyError` on the
  first legacy commit it touched.

  The tests below construct the pre-CX-6scm term shape explicitly rather
  than trusting that the current struct happens to serialise that way —
  the whole point is that the OLD shape differs from the current one, so
  building it from the current struct would test nothing.
  """
  use ExUnit.Case, async: true

  alias Commonplace.Projection
  alias Commonplace.Store.{Commit, CommitStore}
  alias Yelixer.{Doc, Encoding}
  alias Yelixer.Types.Text

  # A commit term exactly as it was written before `:post_state_hash`
  # was added to the struct.
  defp legacy_term(fields) do
    base = %{
      __struct__: Commit,
      id: nil,
      doc_uuid: nil,
      parent_id: nil,
      update: <<>>,
      timestamp: DateTime.utc_now(),
      signature: nil,
      signer_id: nil,
      metadata: %{},
      merge_parents: []
    }

    base
    |> Map.merge(Map.new(fields))
    |> :erlang.term_to_binary()
    |> :erlang.binary_to_term()
  end

  test "the legacy shape really is missing the field (else nothing below is tested)" do
    refute Map.has_key?(legacy_term([]), :post_state_hash),
           "fixture no longer reproduces the pre-CX-6scm term shape"
  end

  test "content_address_of/1 reads a legacy row without raising" do
    doc = Doc.new(client_id: 3)
    {doc, _} = Doc.get_or_create_type(doc, "t", :text)
    doc = Text.insert(doc, "t", 0, "legacy")
    update = Encoding.encode_update(doc)

    modern = Commit.new("d", update, nil, %{kind: :regular})

    legacy =
      legacy_term(id: modern.id, doc_uuid: "d", update: update, metadata: %{kind: :regular})

    # The address must be IDENTICAL to the modern struct's — a legacy row
    # with no hash and a modern row with `nil` are the same commit, which
    # is what the `nil -> <<>>` hatch in `content_address/5` buys.
    assert Commit.content_address_of(legacy) == modern.id
    assert Commit.verify_id(legacy) == :ok
  end

  test "project_at/3 projects a store full of legacy rows" do
    dir = Path.join(System.tmp_dir!(), "cp_legacy_rows_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    name = :"legacy_store_#{:rand.uniform(1_000_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: name})
    on_exit(fn -> File.rm_rf!(dir) end)
    db = CommitStore.db_handle(name)

    u = "legacy-doc"

    doc = Doc.new(client_id: 3)
    {doc, _} = Doc.get_or_create_type(doc, "t", :text)
    doc = Text.insert(doc, "t", 0, "legacy content")
    update = Encoding.encode_update(doc)

    id = Commit.new(u, update, nil, %{kind: :regular}).id
    row = legacy_term(id: id, doc_uuid: u, update: update, metadata: %{kind: :regular})

    CubDB.put(db, {:commit, id}, row)
    CubDB.put(db, {:latest, u}, id)

    assert {:ok, bytes, {:corroborated, _}} =
             Projection.project_at(u, id, store: name, head_path: :direct)

    assert bytes == update
  end
end
