defmodule Commonplace.Black.QueryTest do
  @moduledoc """
  CX-vt9l.1 acceptance tests (bead body, epic CX-vt9l §2c/§3):

    (a) determinism — same query re-run at the same pin is byte-identical.
    (b) pin honesty — mutate + add after the pin; re-run at the OLD pin
        sees neither; re-run at latest sees both.
    (c) witness structure — content is entirely refs/labels, no
        reconstructed document content.
    (d) absent-from-pin — a doc missing from the pin is NOT PRESENT,
        never silently resolved at :latest.
    (e) existing black behavior is untouched (see black_test.exs /
        pattern_compute_test.exs, run separately per the task).
  """

  use ExUnit.Case, async: false

  alias Commonplace.Black.Query
  alias Commonplace.Crypto.{Signing, SigningContext}
  alias Commonplace.Document.ContentType
  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.Schema

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_black_query_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)

    store_name = :"commit_store_black_query_#{:rand.uniform(1_000_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store_name})

    on_exit(fn -> File.rm_rf!(dir) end)

    %{store: store_name}
  end

  defp mint_root(store) do
    root_uuid = UUID.uuid4()
    update = Yelixer.Encoding.encode_update(Schema.new_schema())
    CommitStore.create_commit(store, root_uuid, update, nil)
    root_uuid
  end

  defp latest(store, uuid) do
    case CommitStore.latest_commit(store, uuid) do
      {:ok, commit} -> commit.id
      _ -> nil
    end
  end

  defp load_schema(store, uuid) do
    case Commonplace.Tree.DocBuilder.reconstruct_snapshot(store, uuid) do
      {:ok, doc} -> doc
      :none -> Schema.new_schema()
    end
  end

  defp mint_map_file(store, parent_uuid, name, kvs) do
    file_uuid = UUID.uuid4()
    doc = Yelixer.Doc.new()
    doc = ContentType.create(doc, :map, name)
    doc = Enum.reduce(kvs, doc, fn {k, v}, acc -> ContentType.set_key(acc, k, v) end)
    update = Yelixer.Encoding.encode_update(doc)
    CommitStore.create_commit(store, file_uuid, update, nil)

    parent_doc = load_schema(store, parent_uuid) |> Schema.add_file(name, file_uuid)
    update = Yelixer.Encoding.encode_update(parent_doc)
    CommitStore.create_commit(store, parent_uuid, update, latest(store, parent_uuid))

    file_uuid
  end

  # Mutate a map file's content in place (a new commit on the SAME
  # uuid) — used to prove pin honesty.
  defp mutate_map_file(store, file_uuid, kvs) do
    doc =
      case Commonplace.Tree.DocBuilder.reconstruct_doc(store, file_uuid) do
        {:ok, d} -> d
        :none -> ContentType.create(Yelixer.Doc.new(), :map, "x")
      end

    doc = Enum.reduce(kvs, doc, fn {k, v}, acc -> ContentType.set_key(acc, k, v) end)
    update = Yelixer.Encoding.encode_update(doc)
    CommitStore.create_commit(store, file_uuid, update, latest(store, file_uuid))
  end

  describe "run/3 + run_at/4 determinism (a)" do
    test "same query re-run at the same pin is byte-identical", %{store: store} do
      root = mint_root(store)
      mint_map_file(store, root, "inv-1.json", %{"status" => "open"})
      mint_map_file(store, root, "inv-2.json", %{"status" => "closed"})

      {:ok, first} = Query.run(root, "*.json", store: store)
      {:ok, second} = Query.run_at(root, "*.json", first.pin, store: store)
      {:ok, third} = Query.run_at(root, "*.json", first.pin, store: store)

      assert first.hits == second.hits
      assert second.hits == third.hits
      assert second.pin == third.pin
      assert first.evaluator == second.evaluator
    end
  end

  describe "pin honesty (b, the load-bearing one)" do
    test "mutating a matched doc and adding a new match after the pin does not change an old-pin re-run", %{
      store: store
    } do
      root = mint_root(store)
      inv1 = mint_map_file(store, root, "inv-1.json", %{"status" => "open"})

      {:ok, captured} = Query.run(root, "*.json", store: store)
      assert Enum.map(captured.hits, & &1.path) == ["inv-1.json"]

      # Mutate the already-matched doc AND add a brand new matching doc.
      mutate_map_file(store, inv1, %{"status" => "closed"})
      mint_map_file(store, root, "inv-2.json", %{"status" => "open"})

      # Re-run at the OLD pin: unchanged — same single hit, same commit
      # recorded for inv-1.json, no inv-2.json.
      {:ok, replay} = Query.run_at(root, "*.json", captured.pin, store: store)
      assert replay.hits == captured.hits
      assert replay.pin == captured.pin

      # Re-run at latest (a fresh run/3, no at_pin): sees BOTH changes.
      {:ok, fresh} = Query.run(root, "*.json", store: store)
      paths = fresh.hits |> Enum.map(& &1.path) |> Enum.sort()
      assert paths == ["inv-1.json", "inv-2.json"]
      # inv-1.json's freshly observed pin commit differs from the old one.
      assert fresh.pin[inv1] != captured.pin[inv1]
    end
  end

  describe "witness structure (c)" do
    test "witness content is entirely refs/strings/maps-of-refs — no reconstructed content", %{
      store: store
    } do
      root = mint_root(store)
      mint_map_file(store, root, "inv-1.json", %{"status" => "open", "amount" => 42})

      {:ok, result} = Query.run(root, "*.json", store: store)
      witness = Query.witness(result, query: "*.json")

      assert Map.keys(witness) |> Enum.sort() == [
               "cut_label",
               "evaluator",
               "hits",
               "pin",
               "query",
               "truncated"
             ]

      # "query" is the pattern string itself, not resolved doc content.
      assert witness["query"] == "*.json"
      assert is_binary(witness["evaluator"])
      assert is_binary(witness["cut_label"])
      assert String.starts_with?(witness["cut_label"], "as seen at cut ")

      # "pin" is a map of uuid -> hex commit string, nothing else.
      assert is_map(witness["pin"])

      for {uuid, commit_hex} <- witness["pin"] do
        assert is_binary(uuid)
        assert is_binary(commit_hex)
        assert Regex.match?(~r/^[0-9a-f]+$/, commit_hex)
      end

      # "hits" is a list of path/uuid/commit refs — never the matched
      # doc's own content (no "status", no "amount" anywhere).
      assert is_list(witness["hits"])

      for hit <- witness["hits"] do
        assert Map.keys(hit) |> Enum.sort() == ["commit", "path", "uuid"]
        assert is_binary(hit["path"])
        assert is_binary(hit["uuid"])
        assert is_binary(hit["commit"])
      end

      # No key anywhere in the witness holds the matched doc's OWN
      # field names or values — only refs (path/uuid/commit) and
      # labels (query/evaluator/cut_label) ever appear.
      all_keys =
        [witness["hits"], [witness["pin"]]]
        |> List.flatten()
        |> Enum.flat_map(&Map.keys/1)

      refute "status" in all_keys
      refute "amount" in all_keys
    end

    test "witness/2 with a signing_context mints a real signed doc and returns its uuid", %{store: store} do
      root = mint_root(store)
      mint_map_file(store, root, "inv-1.json", %{"status" => "open"})

      {:ok, result} = Query.run(root, "*.json", store: store)

      {pub, priv} = Signing.generate_keypair()
      sc = %SigningContext{identity_uuid: "test-witness-signer", private_key: priv, public_key: pub}

      assert {:ok, witness_uuid} =
               Query.witness(result, query: "*.json", store: store, signing_context: sc)

      assert {:ok, doc} = Commonplace.Tree.DocBuilder.reconstruct_doc(store, witness_uuid)
      content = ContentType.get_content(doc)
      assert content["query"] == "*.json"
      assert is_map(content["pin"])
      assert is_list(content["hits"])

      {:ok, commit} = CommitStore.latest_commit(store, witness_uuid)
      assert String.starts_with?(commit.signer_id, "test-witness-signer@")
    end
  end

  describe "truncation honesty (CX-vt9l.6 — F3 seam ALWAYS reports it)" do
    # NON-VACUOUSNESS NOTE: the limit pair and the complete case below
    # exercise the SAME code path (`Query.run/3`) with only the cap or
    # corpus size changed, so a hard-coded `truncated` value cannot
    # satisfy both the positive and the negative assertion.

    test "LIMIT: a corpus exceeding a small limit: reports truncated via run/3", %{store: store} do
      root = mint_root(store)
      for i <- 1..20, do: mint_map_file(store, root, "f#{i}.json", %{"n" => i})

      {:ok, result} = Query.run(root, "*.json", store: store, limit: 5)

      assert length(result.hits) == 5
      assert %{limit: true, depth: []} = result.truncated
    end

    test "COMPLETE: the same corpus under a generous limit: reports the explicit :none, not an absent key",
         %{store: store} do
      root = mint_root(store)
      for i <- 1..20, do: mint_map_file(store, root, "f#{i}.json", %{"n" => i})

      {:ok, result} = Query.run(root, "*.json", store: store, limit: 1_000)

      assert length(result.hits) == 20
      assert Map.has_key?(result, :truncated)
      assert result.truncated == :none
    end

    test "DEPTH (sharp case — hit count alone cannot reveal this): matches below a small max_depth: report depth-truncation",
         %{store: store} do
      root = mint_root(store)
      sub = UUID.uuid4()
      CommitStore.create_commit(store, sub, Yelixer.Encoding.encode_update(Schema.new_schema()), nil)
      root_doc = load_schema(store, root) |> Schema.add_directory("sub", sub)
      CommitStore.create_commit(store, root, Yelixer.Encoding.encode_update(root_doc), latest(store, root))
      mint_map_file(store, sub, "inv-1.json", %{"status" => "open"})

      {:ok, result} = Query.run(root, "**/*.json", store: store, max_depth: 0)

      assert result.hits == []
      assert %{limit: false, depth: depth} = result.truncated
      assert depth != []
    end

    test "run_at/4 also always reports truncated (explicit :none on a complete replay)", %{
      store: store
    } do
      root = mint_root(store)
      mint_map_file(store, root, "inv-1.json", %{"status" => "open"})

      {:ok, captured} = Query.run(root, "*.json", store: store)
      assert captured.truncated == :none

      {:ok, replay} = Query.run_at(root, "*.json", captured.pin, store: store)
      assert replay.truncated == :none
    end

    test "witness/2 carries the truncation fact into the witness content", %{store: store} do
      root = mint_root(store)
      for i <- 1..20, do: mint_map_file(store, root, "f#{i}.json", %{"n" => i})

      {:ok, result} = Query.run(root, "*.json", store: store, limit: 5)
      witness = Query.witness(result, query: "*.json")

      assert Map.has_key?(witness, "truncated")
      assert %{"limit" => true, "depth" => []} = witness["truncated"]
    end

    test "witness/2 reports the explicit complete string, not an absent key, for an untruncated result",
         %{store: store} do
      root = mint_root(store)
      mint_map_file(store, root, "inv-1.json", %{"status" => "open"})

      {:ok, result} = Query.run(root, "*.json", store: store)
      witness = Query.witness(result, query: "*.json")

      assert witness["truncated"] == "none"
    end
  end

  describe "absent-from-pin (d)" do
    test "a doc not in the pin map is treated as absent, not resolved at latest", %{store: store} do
      root = mint_root(store)
      inv1 = mint_map_file(store, root, "inv-1.json", %{"status" => "open"})

      {:ok, captured} = Query.run(root, "*.json", store: store)
      assert Map.has_key?(captured.pin, inv1)

      # Strip inv-1.json's own entry out of the pin — it is still named
      # by the (pinned) root schema, but its own commit id is now
      # "not present at this cut".
      thin_pin = Map.delete(captured.pin, inv1)

      {:ok, replay} = Query.run_at(root, "*.json", thin_pin, store: store)
      assert replay.hits == []
      refute Map.has_key?(replay.pin, inv1)
    end

    test "a directory not in the pin map resolves as empty (not present), never :latest", %{store: store} do
      root = mint_root(store)
      sub_uuid = UUID.uuid4()
      update = Yelixer.Encoding.encode_update(Schema.new_schema())
      CommitStore.create_commit(store, sub_uuid, update, nil)

      root_doc = load_schema(store, root) |> Schema.add_directory("sub", sub_uuid)
      CommitStore.create_commit(store, root, Yelixer.Encoding.encode_update(root_doc), latest(store, root))

      mint_map_file(store, sub_uuid, "inv-1.json", %{"status" => "open"})

      {:ok, captured} = Query.run(root, "sub/*.json", store: store)
      assert Enum.map(captured.hits, & &1.path) == ["sub/inv-1.json"]

      # Drop "sub"'s own entry from the pin — the subdirectory itself
      # is now "not present at this cut", so nothing below it can match.
      thin_pin = Map.delete(captured.pin, sub_uuid)

      {:ok, replay} = Query.run_at(root, "sub/*.json", thin_pin, store: store)
      assert replay.hits == []
    end
  end
end
