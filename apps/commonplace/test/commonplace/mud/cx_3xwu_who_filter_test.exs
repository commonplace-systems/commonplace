defmodule Commonplace.MUD.Cx3xwuWhoFilterTest do
  @moduledoc """
  CX-3xwu (display half) — `who` must render a player IFF a LIVE session
  backs their `.usr` presence entry, keyed on `Commonplace.MUD.PresenceRegistry`
  membership (auto-cleared on process death), NOT on heartbeat recency. A
  live-but-slow player (stale heartbeat, live process) must still show; a
  dead session's `.usr` tree entry (fresh-looking or not) must not.

  This test builds a root dir with two `.usr` entries directly in the tree
  (mirroring the `walk_collect_players` shape — flat `.usr` files, no room
  nesting needed since the walk recurses on `:dir` and matches `.usr` at any
  depth). Only one of the two names is registered in `PresenceRegistry`,
  simulating a live session's `init/1` registration. Both entries carry an
  OLD heartbeat, so a pass here can't be explained by any hidden
  recency-based logic.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Document.ContentType
  alias Commonplace.MUD.{Parser, Schemas, Verbs}
  alias Commonplace.Presence
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.Schema
  alias Yelixer.Encoding

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_3xwu_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    n = :rand.uniform(1_000_000_000)
    store = :"cx3xwu_store_#{n}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: dir,
       name: :"cx3xwu_sup_#{n}",
       commit_store_name: store,
       trust_side_store_name: :"cx3xwu_tss_#{n}",
       pending_imports_name: :"cx3xwu_pi_#{n}"}
    )

    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, root} = Schemas.create_dir_with_meta(nil, nil, store, [])

    %{store: store, root: root}
  end

  # Build a `.usr` presence doc directly (bypassing `Presence.create/5`'s
  # always-`now()` heartbeat) so we can pin it to an OLD timestamp — proving
  # the `who` filter never reads it.
  defp create_stale_usr(name, dir_uuid, store) do
    fname = Presence.filename(name, :usr)
    uuid = UUID.uuid4()
    old = DateTime.utc_now() |> DateTime.add(-3600 * 24, :second) |> DateTime.to_iso8601()

    doc = Yelixer.Doc.new(client_id: :erlang.phash2(uuid))
    doc = ContentType.create(doc, :map, fname)
    doc = ContentType.set_key(doc, "name", name)
    doc = ContentType.set_key(doc, "type", "usr")
    doc = ContentType.set_key(doc, "status", "active")
    doc = ContentType.set_key(doc, "started_at", old)
    doc = ContentType.set_key(doc, "heartbeat", old)

    update = Encoding.encode_update(doc)
    _ = CommitStoreClient.create_commit(store, uuid, update, nil, %{kind: :regular}, [])

    {:ok, schema} = Schemas.load_dir_schema(dir_uuid, store)
    schema = Schema.add_file(schema, fname, uuid)
    dir_update = Encoding.encode_update(schema)

    r =
      CommitStoreClient.create_chained_commit(store, dir_uuid, dir_update, %{kind: :regular}, [])

    refute match?({:error, _}, r), "stale .usr entry must land in the tree"
    fname
  end

  defp who_text(root, store) do
    ctx = %{root_uuid: root, store: store}
    {:reply, text} = Verbs.dispatch(Parser.parse("who"), ctx)
    text
  end

  test "who renders only the LIVE-registered player, hiding the stale ghost", %{
    store: store,
    root: root
  } do
    create_stale_usr("alive", root, store)
    create_stale_usr("ghost", root, store)

    # Simulate a live session's `init/1` registration for "alive" ONLY. A
    # spawned process that stays alive for the test keeps the registration
    # real (auto-cleared on death, exactly like a real PlayerSession).
    test_pid = self()

    live_pid =
      spawn(fn ->
        Registry.register(Commonplace.MUD.PresenceRegistry, "alive.usr", nil)
        send(test_pid, :registered)

        receive do
          :stop -> :ok
        end
      end)

    assert_receive :registered, 1000

    text = who_text(root, store)

    # PIN 1: live-registered "alive" shows; unregistered "ghost" is hidden —
    # even though BOTH `.usr` entries exist in the tree.
    assert text =~ "alive"
    refute text =~ "ghost"

    # PIN 2: this holds despite BOTH entries carrying an OLD (24h-stale)
    # heartbeat — proving the filter keys on live-session REGISTRY
    # membership, not heartbeat recency. A live-but-slow player (stale
    # heartbeat, live process) is not penalized.
    send(live_pid, :stop)
  end

  test "unregistering (process death) makes a previously-live player vanish from who", %{
    store: store,
    root: root
  } do
    create_stale_usr("wanderer", root, store)

    test_pid = self()

    live_pid =
      spawn(fn ->
        Registry.register(Commonplace.MUD.PresenceRegistry, "wanderer.usr", nil)
        send(test_pid, :registered)

        receive do
          :stop -> :ok
        end
      end)

    assert_receive :registered, 1000
    assert who_text(root, store) =~ "wanderer"

    send(live_pid, :stop)
    # Registry auto-unregisters on process death; wait for it to be reflected.
    ref = Process.monitor(live_pid)
    assert_receive {:DOWN, ^ref, :process, ^live_pid, _}, 1000

    refute who_text(root, store) =~ "wanderer",
           "a dead session's stale .usr entry must not render once the process (and its registration) is gone"
  end
end
