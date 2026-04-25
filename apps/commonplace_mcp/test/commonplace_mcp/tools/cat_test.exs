defmodule Commonplace.MCP.Tools.CatTest do
  @moduledoc """
  CX-re6b round 16: cat is the strongest BEAM-death candidate post
  CX-71ej + safe_invoke. Hypothesis: cat returning megabytes of content
  triggers OOM mid-`IO.write`, killing the escript and tearing the
  transport. Defense: cap structured-payload content size and return a
  summary when oversized.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Document.ContentType
  alias Commonplace.MCP.Tools.Cat
  alias Commonplace.Store.CommitStore

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_cat_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    name = :"commit_store_cat_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: name})

    on_exit(fn -> File.rm_rf!(dir) end)

    # CommitStoreClient has no per-call store override — it routes via a
    # pinned store name. We can't intercept the dispatch without an
    # injection layer, so these tests start the production-named store
    # and tear it down between tests.
    %{store: name, dir: dir}
  end

  defp create_text_doc(store, content) do
    uuid = UUID.uuid4()
    doc = Yelixer.Doc.new()
    doc = ContentType.create(doc, :text, "test")
    doc = ContentType.insert_text(doc, 0, content)
    update = Yelixer.Encoding.encode_update(doc)
    CommitStore.create_commit(store, uuid, update, nil)
    uuid
  end

  describe "run/1" do
    test "tiny text doc returns content in structured payload", %{store: _store} do
      uuid = create_text_doc(Commonplace.Store.CommitStore, "hello")

      assert {:ok, response} = Cat.run(%{"uuid" => uuid})

      structured =
        response["content"]
        |> Enum.at(1)
        |> Map.get("text")
        |> Jason.decode!()

      assert structured["content"] == "hello"
      refute Map.has_key?(structured, "truncated")
    end

    # Defense against OOM mid-IO.write: when content exceeds the cap,
    # replace it with a {size_bytes, truncated, preview} summary so the
    # serialized response never approaches a memory-pressure threshold.
    test "oversized text content is truncated with a summary", %{store: _store} do
      big_blob = :binary.copy("x", 200_000)
      uuid = create_text_doc(Commonplace.Store.CommitStore, big_blob)

      assert {:ok, response} = Cat.run(%{"uuid" => uuid})

      structured =
        response["content"]
        |> Enum.at(1)
        |> Map.get("text")
        |> Jason.decode!()

      assert structured["truncated"] == true
      assert structured["size_bytes"] == 200_000
      assert is_binary(structured["preview"])
      # Preview must be small enough to keep the full response under cap
      assert byte_size(structured["preview"]) <= 4_096
      refute structured["content"] == big_blob
    end

    test "missing uuid returns clean not_found", %{store: _store} do
      assert {:error, "not found: " <> _} =
               Cat.run(%{"uuid" => "00000000-0000-0000-0000-000000000000"})
    end

    test "non-string uuid returns invalid_params", %{store: _store} do
      assert {:error, :invalid_params, _} = Cat.run(%{"uuid" => 42})
    end
  end
end
