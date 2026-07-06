defmodule Commonplace.Tree.CherrypickTest do
  @moduledoc """
  CX-b70: apply specific commits from one branch to another.

  Cherry-pick takes a source commit_id and a target doc_uuid, extracts
  the DELTA the source commit introduced (ops not already present in
  the source's parent), applies that delta to the target's latest
  state, and creates a new chained commit on the target with the
  merged full-state encoding.

  Because Yjs CRDT merges are idempotent and commutative, applying the
  same delta twice is a no-op: the second cherry-pick materializes a
  commit whose content equals the current state, and CubDB's CAS will
  treat it as a no-op write if the derived commit id already exists.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Tree.{Cherrypick, DocBuilder, Fork}
  alias Commonplace.Document.ContentType
  alias Commonplace.Store.CommitStore
  alias Yelixer.{Doc, Encoding}

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_cherry_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    name = :"cherry_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: name})
    on_exit(fn -> File.rm_rf!(dir) end)
    %{store: name}
  end

  defp text_commit(store, uuid, content, opts \\ []) do
    doc = Doc.new(client_id: Keyword.get(opts, :client_id, 1))
    doc = ContentType.create(doc, :text, "doc")
    doc = ContentType.insert_text(doc, 0, content)
    update = Encoding.encode_update(doc)

    case Keyword.get(opts, :parent) do
      nil -> CommitStore.create_commit(store, uuid, update, nil)
      _ -> CommitStore.create_chained_commit(store, uuid, update)
    end
  end

  defp content_of(store, uuid) do
    case DocBuilder.reconstruct_doc(store, uuid) do
      {:ok, doc} -> ContentType.get_content(doc)
      :none -> nil
    end
  end

  describe "cherrypick/3" do
    test "applies the source commit's delta to a forked target",
         %{store: store} do
      # Cherry-pick is only semantically well-defined across branches
      # that share ancestry — otherwise the source's op refs (origin /
      # right_origin) point at items the target has never seen and the
      # integration fails. For unrelated docs, Build 6/7 late-edit
      # translation is the right tool.
      source = UUID.uuid4()
      text_commit(store, source, "hello")
      target = Fork.fork_directory(source, store)

      # Source advances after the fork: "hello world".
      {:ok, source_base} = DocBuilder.reconstruct_doc(store, source)
      source_extended = ContentType.insert_text(source_base, 5, " world")
      second_commit =
        CommitStore.create_chained_commit(store, source, Encoding.encode_update(source_extended))

      # Target independently adds something too.
      {:ok, target_base} = DocBuilder.reconstruct_doc(store, target)
      target_modified = ContentType.insert_text(target_base, 0, "[fork] ")
      CommitStore.create_chained_commit(store, target, Encoding.encode_update(target_modified))

      assert {:ok, new_commit} = Cherrypick.cherrypick(store, second_commit.id, target)
      assert is_binary(new_commit.id)

      merged = content_of(store, target)
      assert merged =~ "[fork]"
      assert merged =~ " world"
    end

    test "idempotent on repeat — picking same source twice yields same final state",
         %{store: store} do
      source = UUID.uuid4()
      target = UUID.uuid4()

      text_commit(store, source, "alpha")
      text_commit(store, target, "beta", client_id: 2)

      {:ok, source_commit} = CommitStore.latest_commit(store, source)

      {:ok, _} = Cherrypick.cherrypick(store, source_commit.id, target)
      after_first = content_of(store, target)

      {:ok, _} = Cherrypick.cherrypick(store, source_commit.id, target)
      after_second = content_of(store, target)

      assert after_first == after_second
    end

    test "returns error when source commit id is not found", %{store: store} do
      target = UUID.uuid4()
      text_commit(store, target, "x")

      bogus = :crypto.hash(:sha256, "nonexistent-commit")
      assert {:error, :source_commit_not_found} = Cherrypick.cherrypick(store, bogus, target)
    end

    test "cherry-pick onto fresh target creates a chain from target's genesis",
         %{store: store} do
      source = UUID.uuid4()
      target = UUID.uuid4()

      text_commit(store, source, "cherry")
      {:ok, source_commit} = CommitStore.latest_commit(store, source)

      # Target has never been written — maybe_stamp_genesis will create it.
      assert {:ok, new_commit} = Cherrypick.cherrypick(store, source_commit.id, target)
      assert new_commit.parent_id != nil

      assert content_of(store, target) =~ "cherry"
    end

    test "cherry-pick across forked branches reintegrates the forked commit",
         %{store: store} do
      # This is the canonical use case: fork source, both branches diverge,
      # cherry-pick one commit from the original back into the fork.
      #
      # Both branches' advances are built by reconstructing the REAL chain
      # first (as the moduledoc's precondition requires: cherry-pick is
      # only well-defined when the source's op refs point at items the
      # target has actually seen). Building a from-scratch `Doc.new/1` with
      # a colliding client_id and calling it a "branch advance" — as this
      # test used to — has no real origin ancestry at all; it only used to
      # "work" as a side effect of the pre-H1 bug (CX-cdyi), which pushed
      # the resulting un-integratable delta into the store raw and let a
      # later full-chain replay coincidentally satisfy its real
      # dependency. H1 buffers that delta instead (correctly — it's not
      # actually cherry-pickable) and excludes it from encode, so this
      # test must exercise a genuine shared-ancestry cherry-pick instead.
      source = UUID.uuid4()
      text_commit(store, source, "base")
      forked = Fork.fork_directory(source, store)

      # Source advances with a unique edit, anchored on real "base" content.
      {:ok, source_base} = DocBuilder.reconstruct_doc(store, source)
      source_extended = ContentType.insert_text(source_base, 4, " + source-only")

      source_new_commit =
        CommitStore.create_chained_commit(store, source, Encoding.encode_update(source_extended))

      # Fork advances differently, also anchored on its own real "base" content.
      {:ok, fork_base} = DocBuilder.reconstruct_doc(store, forked)
      fork_extended = ContentType.insert_text(fork_base, 4, " + fork-only")
      CommitStore.create_chained_commit(store, forked, Encoding.encode_update(fork_extended))

      # Cherry-pick source's advance into the fork.
      {:ok, _cherry_commit} =
        Cherrypick.cherrypick(store, source_new_commit.id, forked)

      merged = content_of(store, forked)
      assert merged =~ "source-only"
      assert merged =~ "fork-only"
    end
  end
end
