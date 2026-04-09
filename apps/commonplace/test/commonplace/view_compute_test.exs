defmodule Commonplace.ViewComputeTest do
  use ExUnit.Case, async: false

  alias Commonplace.ViewCompute
  alias Commonplace.CommandRouter
  alias Commonplace.Store.CommitStore
  alias Commonplace.Document.ContentType
  alias Commonplace.Tree.DocBuilder

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_vc_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)

    store_name = :"commit_store_vc_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store_name})

    # Dedicated CommandRouter bound to this test's store so writes
    # don't collide with the app's global router (which uses the
    # default CommitStoreClient).
    router_name = :"router_vc_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommandRouter, name: router_name, store: store_name})

    on_exit(fn -> File.rm_rf!(dir) end)

    %{store: store_name, router: router_name, dir: dir}
  end

  defp seed_text_doc(store, content) do
    uuid = UUID.uuid4()
    doc = Yelixer.Doc.new()
    doc = ContentType.create(doc, :text, "seed")
    # Yelixer.Types.Text.insert rejects empty binaries, so only insert
    # when content is non-empty. An empty-content doc is a valid seeded
    # state — the first compute will grow it via Diff.apply_diff.
    doc = if content != "", do: ContentType.insert_text(doc, 0, content), else: doc
    update = Yelixer.Encoding.encode_update(doc)
    CommitStore.create_commit(store, uuid, update, nil)
    uuid
  end

  defp read_content(store, uuid) do
    case DocBuilder.reconstruct_snapshot(store, uuid) do
      {:ok, doc} -> ContentType.get_content(doc)
      :none -> nil
    end
  end

  describe "ViewCompute" do
    test "runs initial compute at startup and writes to target", %{store: store, router: router} do
      source_uuid = seed_text_doc(store, "hello world")
      target_uuid = seed_text_doc(store, "")

      compute_fn = fn src -> "VIEW: " <> String.upcase(src) end

      {:ok, pid} =
        ViewCompute.start_link(
          source_uuid: source_uuid,
          target_uuid: target_uuid,
          compute_fn: compute_fn,
          store: store,
          router: router
        )

      :ok = wait_until(fn -> read_content(store, target_uuid) == "VIEW: HELLO WORLD" end)
      GenServer.stop(pid)
    end

    test "recomputes when source doc receives a new commit", %{store: store, router: router} do
      source_uuid = seed_text_doc(store, "original")
      target_uuid = seed_text_doc(store, "")

      compute_fn = fn src -> "[[" <> src <> "]]" end

      {:ok, pid} =
        ViewCompute.start_link(
          source_uuid: source_uuid,
          target_uuid: target_uuid,
          compute_fn: compute_fn,
          store: store,
          router: router
        )

      :ok = wait_until(fn -> read_content(store, target_uuid) == "[[original]]" end)

      # Write a new version of the source via the dedicated router
      {:ok, _} = CommandRouter.write(router, source_uuid, "updated")

      # CommitStore broadcasts on blue:UUID → ViewCompute picks it up →
      # recomputes and writes to target
      :ok = wait_until(fn -> read_content(store, target_uuid) == "[[updated]]" end)

      GenServer.stop(pid)
    end

    test "recompute/1 forces a synchronous recompute", %{store: store, router: router} do
      source_uuid = seed_text_doc(store, "start")
      target_uuid = seed_text_doc(store, "")

      compute_fn = fn src -> String.upcase(src) end

      {:ok, pid} =
        ViewCompute.start_link(
          source_uuid: source_uuid,
          target_uuid: target_uuid,
          compute_fn: compute_fn,
          store: store,
          router: router
        )

      :ok = wait_until(fn -> read_content(store, target_uuid) == "START" end)

      # Mutate source without going through the router (so no broadcast)
      doc = Yelixer.Doc.new()
      doc = ContentType.create(doc, :text, "seed")
      doc = ContentType.insert_text(doc, 0, "second")
      update = Yelixer.Encoding.encode_update(doc)
      CommitStore.create_chained_commit(store, source_uuid, update)

      # force a sync recompute
      :ok = ViewCompute.recompute(pid)
      assert read_content(store, target_uuid) == "SECOND"

      GenServer.stop(pid)
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
        Process.sleep(50)
        do_wait(fun, deadline)
      end
    end
  end
end
