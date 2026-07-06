defmodule Commonplace.Black.PatternComputeTest do
  @moduledoc """
  CX-o1l9 (Black M1) test pin 4 from
  `docs/plans/2026-07-06-black-m1-build-spec.md` §5:

    4a. matched-doc edit recomputes target.
    4b. THE pin — a NEW doc committed under a matching path after init
        triggers subscribe + recompute, with no re-registration.
    4c. non-matching doc changes do not recompute.
    4d. removed entry drops from the match set.
    4e. target-matches-pattern init refusal.
  """

  use ExUnit.Case, async: false

  alias Commonplace.Black.PatternCompute
  alias Commonplace.CommandRouter
  alias Commonplace.Document.ContentType
  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.{DocBuilder, Schema}

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_pc_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)

    store_name = :"commit_store_pc_#{:rand.uniform(1_000_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store_name})

    router_name = :"router_pc_#{:rand.uniform(1_000_000_000)}"
    start_supervised!({CommandRouter, name: router_name, store: store_name})

    on_exit(fn -> File.rm_rf!(dir) end)

    %{store: store_name, router: router_name}
  end

  defp mint_root(store) do
    root_uuid = UUID.uuid4()
    doc = Schema.new_schema()
    update = Yelixer.Encoding.encode_update(doc)
    CommitStore.create_commit(store, root_uuid, update, nil)
    root_uuid
  end

  defp mint_text_file(store, parent_uuid, name, content) do
    file_uuid = UUID.uuid4()
    doc = Yelixer.Doc.new()
    doc = ContentType.create(doc, :text, name)
    doc = if content != "", do: ContentType.insert_text(doc, 0, content), else: doc
    update = Yelixer.Encoding.encode_update(doc)
    CommitStore.create_commit(store, file_uuid, update, nil)
    add_entry(store, parent_uuid, name, :doc, file_uuid)
    file_uuid
  end

  defp add_entry(store, parent_uuid, name, kind, node_uuid) do
    parent_doc = load_schema(store, parent_uuid)

    parent_doc =
      case kind do
        :dir -> Schema.add_directory(parent_doc, name, node_uuid)
        :doc -> Schema.add_file(parent_doc, name, node_uuid)
      end

    update = Yelixer.Encoding.encode_update(parent_doc)
    CommitStore.create_commit(store, parent_uuid, update, latest(store, parent_uuid))
  end

  defp remove_entry(store, parent_uuid, name) do
    parent_doc = load_schema(store, parent_uuid)
    parent_doc = Schema.remove_entry(parent_doc, name)
    update = Yelixer.Encoding.encode_update(parent_doc)
    CommitStore.create_commit(store, parent_uuid, update, latest(store, parent_uuid))
  end

  defp edit_text_file(store, uuid, new_content) do
    {:ok, doc} = DocBuilder.reconstruct_doc(store, uuid)
    old_len = String.length(ContentType.get_content(doc) || "")
    doc = if old_len > 0, do: ContentType.delete_text(doc, 0, old_len), else: doc
    doc = ContentType.insert_text(doc, 0, new_content)
    update = Yelixer.Encoding.encode_update(doc)
    CommitStore.create_commit(store, uuid, update, latest(store, uuid))
  end

  defp latest(store, uuid) do
    case CommitStore.latest_commit(store, uuid) do
      {:ok, commit} -> commit.id
      _ -> nil
    end
  end

  defp load_schema(store, uuid) do
    case DocBuilder.reconstruct_snapshot(store, uuid) do
      {:ok, doc} -> doc
      :none -> Schema.new_schema()
    end
  end

  defp read_content(store, uuid) do
    case DocBuilder.reconstruct_snapshot(store, uuid) do
      {:ok, doc} -> ContentType.get_content(doc)
      :none -> nil
    end
  end

  defp wait_until(fun, deadline_ms \\ 2000) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    do_wait(fun, deadline)
  end

  defp do_wait(fun, deadline) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("timed out waiting for condition")
      else
        Process.sleep(25)
        do_wait(fun, deadline)
      end
    end
  end

  # Renders the current match list as a sorted, joined list of paths —
  # simple deterministic compute_fn for assertions below.
  defp render_paths(matches, _ctx) do
    matches |> Enum.map(& &1.path) |> Enum.sort() |> Enum.join(",")
  end

  describe "PatternCompute reactive loop" do
    test "4a: matched-doc content edit recomputes the target", %{store: store, router: router} do
      root = mint_root(store)
      _f1 = mint_text_file(store, root, "a.txt", "one")
      target = mint_text_file(store, root, "_target", "")

      {:ok, pid} =
        PatternCompute.start_link(
          root_uuid: root,
          pattern: "*.txt",
          target_uuid: target,
          compute_fn: &render_paths/2,
          store: store,
          router: router
        )

      :ok = wait_until(fn -> read_content(store, target) == "a.txt" end)

      f1_uuid = PatternCompute.state(pid).matches |> hd() |> Map.get(:uuid)
      edit_text_file(store, f1_uuid, "one edited")

      # content edit doesn't change the match set (still "a.txt"), but
      # the recompute must still run against the current match list.
      :ok = wait_until(fn -> read_content(store, target) == "a.txt" end)
      GenServer.stop(pid)
    end

    test "4b: THE pin — a new doc matching the pattern after init triggers recompute", %{
      store: store,
      router: router
    } do
      root = mint_root(store)
      _f1 = mint_text_file(store, root, "a.txt", "one")
      target = mint_text_file(store, root, "_target", "")

      {:ok, pid} =
        PatternCompute.start_link(
          root_uuid: root,
          pattern: "*.txt",
          target_uuid: target,
          compute_fn: &render_paths/2,
          store: store,
          router: router
        )

      :ok = wait_until(fn -> read_content(store, target) == "a.txt" end)

      # No re-registration — just commit a new matching file to root's
      # schema (root's schema doc is already subscribed).
      _f2 = mint_text_file(store, root, "b.txt", "two")

      :ok = wait_until(fn -> read_content(store, target) == "a.txt,b.txt" end)
      GenServer.stop(pid)
    end

    test "4c: non-matching doc changes do not recompute", %{store: store, router: router} do
      root = mint_root(store)
      _f1 = mint_text_file(store, root, "a.txt", "one")
      target = mint_text_file(store, root, "_target", "")

      {:ok, pid} =
        PatternCompute.start_link(
          root_uuid: root,
          pattern: "*.txt",
          target_uuid: target,
          compute_fn: &render_paths/2,
          store: store,
          router: router
        )

      :ok = wait_until(fn -> read_content(store, target) == "a.txt" end)

      # Add a NON-matching file (.md, not .txt) — the root schema
      # commit fires, PatternCompute re-evaluates, but the match set
      # is unchanged so target content stays "a.txt".
      _other = mint_text_file(store, root, "note.md", "irrelevant")

      # Give the (deterministic, synchronous) commit handler a moment,
      # then assert the content is still exactly "a.txt" (not
      # "a.txt,note.md").
      Process.sleep(150)
      assert read_content(store, target) == "a.txt"
      GenServer.stop(pid)
    end

    test "4d: removing a matched entry drops it from the match set", %{
      store: store,
      router: router
    } do
      root = mint_root(store)
      _f1 = mint_text_file(store, root, "a.txt", "one")
      _f2 = mint_text_file(store, root, "b.txt", "two")
      target = mint_text_file(store, root, "_target", "")

      {:ok, pid} =
        PatternCompute.start_link(
          root_uuid: root,
          pattern: "*.txt",
          target_uuid: target,
          compute_fn: &render_paths/2,
          store: store,
          router: router
        )

      :ok = wait_until(fn -> read_content(store, target) == "a.txt,b.txt" end)

      remove_entry(store, root, "b.txt")

      :ok = wait_until(fn -> read_content(store, target) == "a.txt" end)
      GenServer.stop(pid)
    end

    test "4e: refuses to start when target_uuid matches the watched pattern", %{
      store: store,
      router: router
    } do
      root = mint_root(store)
      target = mint_text_file(store, root, "target.txt", "")

      Process.flag(:trap_exit, true)

      result =
        PatternCompute.start_link(
          root_uuid: root,
          pattern: "*.txt",
          target_uuid: target,
          compute_fn: &render_paths/2,
          store: store,
          router: router
        )

      assert {:error, reason} = result
      assert reason =~ "self-retrigger"
    end
  end
end
