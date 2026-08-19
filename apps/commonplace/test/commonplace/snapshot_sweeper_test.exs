defmodule Commonplace.SnapshotSweeperTest do
  @moduledoc """
  Tests for the periodic snapshot-sweep service (CX-fab5).

  The sweeper walks all docs known to the local CommitStore on a
  configurable interval and invokes the SnapshotTrigger primitive on
  each — catching docs that have accumulated chain length but haven't
  been written recently (so the producer-side trigger CX-tvyb hasn't
  had a chance to fire).
  """
  use ExUnit.Case, async: false

  alias Commonplace.Document.ContentType
  alias Commonplace.SnapshotSweeper
  alias Commonplace.Store.CommitStore
  alias Yelixer.{Doc, ID, Integrate, Item}

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_sweeper_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    store_name = :"sweeper_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store_name})
    on_exit(fn -> File.rm_rf!(dir) end)
    %{store: store_name, dir: dir}
  end

  defp seed_chained_doc(store, n_commits) do
    uuid = UUID.uuid4()

    for i <- 1..n_commits do
      doc = Yelixer.Doc.new()
      doc = ContentType.create(doc, :text, "doc.txt")
      doc = ContentType.insert_text(doc, 0, "v#{i}")
      update = Yelixer.Encoding.encode_update(doc)

      if i == 1 do
        CommitStore.create_commit(store, uuid, update, nil)
      else
        CommitStore.create_chained_commit(store, uuid, update)
      end
    end

    uuid
  end

  # Seeds a doc whose only commit carries a genuine nested CRDT sub-type
  # (a `__sub:CLIENT:CLOCK` type, the kind `Yelixer.Doc.nested_subtype_names/1`
  # flags and `Commonplace.Store.Snapshotter.build_payload/2` refuses to
  # snapshot — the R5 guard). Unlike `Commonplace.Store.SnapshotterGuardTest`
  # (which pokes `doc.types` directly since that's a local-only field), this
  # needs to survive an encode/decode round trip through the CommitStore, so
  # it builds the nesting for real: one item holding `{:type, :map}` content
  # under a top-level named type, and a second item parented on the first
  # item's *id* rather than a type name. `Yelixer.Encoding`'s decode path
  # (`parent_type_key/1`) registers the `__sub:` type automatically for any
  # item parented on another item's id — exactly what a real nested-map
  # write would produce, if any facade minted one today (none does yet).
  defp seed_nested_subtype_doc(store) do
    uuid = UUID.uuid4()
    doc = Doc.new(client_id: 3)
    {doc, _} = Doc.get_or_create_type(doc, "top", :map)

    container_id = ID.new(doc.client_id, Doc.mint_clock(doc))
    container = Item.new(container_id, nil, nil, {:type, :map}, {:named, "top"}, "nested")
    {:ok, doc_store} = Integrate.integrate(doc.store, container, "top")
    doc = %{doc | store: doc_store}

    nested_id = ID.new(doc.client_id, Doc.mint_clock(doc))
    sub_key = "__sub:#{container_id.client}:#{container_id.clock}"
    nested = Item.new(nested_id, nil, nil, {:any, ["value"]}, {:id, container_id}, "inner")
    {:ok, doc_store} = Integrate.integrate(doc.store, nested, sub_key)
    doc = %{doc | store: doc_store}

    update = Yelixer.Encoding.encode_update(doc)
    CommitStore.create_commit(store, uuid, update, nil)

    # Chain a couple of plain edits on top so the doc's chain length
    # crosses a small test threshold (e.g. 3) — otherwise
    # SnapshotTrigger.maybe_snapshot/3 never gets far enough to attempt
    # a snapshot at all, and the R5 guard (and this test) never fires.
    for i <- 1..2 do
      extra_doc = Yelixer.Doc.new()
      extra_doc = ContentType.create(extra_doc, :text, "doc.txt")
      extra_doc = ContentType.insert_text(extra_doc, 0, "v#{i}")
      extra_update = Yelixer.Encoding.encode_update(extra_doc)
      CommitStore.create_chained_commit(store, uuid, extra_update)
    end

    uuid
  end

  describe "sweep/2" do
    test "snapshots every doc that has crossed the threshold", %{store: store} do
      bloated_uuid = seed_chained_doc(store, 5)
      tiny_uuid = seed_chained_doc(store, 1)

      assert :ok = SnapshotSweeper.sweep(store, chain_length_threshold: 3)

      bloated_log = CommitStore.commit_log(store, bloated_uuid)

      assert Enum.any?(bloated_log, fn c -> c.metadata[:kind] == :snapshot end),
             "bloated doc should have been snapshotted"

      tiny_log = CommitStore.commit_log(store, tiny_uuid)

      refute Enum.any?(tiny_log, fn c -> c.metadata[:kind] == :snapshot end),
             "below-threshold doc should NOT have been snapshotted"
    end

    test "is a no-op on a workspace with no docs", %{store: store} do
      assert :ok = SnapshotSweeper.sweep(store, chain_length_threshold: 3)
    end
  end

  describe "supervised loop" do
    test "fires sweep on the configured interval", %{store: store} do
      bloated_uuid = seed_chained_doc(store, 5)

      sup_name = :"sweeper_sup_#{:rand.uniform(1_000_000)}"

      {:ok, _sup} =
        Supervisor.start_link(
          [
            {SnapshotSweeper,
             [
               store: store,
               interval: 50,
               chain_length_threshold: 3
             ]}
          ],
          strategy: :one_for_one,
          name: sup_name
        )

      # Poll for the snapshot to land. The first tick fires after `interval`,
      # and the snapshot-trigger work is instantaneous.
      deadline = System.monotonic_time(:millisecond) + 5_000

      snapshotted? =
        Stream.repeatedly(fn ->
          Process.sleep(50)
          log = CommitStore.commit_log(store, bloated_uuid)
          Enum.any?(log, fn c -> c.metadata[:kind] == :snapshot end)
        end)
        |> Enum.reduce_while(false, fn done?, _acc ->
          cond do
            done? -> {:halt, true}
            System.monotonic_time(:millisecond) > deadline -> {:halt, false}
            true -> {:cont, false}
          end
        end)

      Supervisor.stop(sup_name)

      assert snapshotted?, "supervised sweeper did not snapshot the bloated doc within 5s"
    end
  end

  describe "stuck_docs/1 (CX-inpn)" do
    test "reports a doc stuck behind the nested-subtypes guard, and drops normal docs", %{
      store: store
    } do
      stuck_uuid = seed_nested_subtype_doc(store)
      normal_uuid = seed_chained_doc(store, 1)

      name = :"sweeper_#{:rand.uniform(1_000_000)}"

      {:ok, pid} =
        SnapshotSweeper.start_link(
          name: name,
          store: store,
          # Long enough that the scheduled tick from init/1 never fires
          # during the test; the sweep below is driven manually.
          interval: 999_000,
          chain_length_threshold: 3
        )

      # GenServer processes their mailbox in order, so sending :sweep and
      # then calling stuck_docs/1 sequences the read after the sweep
      # completes without any polling/sleep.
      send(pid, :sweep)

      stuck = SnapshotSweeper.stuck_docs(name)

      assert Enum.any?(stuck, fn {uuid, _names} -> uuid == stuck_uuid end),
             "expected #{stuck_uuid} (nested sub-type doc) to appear in stuck_docs/1"

      refute Enum.any?(stuck, fn {uuid, _names} -> uuid == normal_uuid end),
             "normal doc #{normal_uuid} should not appear in stuck_docs/1"

      {_uuid, names} = Enum.find(stuck, fn {uuid, _names} -> uuid == stuck_uuid end)
      assert names == ["__sub:3:0"]

      GenServer.stop(pid)
    end

    test "stuck_docs/1 is empty before any sweep has run", %{store: store} do
      _stuck_uuid = seed_nested_subtype_doc(store)

      name = :"sweeper_#{:rand.uniform(1_000_000)}"

      {:ok, pid} =
        SnapshotSweeper.start_link(
          name: name,
          store: store,
          interval: 999_000,
          chain_length_threshold: 3
        )

      assert SnapshotSweeper.stuck_docs(name) == []

      GenServer.stop(pid)
    end
  end
end
