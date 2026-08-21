defmodule Commonplace.GitBridge.ExporterAtPinTest do
  @moduledoc """
  Chit epic [6]-wiring: verified export at a pin. The exporter routes every
  doc/schema render through `Projection.project_doc_at`, so export bytes carry
  a verdict and a tampered store cannot be silently reproduced as a clean tree.

  The load-bearing gates:
    * F5 byte-identity — routing through the verified oracle does NOT change
      tree bytes (verdict is added metadata; the existing exporter_test.exs's
      13 exact-content assertions already prove this, and the pin-at-head vs
      unpinned test below guards it explicitly).
    * Tamper is UNMISSABLE — a positive detection of wrong bytes (content-
      address / signature failure) hard-fails the export and leaves a loud
      marker, never a clean-looking file. Both arms shown: the raw
      reconstruction layer ABSORBS the tamper (Finding 4), the verified path
      CATCHES it.
    * Unverified ≠ wrong — an unsigned doc exports honestly (not hard-failed).
  """
  use ExUnit.Case, async: true
  import Bitwise

  alias Commonplace.GitBridge.Exporter
  alias Commonplace.Tree.{Schema, DocBuilder}
  alias Commonplace.Document.ContentType
  alias Commonplace.Store.CommitStore
  alias Commonplace.Projection

  setup do
    store_dir = Path.join(System.tmp_dir!(), "cp_gb_pin_store_#{:rand.uniform(1_000_000_000)}")
    repo_dir = Path.join(System.tmp_dir!(), "cp_gb_pin_repo_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(store_dir)
    File.mkdir_p!(repo_dir)
    store_name = :"gb_pin_store_#{:rand.uniform(1_000_000_000)}"
    start_supervised!({CommitStore, data_dir: store_dir, name: store_name})

    on_exit(fn ->
      File.rm_rf!(store_dir)
      File.rm_rf!(repo_dir)
    end)

    %{store: store_name, repo_dir: repo_dir}
  end

  # --- helpers ---

  defp text_update(name, content) do
    Yelixer.Doc.new()
    |> ContentType.create(:text, name)
    |> ContentType.insert_text(0, content)
    |> Yelixer.Encoding.encode_update()
  end

  defp create_text(store, uuid, name, content) do
    CommitStore.create_commit(store, uuid, text_update(name, content), nil)
  end

  defp create_schema(store, uuid, schema_doc) do
    CommitStore.create_commit(store, uuid, Yelixer.Encoding.encode_update(schema_doc), nil)
  end

  defp signed_ctx do
    {pub, priv} = Commonplace.Crypto.Signing.generate_keypair()
    signer_id = Commonplace.Crypto.Signing.signer_id("alice-uuid", pub)

    ctx = %Commonplace.Crypto.SigningContext{
      identity_uuid: "alice-uuid",
      private_key: priv,
      public_key: pub
    }

    {ctx, signer_id}
  end

  # Overwrite a stored commit row directly (a store-tamperer with write access).
  defp overwrite_commit(store, commit_id, mutate) do
    db = CommitStore.db_handle(store)
    {:ok, commit} = CommitStore.get_commit(store, commit_id)
    CubDB.put(db, {:commit, commit_id}, mutate.(commit))
  end

  defp read_tree(dir) do
    Path.wildcard(Path.join(dir, "**/*"))
    |> Enum.filter(&File.regular?/1)
    |> Map.new(fn path -> {Path.relative_to(path, dir), File.read!(path)} end)
  end

  # --- tests ---

  test "verdict is carried in the manifest for each exported doc", %{store: store, repo_dir: dir} do
    create_text(store, "u-a", "a.txt", "hello")
    root = Schema.new_schema() |> Schema.add_file("a.txt", "u-a")
    create_schema(store, "u-root", root)

    {:ok, result} = Exporter.export("u-root", dir, store)

    entry = result.manifest["a.txt"]
    assert entry.uuid == "u-a"
    assert Map.has_key?(entry, :verdict)
    # a clean unsigned commit corroborates with honest 0-verified coverage
    assert match?({:corroborated, _}, entry.verdict) or entry.verdict == :witnessed or
             match?({:declared, _, _}, entry.verdict)
  end

  test "pin reads the pinned historical commit, not the head", %{store: store, repo_dir: dir} do
    c1 = create_text(store, "u-a", "a.txt", "one")
    # advance head to v2 as a real edit of v1's doc (same lineage), so the
    # chain replays to "one two" rather than merging two independent inserts.
    {:ok, doc1} = DocBuilder.reconstruct_doc(store, "u-a", mint: false)
    doc2 = ContentType.insert_text(doc1, 3, " two")
    CommitStore.create_chained_commit(store, "u-a", Yelixer.Encoding.encode_update(doc2))

    root = Schema.new_schema() |> Schema.add_file("a.txt", "u-a")
    root_c1 = create_schema(store, "u-root", root)

    # unpinned: head content
    {:ok, _} = Exporter.export("u-root", dir, store)
    assert File.read!(Path.join(dir, "a.txt")) == "one two"

    # pinned to v1 (and the root at its only commit): the older content
    pin = %{"u-a" => c1.id, "u-root" => root_c1.id}
    {:ok, _} = Exporter.export("u-root", dir, store, %{}, pin)
    assert File.read!(Path.join(dir, "a.txt")) == "one"
  end

  test "unsigned clean doc exports honestly (unverified is not tamper)", %{
    store: store,
    repo_dir: dir
  } do
    create_text(store, "u-a", "a.txt", "hello")
    root = Schema.new_schema() |> Schema.add_file("a.txt", "u-a")
    create_schema(store, "u-root", root)

    {:ok, result} = Exporter.export("u-root", dir, store)
    assert File.read!(Path.join(dir, "a.txt")) == "hello"
    assert match?({:corroborated, _}, result.manifest["a.txt"].verdict)
  end

  test "store tamper hard-fails the export — both arms: raw ABSORBS, verified CATCHES", %{
    store: store,
    repo_dir: dir
  } do
    c = create_text(store, "u-a", "a.txt", "hello")
    root = Schema.new_schema() |> Schema.add_file("a.txt", "u-a")
    create_schema(store, "u-root", root)

    # A store-tamper that yjs replay is blind to: change metadata (part of the
    # content-address) while leaving the update untouched — deterministically
    # absorbed by replay, deterministically caught by the content-address check.
    overwrite_commit(store, c.id, fn commit ->
      %{commit | metadata: Map.put(commit.metadata || %{}, :injected, true)}
    end)

    # ARM 1 (Finding 4 baseline): the raw reconstruction layer ABSORBS it —
    # replay of the untouched update succeeds, no integrity check, silent.
    assert {:ok, _doc} = DocBuilder.reconstruct_doc(store, "u-a", mint: false)

    # ARM 2: the verified oracle CATCHES it loud...
    assert {:error, {:content_address_mismatch, _}} =
             Projection.project_doc_at("u-a", c.id, store: store)

    # ...so the export hard-fails, and the file on disk is a loud marker, not
    # the clean-looking content — unmissable by construction.
    assert {:error, {:unverifiable_pin, offenders}} = Exporter.export("u-root", dir, store)
    assert Enum.any?(offenders, fn {_rel, uuid, _v} -> uuid == "u-a" end)
    assert File.read!(Path.join(dir, "a.txt")) =~ "VERIFICATION FAILED"
    refute File.read!(Path.join(dir, "a.txt")) == "hello"
  end

  test "tampering a SIGNED commit's bytes hard-fails via signature", %{
    store: store,
    repo_dir: dir
  } do
    {ctx, _signer} = signed_ctx()

    c =
      CommitStore.create_commit(store, "u-s", text_update("s.txt", "signed"), nil, %{},
        signing_context: ctx
      )

    root = Schema.new_schema() |> Schema.add_file("s.txt", "u-s")
    create_schema(store, "u-root", root)

    # clean export first: succeeds
    {:ok, _} = Exporter.export("u-root", dir, store)
    assert File.read!(Path.join(dir, "s.txt")) == "signed"

    # flip one byte of the stored update, leaving id + signature — the
    # signature no longer verifies over the content.
    overwrite_commit(store, c.id, fn commit ->
      <<h, rest::binary>> = commit.update
      %{commit | update: <<bxor(h, 1)>> <> rest}
    end)

    assert {:error, {:unverifiable_pin, offenders}} = Exporter.export("u-root", dir, store)
    assert Enum.any?(offenders, fn {_rel, uuid, _v} -> uuid == "u-s" end)
    assert File.read!(Path.join(dir, "s.txt")) =~ "VERIFICATION FAILED"
  end

  test "F5: pin-at-current-heads produces a byte-identical tree to the unpinned export", %{
    store: store,
    repo_dir: dir
  } do
    a = create_text(store, "u-a", "a.txt", "alpha")
    # b as a clean single-commit map doc
    b =
      CommitStore.create_commit(
        store,
        "u-b",
        Yelixer.Doc.new()
        |> ContentType.create(:map, "b.json")
        |> ContentType.set_key("k", "v")
        |> Yelixer.Encoding.encode_update(),
        nil
      )

    root =
      Schema.new_schema()
      |> Schema.add_file("a.txt", "u-a")
      |> Schema.add_file("b.json", "u-b")

    root_c = create_schema(store, "u-root", root)

    {:ok, _} = Exporter.export("u-root", dir, store)
    unpinned = read_tree(dir)
    assert map_size(unpinned) == 2

    # explicit pin at the current heads = the same content
    pin = %{"u-a" => a.id, "u-b" => b.id, "u-root" => root_c.id}
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    {:ok, _} = Exporter.export("u-root", dir, store, %{}, pin)
    pinned = read_tree(dir)

    assert pinned == unpinned
  end
end
