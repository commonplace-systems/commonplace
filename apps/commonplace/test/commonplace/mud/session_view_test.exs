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
      if is_nil(old_data_dir) do
        Application.delete_env(:commonplace, :data_dir)
      else
        Application.put_env(:commonplace, :data_dir, old_data_dir)
      end

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
end
