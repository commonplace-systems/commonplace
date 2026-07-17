defmodule Commonplace.MUD.SessionViewTest do
  @moduledoc """
  CX-i9j3 (UI Inc-1) — proves the four invariants documented in
  `Commonplace.MUD.SessionView`'s moduledoc:

    1. delta-not-full encode (commit byte size stays flat as the
       transcript grows — the anti-regression guard against the O(N²)
       full-encode trap)
    2. region isolation (`<scrollback>` appends never touch `<room>`)
    3. node-signed (every commit signed by the node identity)
    4. append-only scrollback (turns land in order, never rewritten)

  plus a round-trip render test (live `to_html/1` vs. `load/2`'d
  `to_html/1` — replay fidelity).
  """
  use ExUnit.Case, async: false

  alias Commonplace.Crypto.{NodeIdentity, Signing}
  alias Commonplace.MUD.SessionView
  alias Commonplace.Store.CommitStore
  alias Yelixer.Encoding

  setup do
    Application.ensure_all_started(:phoenix_pubsub)

    case Phoenix.PubSub.Supervisor.start_link(name: Commonplace.PubSub) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    dir = Path.join(System.tmp_dir!(), "cp_session_view_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    n = :rand.uniform(1_000_000_000)
    store = :"session_view_store_#{n}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: dir,
       name: :"session_view_sup_#{n}",
       commit_store_name: store,
       trust_side_store_name: :"session_view_tss_#{n}",
       pending_imports_name: :"session_view_pi_#{n}"}
    )

    old_data_dir = Application.get_env(:commonplace, :data_dir)
    Application.put_env(:commonplace, :data_dir, dir)

    on_exit(fn ->
      Application.put_env(:commonplace, :data_dir, old_data_dir || "tmp/test_data")

      File.rm_rf!(dir)
    end)

    {:ok, node_identity} = NodeIdentity.identity()

    %{store: store, node_identity: node_identity}
  end

  test "delta stays flat across 50 command-turn appends (anti-regression: no O(N^2) full-encode)",
       %{store: store} do
    view = SessionView.new("sess-flat", store)

    {_final_view, sizes} =
      Enum.reduce(1..50, {view, []}, fn i, {view, sizes} ->
        sv_before = Yelixer.BlockStore.state_vector(view.doc.store)
        view = SessionView.append_command_turn(view, "cmd-#{i}", "out-#{i}")
        delta = Encoding.encode_diff(view.doc, sv_before)
        {view, [byte_size(delta) | sizes]}
      end)

    sizes = Enum.reverse(sizes)
    first_size = List.first(sizes)
    last_size = List.last(sizes)

    assert last_size <= first_size * 2,
           "expected turn 50's delta (#{last_size}b) to stay within ~2x turn 1's (#{first_size}b) — " <>
             "growth beyond that would indicate a full-encode regression"
  end

  test "region isolation: scrollback appends never touch the room subtree", %{store: store} do
    view = SessionView.new("sess-isolation", store)

    view =
      Enum.reduce(1..5, view, fn i, view ->
        SessionView.append_command_turn(view, "warm-up #{i}", "ok #{i}")
      end)

    # room is still an empty stub after several scrollback appends.
    assert Yelixer.Types.XMLElement.child_count(view.doc, view.room_name) == 0

    sv_before = Yelixer.BlockStore.state_vector(view.doc.store)
    view = SessionView.append_command_turn(view, "spin orrery", "You spin the orrery.")
    delta = Encoding.encode_diff(view.doc, sv_before)

    # room untouched by growth in scrollback: still empty, and the
    # isolated append's delta size doesn't depend on how much
    # scrollback already exists (region isolation ⇒ delta isolation).
    assert Yelixer.Types.XMLElement.child_count(view.doc, view.room_name) == 0
    assert Yelixer.Types.XMLElement.child_count(view.doc, view.scrollback_name) == 6

    small_view = SessionView.new("sess-isolation-baseline", store)
    baseline_sv = Yelixer.BlockStore.state_vector(small_view.doc.store)
    small_view = SessionView.append_command_turn(small_view, "spin orrery", "You spin the orrery.")
    baseline_delta = Encoding.encode_diff(small_view.doc, baseline_sv)

    assert byte_size(delta) <= byte_size(baseline_delta) * 2,
           "an append's delta size should not grow just because scrollback already has history"
  end

  test "every commit is node-signed", %{store: store, node_identity: node_identity} do
    view = SessionView.new("sess-signed", store)
    view = SessionView.append_command_turn(view, "look", "You see nothing special.")

    {:ok, commit} = CommitStore.latest_commit(store, view.uuid)
    assert {:ok, ^node_identity, _fingerprint} = Signing.parse_signer_id(commit.signer_id)
  end

  test "round-trip render: to_html matches after load/2 (replay fidelity)", %{store: store} do
    view = SessionView.new("sess-roundtrip", store)

    view = SessionView.append_command_turn(view, "spin orrery", "You spin the orrery slowly.")
    view = SessionView.append_ambient_turn(view, ["Grunk says: hello", "Grunk waves."])

    html = SessionView.to_html(view)

    assert html =~ "spin orrery"
    assert html =~ "You spin the orrery slowly."
    assert html =~ "Grunk says: hello"
    assert html =~ "Grunk waves."
    assert html =~ ~s(kind="command")
    assert html =~ ~s(kind="ambient")
    assert html =~ ~s(n="1")
    assert html =~ ~s(n="2")

    {:ok, loaded} = SessionView.load(view.uuid, store)
    assert SessionView.to_html(loaded) == html
  end

  test "append-only: scrollback child_count and turn n attributes read back in order", %{
    store: store
  } do
    view = SessionView.new("sess-append-only", store)

    view =
      Enum.reduce(1..8, view, fn i, view ->
        SessionView.append_command_turn(view, "cmd-#{i}", "out-#{i}")
      end)

    assert Yelixer.Types.XMLElement.child_count(view.doc, view.scrollback_name) == 8

    turn_ns =
      Yelixer.Types.XMLElement.children(view.doc, view.scrollback_name)
      |> Enum.map(fn {:element, "turn", turn_name} ->
        view.doc
        |> Yelixer.Types.XMLElement.get_attribute(turn_name, "n")
        |> String.to_integer()
      end)

    assert turn_ns == Enum.to_list(1..8)
  end

  # --- Increment 2: live <room> + ambient coalescing buffer ---

  @room %{
    name: "The Orrery Hall",
    desc: "A vaulted hall of brass gears turning overhead.",
    exits: "north, down",
    contents: "a brass orrery",
    occupants: "Grunk"
  }

  test "region-isolation (a): a room-replace's delta does NOT grow with scrollback length", %{
    store: store
  } do
    # Large scrollback, THEN replace_room — capture that replace's delta.
    big = SessionView.new("sess-room-big", store)

    big =
      Enum.reduce(1..30, big, fn i, view ->
        SessionView.append_command_turn(view, "cmd-#{i}", "out-#{i}")
      end)

    big_sv = Yelixer.BlockStore.state_vector(big.doc.store)
    big = SessionView.replace_room(big, @room)
    big_delta = byte_size(Encoding.encode_diff(big.doc, big_sv))

    # Fresh (empty scrollback) view — same replace_room.
    fresh = SessionView.new("sess-room-fresh", store)
    fresh_sv = Yelixer.BlockStore.state_vector(fresh.doc.store)
    fresh = SessionView.replace_room(fresh, @room)
    fresh_delta = byte_size(Encoding.encode_diff(fresh.doc, fresh_sv))

    assert big_delta <= fresh_delta * 2,
           "a room-replace's delta (#{big_delta}b after 30 turns) should stay within ~2x " <>
             "the fresh replace (#{fresh_delta}b) — room-updates must NOT be O(scrollback length)"
  end

  test "region-isolation (b): a scrollback append's delta does NOT include live room content", %{
    store: store
  } do
    # Baseline: append with an EMPTY room.
    empty_room = SessionView.new("sess-append-emptyroom", store)
    base_sv = Yelixer.BlockStore.state_vector(empty_room.doc.store)
    empty_room = SessionView.append_command_turn(empty_room, "spin orrery", "You spin the orrery.")
    baseline_delta = byte_size(Encoding.encode_diff(empty_room.doc, base_sv))

    # Live room, then append — the append delta must not carry room ops.
    live = SessionView.new("sess-append-liveroom", store)
    live = SessionView.replace_room(live, @room)
    assert Yelixer.Types.XMLElement.child_count(live.doc, live.room_name) == 5

    live_sv = Yelixer.BlockStore.state_vector(live.doc.store)
    live = SessionView.append_command_turn(live, "spin orrery", "You spin the orrery.")
    live_delta = byte_size(Encoding.encode_diff(live.doc, live_sv))

    assert live_delta <= baseline_delta * 2,
           "a scrollback append's delta (#{live_delta}b with a live room) should stay within ~2x " <>
             "the empty-room baseline (#{baseline_delta}b) — the append must not include room content"
  end

  test "replace_room does NOT advance the turn counter n", %{store: store} do
    view = SessionView.new("sess-room-n", store)
    view = SessionView.append_command_turn(view, "look", "ok")
    n_before = view.n
    view = SessionView.replace_room(view, @room)
    assert view.n == n_before, "a room-replace must not renumber turns"

    # A subsequent turn still numbers from where the scrollback left off.
    view = SessionView.append_command_turn(view, "wait", "time passes")

    [_, {:element, "turn", turn_name}] =
      Yelixer.Types.XMLElement.children(view.doc, view.scrollback_name)

    assert Yelixer.Types.XMLElement.get_attribute(view.doc, turn_name, "n") == to_string(n_before)
  end

  # --- Increment 2: STRUCTURED room-pane (design §1 nested schema) ---

  @structured_room %{
    name: "The Forge",
    desc: "Heat shimmers off the anvil.",
    exits: [{"north", "The Hall"}, {"down", "The Cellar"}],
    contents: ["an anvil", "a glowing ingot"],
    occupants: ["Grunk", "Ember"]
  }

  test "replace_room with STRUCTURED sections builds nested <exit>/<item>/<who> children", %{
    store: store
  } do
    alias Yelixer.Types.XMLElement

    view = SessionView.new("sess-structured", store)
    view = SessionView.replace_room(view, @structured_room)

    # Still exactly the 5 section containers.
    assert XMLElement.child_count(view.doc, view.room_name) == 5
    children = XMLElement.children(view.doc, view.room_name)

    # <exits> holds two <exit dir=.. to=../>.
    {:element, "exits", exits_name} = Enum.find(children, &match?({:element, "exits", _}, &1))
    exits = XMLElement.children(view.doc, exits_name)
    assert length(exits) == 2
    {:element, "exit", ex1} = hd(exits)
    assert XMLElement.get_attribute(view.doc, ex1, "dir") == "north"
    assert XMLElement.get_attribute(view.doc, ex1, "to") == "The Hall"

    # <contents> holds two <item> text elements.
    {:element, "contents", contents_name} =
      Enum.find(children, &match?({:element, "contents", _}, &1))

    items = XMLElement.children(view.doc, contents_name) |> Enum.map(&text_of(view.doc, &1))
    assert items == ["an anvil", "a glowing ingot"]

    # <occupants> holds two <who> text elements.
    {:element, "occupants", occ_name} = Enum.find(children, &match?({:element, "occupants", _}, &1))
    whos = XMLElement.children(view.doc, occ_name) |> Enum.map(&text_of(view.doc, &1))
    assert whos == ["Grunk", "Ember"]

    # Replay fidelity: the nested pane survives a load round-trip.
    {:ok, loaded} = SessionView.load(view.uuid, store)
    html = SessionView.to_html(loaded)
    assert html =~ "an anvil"
    assert html =~ "Grunk"
    assert html =~ "exit"
  end

  test "region-isolation with a STRUCTURED room: a nested room-replace's delta stays flat as scrollback grows",
       %{store: store} do
    big = SessionView.new("sess-structured-big", store)

    big =
      Enum.reduce(1..30, big, fn i, view ->
        SessionView.append_command_turn(view, "cmd-#{i}", "out-#{i}")
      end)

    big_sv = Yelixer.BlockStore.state_vector(big.doc.store)
    big = SessionView.replace_room(big, @structured_room)
    big_delta = byte_size(Encoding.encode_diff(big.doc, big_sv))

    fresh = SessionView.new("sess-structured-fresh", store)
    fresh_sv = Yelixer.BlockStore.state_vector(fresh.doc.store)
    fresh = SessionView.replace_room(fresh, @structured_room)
    fresh_delta = byte_size(Encoding.encode_diff(fresh.doc, fresh_sv))

    assert big_delta <= fresh_delta * 2,
           "a STRUCTURED room-replace's delta (#{big_delta}b after 30 turns) must stay within ~2x " <>
             "the fresh replace (#{fresh_delta}b) — the nested pane is still O(1) in scrollback length"
  end

  test "ambient buffer: M adds → ONE flush → ONE commit with M lines in order", %{store: store} do
    view = SessionView.new("sess-ambient", store)

    before_count = length(CommitStore.commit_log(store, view.uuid, limit: 10_000))

    buffer = SessionView.buffer_new()
    lines = ["Grunk says: hello", "Grunk waves.", "A bell tolls.", "The wind rises."]
    buffer = Enum.reduce(lines, buffer, fn line, buf -> SessionView.buffer_add(buf, line) end)

    # buffer_add committed nothing.
    assert length(CommitStore.commit_log(store, view.uuid, limit: 10_000)) == before_count

    {view, buffer} = SessionView.buffer_flush(view, buffer)

    after_count = length(CommitStore.commit_log(store, view.uuid, limit: 10_000))
    assert after_count == before_count + 1, "M ambient events must coalesce into exactly ONE commit"

    # The flushed turn carries all 4 <line> children in order.
    {:element, "turn", turn_name} =
      Yelixer.Types.XMLElement.children(view.doc, view.scrollback_name) |> List.last()

    line_texts =
      Yelixer.Types.XMLElement.children(view.doc, turn_name)
      |> Enum.map(fn {:element, "line", line_name} ->
        [{:text, text_name}] = Yelixer.Types.XMLElement.children(view.doc, line_name)
        Yelixer.Types.XMLText.to_string(view.doc, text_name)
      end)

    assert line_texts == lines

    # Flushing an EMPTY buffer commits nothing and returns unchanged.
    count_before_empty = length(CommitStore.commit_log(store, view.uuid, limit: 10_000))
    {^view, ^buffer} = SessionView.buffer_flush(view, buffer)
    assert length(CommitStore.commit_log(store, view.uuid, limit: 10_000)) == count_before_empty
  end

  test "every commit in the chain is node-signed (not just the latest)", %{
    store: store,
    node_identity: node_identity
  } do
    view = SessionView.new("sess-allsigned", store)
    view = SessionView.append_command_turn(view, "look", "You see a hall.")
    view = SessionView.replace_room(view, @room)
    view = SessionView.append_ambient_turn(view, ["Grunk waves."])

    {buffer, view} = {SessionView.buffer_new(), view}
    buffer = SessionView.buffer_add(buffer, "A bell tolls.")
    buffer = SessionView.buffer_add(buffer, "The wind rises.")
    {view, _buffer} = SessionView.buffer_flush(view, buffer)

    log = CommitStore.commit_log(store, view.uuid, limit: 10_000)

    # The chain's synthetic root is the deterministic-genesis stamp
    # (CX-m3x): `create_commit(parent_id: nil)` materializes an unsigned
    # `parent_id: nil` row and chains our (signed) `new/3` commit onto
    # it. That stamp "stays as-is" (infrastructure, not one of our
    # writes); every REAL commit we author — new/3 + every chained
    # append/replace — must be node-signed.
    real_commits = Enum.reject(log, fn c -> is_nil(c.parent_id) end)
    assert length(real_commits) >= 5

    for commit <- real_commits do
      assert {:ok, ^node_identity, _fp} = Signing.parse_signer_id(commit.signer_id),
             "commit #{inspect(commit.id)} is not node-signed"
    end
  end

  test "replace_room round-trip: to_html carries room + scrollback, and load/2 replays faithfully",
       %{store: store} do
    view = SessionView.new("sess-room-roundtrip", store)
    view = SessionView.append_command_turn(view, "spin orrery", "You spin the orrery slowly.")
    view = SessionView.replace_room(view, @room)
    view = SessionView.append_ambient_turn(view, ["Grunk says: hello"])

    html = SessionView.to_html(view)

    # Room section texts present...
    assert html =~ "The Orrery Hall"
    assert html =~ "A vaulted hall of brass gears turning overhead."
    assert html =~ "north, down"
    assert html =~ "a brass orrery"
    assert html =~ ~s(<occupants>Grunk</occupants>)
    # ...alongside the scrollback.
    assert html =~ "spin orrery"
    assert html =~ "You spin the orrery slowly."
    assert html =~ "Grunk says: hello"

    {:ok, loaded} = SessionView.load(view.uuid, store)
    assert SessionView.to_html(loaded) == html
  end

  defp text_of(doc, {:element, _tag, elem_name}) do
    case Yelixer.Types.XMLElement.children(doc, elem_name) do
      [{:text, text_name}] -> Yelixer.Types.XMLText.to_string(doc, text_name)
      _ -> ""
    end
  end
end
