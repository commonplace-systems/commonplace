defmodule Mix.Tasks.Bots.Tail do
  @shortdoc "Tail bot activity from the running demo BEAM"

  @moduledoc """
  Tail the running bot demo's `__bot_activity` log(s) live.

  Connects to a long-running serve node (default
  `botdemo@localhost`, shared cookie
  `commonplace-bots-demo` — same defaults as `bin/bot-demo-{post,read}`),
  prints the recent activity log for each registered room, then
  polls every second for new entries and prints them as they
  arrive.

  ## Usage

      mix bots.tail                 # all registered rooms, last 20 entries
      mix bots.tail --room demo     # single room
      mix bots.tail --history 50    # last 50 entries before tail starts
      mix bots.tail --interval 500  # poll every 500ms (default 1000)
      mix bots.tail --once          # print history + exit (no follow)

  Output format:

      [<ts>] <room>/<bot> <decision> [<reason>]

  Decisions: `fired`, `suppressed`, `completed`, `cap_hit`, `error`
  (the last three shipped in CX-gptu).

  Ctrl-C to exit.

  ## Requires

  A running BEAM started with:

      ANTHROPIC_API_KEY=... \\
        iex --sname botdemo@localhost --cookie commonplace-bots-demo -S mix

  AND `Commonplace.Bots.DemoSession.start(<root>)` already
  invoked in that session (registers the room with the dispatcher
  + mints the activity doc).
  """

  use Mix.Task

  @default_node :botdemo@localhost
  @default_cookie :"commonplace-bots-demo"
  @default_history 20
  @default_interval_ms 1_000

  @impl true
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        switches: [
          room: :string,
          history: :integer,
          interval: :integer,
          once: :boolean,
          node: :string,
          cookie: :string
        ]
      )

    node_name = opts[:node] |> to_node(@default_node)
    cookie = opts[:cookie] |> to_cookie(@default_cookie)
    history = opts[:history] || @default_history
    interval = opts[:interval] || @default_interval_ms
    once? = opts[:once] || false
    room_filter = opts[:room]

    ensure_distributed!()
    Node.set_cookie(node_name, cookie)

    unless Node.connect(node_name) do
      Mix.shell().error(
        "failed to connect to #{inspect(node_name)} — is the demo BEAM running with --sname #{node_name} --cookie #{cookie}?"
      )

      exit({:shutdown, 1})
    end

    rooms = fetch_rooms!(node_name, room_filter)

    if rooms == %{} do
      Mix.shell().error("no rooms registered on #{inspect(node_name)}.")
      exit({:shutdown, 0})
    end

    initial =
      rooms
      |> Enum.flat_map(fn {room, info} -> fetch_entries(node_name, room, info) end)
      |> Enum.sort_by(& &1.ts)

    {to_print, seen} = trim_history(initial, history)
    Enum.each(to_print, &print/1)

    if once? do
      :ok
    else
      follow_loop(node_name, rooms, seen, interval)
    end
  end

  defp to_node(nil, default), do: default
  defp to_node(str, _), do: String.to_atom(str)
  defp to_cookie(nil, default), do: default
  defp to_cookie(str, _), do: String.to_atom(str)

  defp ensure_distributed! do
    case Node.alive?() do
      true ->
        :ok

      false ->
        # Pick a unique short name for this client invocation.
        sname = :"bots_tail_#{:os.getpid()}_#{:erlang.unique_integer([:positive])}@localhost"

        case Node.start(sname, :shortnames) do
          {:ok, _} ->
            :ok

          {:error, reason} ->
            Mix.shell().error("failed to start distributed Erlang: #{inspect(reason)}")
            exit({:shutdown, 1})
        end
    end
  end

  defp fetch_rooms!(node_name, filter) do
    case :rpc.call(node_name, Commonplace.Bots.Dispatcher, :registered_rooms, [], 5_000) do
      {:badrpc, reason} ->
        Mix.shell().error("rpc failed: #{inspect(reason)}")
        exit({:shutdown, 2})

      rooms when is_map(rooms) ->
        case filter do
          nil -> rooms
          name -> Map.take(rooms, [name])
        end
    end
  end

  defp fetch_entries(node_name, room, %{activity_uuid: uuid}) when is_binary(uuid) do
    case :rpc.call(
           node_name,
           Commonplace.Bots.Activity,
           :list,
           [uuid, Commonplace.Store.CommitStoreClient],
           5_000
         ) do
      list when is_list(list) ->
        Enum.map(list, &normalize_entry(&1, room))

      _ ->
        []
    end
  end

  defp fetch_entries(_node_name, _room, _info), do: []

  defp normalize_entry(raw, room) do
    %{
      ts: Map.get(raw, "ts", ""),
      room: Map.get(raw, "room", room),
      bot: Map.get(raw, "bot", "-"),
      decision: Map.get(raw, "decision", "?"),
      reason: Map.get(raw, "reason"),
      message_id: Map.get(raw, "message_id"),
      raw: raw
    }
  end

  defp trim_history(entries, limit) do
    take = Enum.take(entries, -limit)
    seen = MapSet.new(entries, &seen_key/1)
    {take, seen}
  end

  defp seen_key(%{ts: ts, room: room, bot: bot, decision: d, message_id: mid}) do
    {ts, room, bot, d, mid}
  end

  defp follow_loop(node_name, rooms, seen, interval) do
    Process.sleep(interval)

    all =
      rooms
      |> Enum.flat_map(fn {room, info} -> fetch_entries(node_name, room, info) end)
      |> Enum.sort_by(& &1.ts)

    {new, updated_seen} =
      Enum.reduce(all, {[], seen}, fn entry, {acc_new, acc_seen} ->
        key = seen_key(entry)

        if MapSet.member?(acc_seen, key) do
          {acc_new, acc_seen}
        else
          {[entry | acc_new], MapSet.put(acc_seen, key)}
        end
      end)

    new
    |> Enum.reverse()
    |> Enum.each(&print/1)

    follow_loop(node_name, rooms, updated_seen, interval)
  end

  defp print(%{ts: ts, room: room, bot: bot, decision: decision, reason: reason}) do
    reason_str = if reason, do: " [#{reason}]", else: ""
    IO.puts("[#{ts}] #{room}/#{bot} #{decision}#{reason_str}")
  end
end
