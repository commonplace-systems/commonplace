defmodule Commonplace.Trust.CodeDocHeuristicTest do
  use ExUnit.Case, async: false

  alias Commonplace.Trust.CodeDocHeuristic
  alias Commonplace.Document.ContentType
  alias Commonplace.Store.CommitStore
  alias Yelixer.Doc

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_codedoc_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    name = :"codedoc_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: name})
    on_exit(fn -> File.rm_rf!(dir) end)
    %{store: name}
  end

  defp commit_text(store, uuid, name, body) do
    doc = Doc.new() |> ContentType.create(:text, name)
    doc = ContentType.insert_text(doc, 0, body)
    update = Yelixer.Encoding.encode_update(doc)
    CommitStore.create_commit(store, uuid, update, nil, %{})
  end

  test "elixir source content is classified as code", %{store: store} do
    uuid = "11111111-1111-1111-1111-111111111111"
    commit_text(store, uuid, "_renderer.ex", "defmodule Foo do\n  def x, do: 1\nend\n")
    assert CodeDocHeuristic.code_doc?(uuid, store)
  end

  test "plain prose text is NOT code", %{store: store} do
    uuid = "22222222-2222-2222-2222-222222222222"
    commit_text(store, uuid, "notes", "the quick brown fox, defmodule mentioned in prose")
    refute CodeDocHeuristic.code_doc?(uuid, store)
  end

  test "a __processes.json declaration is classified as code", %{store: store} do
    uuid = "33333333-3333-3333-3333-333333333333"
    json = ~s({"worker": {"command": "echo hi", "mode": "sandbox_exec"}})
    commit_text(store, uuid, "__processes.json", json)
    assert CodeDocHeuristic.code_doc?(uuid, store)
  end

  test "missing doc -> not classifiable -> false (best-effort)", %{store: store} do
    refute CodeDocHeuristic.code_doc?("00000000-0000-0000-0000-000000000000", store)
  end
end
