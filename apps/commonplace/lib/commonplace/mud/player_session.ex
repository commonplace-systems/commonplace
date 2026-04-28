defmodule Commonplace.MUD.PlayerSession do
  @moduledoc """
  Per-player session GenServer for the MUD.

  Owns subscriptions, parses commands, dispatches to verbs, renders
  events. v0 design: runs in the CLI's local BEAM. Phoenix PubSub
  broadcasts cross the cluster automatically via pg, so two sessions on
  two different CLI nodes still see each other's room events.

  Player input arrives via `cast({:input, line})`. Output goes through
  an `output_fn :: (text -> :ok)` set at start_link time (defaults to
  IO.puts). The session terminates on `quit` or when its caller exits.
  """

  use GenServer
  require Logger

  alias Commonplace.MUD.{Parser, Schemas, Topics, Verbs, VerbSource}
  alias Commonplace.MUD.Schemas.{Player, Room}
  alias Commonplace.Presence
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.{DocBuilder, Schema}
  alias Yelixer.Encoding

  @start_room_name "start"
  @players_dir "players"

  defstruct [
    :player_name,
    :player_uuid,
    :player_dir_uuid,
    :inventory_uuid,
    :current_room_uuid,
    :presence_filename,
    :root_uuid,
    :store,
    :output_fn,
    :owner_pid,
    mode: :normal,
    buffer: nil
  ]

  ## Client

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, [])
  end

  def input(pid, line), do: GenServer.cast(pid, {:input, line})

  @doc "Synchronously deliver input and wait for the verb to finish processing."
  def input_sync(pid, line), do: GenServer.call(pid, {:input, line}, 10_000)

  @doc "Drain and clear the buffered output (only valid for buffered sessions)."
  def drain_buffer(pid), do: GenServer.call(pid, :drain_buffer, 5_000)

  def stop(pid), do: GenServer.stop(pid, :normal)

  ## Server

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :player_name)
    root_uuid = Keyword.fetch!(opts, :root_uuid)
    store = Keyword.get(opts, :store, CommitStoreClient)
    buffered? = Keyword.get(opts, :buffered, false)

    output_fn =
      cond do
        buffered? ->
          self_pid = self()
          fn line -> GenServer.cast(self_pid, {:buffer_append, line}) end

        true ->
          Keyword.get(opts, :output_fn, &IO.puts/1)
      end

    owner_pid = Keyword.get(opts, :owner_pid)

    case bootstrap_player(name, root_uuid, store) do
      {:ok, ids} ->
        state = %__MODULE__{
          player_name: name,
          player_uuid: ids.presence_uuid,
          player_dir_uuid: ids.player_dir_uuid,
          inventory_uuid: ids.inventory_uuid,
          current_room_uuid: ids.room_uuid,
          presence_filename: Presence.filename(name, :usr),
          root_uuid: root_uuid,
          store: store,
          output_fn: output_fn,
          owner_pid: owner_pid,
          buffer: if(buffered?, do: [], else: nil)
        }

        Topics.subscribe_room(state.current_room_uuid)
        Topics.subscribe_player_tell(state.player_uuid)

        send(self(), :greet)
        {:ok, state}

      {:error, reason} ->
        {:stop, {:bootstrap_failed, reason}}
    end
  end

  @impl true
  def handle_cast({:input, line}, state) do
    process_input(line, state)
  end

  def handle_cast({:buffer_append, line}, state) when is_list(state.buffer) do
    {:noreply, %{state | buffer: state.buffer ++ [line]}}
  end

  def handle_cast({:buffer_append, _line}, state), do: {:noreply, state}

  @impl true
  def handle_call(:drain_buffer, _from, state) do
    {:reply, state.buffer || [], %{state | buffer: if(is_list(state.buffer), do: [], else: nil)}}
  end

  def handle_call({:input, line}, _from, state) do
    case process_input(line, state) do
      {:noreply, new_state} -> {:reply, :ok, new_state}
      {:stop, reason, new_state} -> {:stop, reason, :ok, new_state}
    end
  end

  defp process_input(line, %__MODULE__{mode: :normal} = state) do
    cmd = Parser.parse(line)

    if cmd.verb == "" do
      {:noreply, state}
    else
      ctx = build_ctx(state, cmd)
      result = Verbs.dispatch(cmd, ctx)
      handle_verb_result(result, state)
    end
  end

  defp process_input(line, %__MODULE__{mode: {:editor, ed}} = state) do
    case String.trim(line) do
      "." ->
        save_verb(ed, state)

      "@abort" ->
        state.output_fn.("(aborted, no changes saved)")
        {:noreply, %{state | mode: :normal}}

      _ ->
        new_lines = ed.lines ++ [line]
        {:noreply, %{state | mode: {:editor, %{ed | lines: new_lines}}}}
    end
  end

  defp save_verb(ed, state) do
    source_text = Enum.join(ed.lines, "\n")

    case VerbSource.save_verb(ed.target_uuid, ed.verb_name, source_text, state.store) do
      :ok ->
        state.output_fn.("(saved #{ed.target_label}:#{ed.verb_name} — compiles cleanly)")
        {:noreply, %{state | mode: :normal}}

      {:error, {:compile_error, msg}} ->
        state.output_fn.("(saved with compile error: #{msg})")
        {:noreply, %{state | mode: :normal}}

      {:error, {:no_run_export, _}} ->
        state.output_fn.("(saved, but the module does not export run/1 — verb won't fire)")
        {:noreply, %{state | mode: :normal}}

      {:error, other} ->
        state.output_fn.("(save failed: #{inspect(other)})")
        {:noreply, %{state | mode: :normal}}
    end
  end

  @impl true
  def handle_info(:greet, state) do
    state.output_fn.("Welcome, #{state.player_name}.\n")
    render_room(state)
    {:noreply, state}
  end

  def handle_info({"red:" <> _ = _topic, payload}, state) do
    render_event(payload, state)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  ## Verb result handling

  defp handle_verb_result(:ok, state), do: {:noreply, state}

  defp handle_verb_result(:unhandled, state) do
    state.output_fn.("I don't understand that.")
    {:noreply, state}
  end

  defp handle_verb_result({:reply, :quit}, state) do
    state.output_fn.("Goodbye.")
    if pid = state.owner_pid, do: send(pid, {:player_session_quit, self()})
    {:stop, :normal, state}
  end

  defp handle_verb_result({:reply, text}, state) when is_binary(text) do
    state.output_fn.(text)
    {:noreply, state}
  end

  defp handle_verb_result({:error, msg}, state) do
    state.output_fn.(msg)
    {:noreply, state}
  end

  defp handle_verb_result({:moved, dest_uuid}, state) do
    Topics.unsubscribe_room(state.current_room_uuid)
    Topics.subscribe_room(dest_uuid)
    new_state = %{state | current_room_uuid: dest_uuid}
    render_room(new_state)
    {:noreply, new_state}
  end

  defp handle_verb_result({:enter_editor, %{} = ed}, state) do
    state.output_fn.("=== editing #{ed.target_label}:#{ed.verb_name} ===")

    if ed.current != "" do
      state.output_fn.("(current source — type new lines to replace; '.' to save, '@abort' to cancel)")
      state.output_fn.(ed.current)
    else
      state.output_fn.(
        "(new verb — type lines, '.' to save, '@abort' to cancel)\n" <>
          "verb body shape:\n" <>
          "  defmodule UserVerb do\n" <>
          "    alias Commonplace.MUD.Output\n" <>
          "    def run(ctx) do\n" <>
          "      Output.tell(ctx, \"You feel something happen.\")\n" <>
          "      Output.broadcast(ctx, \"\#{ctx.player_name} does something.\")\n" <>
          "      :ok\n" <>
          "    end\n" <>
          "  end"
      )
    end

    {:noreply, %{state | mode: {:editor, Map.put(ed, :lines, [])}}}
  end

  ## Rendering

  defp build_ctx(state, cmd) do
    %{
      player_name: state.player_name,
      player_uuid: state.player_uuid,
      player_dir_uuid: state.player_dir_uuid,
      inventory_uuid: state.inventory_uuid,
      current_room_uuid: state.current_room_uuid,
      presence_filename: state.presence_filename,
      root_uuid: state.root_uuid,
      store: state.store,
      cmd: cmd
    }
  end

  defp render_room(state) do
    ctx = build_ctx(state, %Parser.Command{})

    case Verbs.dispatch(%Parser.Command{verb: "look"}, ctx) do
      {:reply, text} -> state.output_fn.(text)
      _ -> :ok
    end
  end

  defp render_event(%{except: except} = payload, state) do
    if state.player_uuid in except do
      :ok
    else
      render_event(Map.delete(payload, :except), state)
    end
  end

  defp render_event(%{kind: :say, who: who, text: text}, state) do
    if who != state.player_name do
      state.output_fn.("#{who} says, \"#{text}\"")
    else
      state.output_fn.("You say, \"#{text}\"")
    end
  end

  defp render_event(%{kind: :emote, who: who, text: text}, state) do
    own = who == state.player_name
    prefix = if own, do: "You", else: who
    state.output_fn.("#{prefix} #{text}")
  end

  defp render_event(%{kind: :arrive, who: who, from: from}, state) do
    if who != state.player_name do
      state.output_fn.("#{who} arrives from the #{from}.")
    end
  end

  defp render_event(%{kind: :depart, who: who, to: to}, state) do
    if who != state.player_name do
      state.output_fn.("#{who} leaves to the #{to}.")
    end
  end

  defp render_event(%{kind: :take, who: who, what: what}, state) do
    if who != state.player_name do
      state.output_fn.("#{who} takes #{what}.")
    end
  end

  defp render_event(%{kind: :drop, who: who, what: what}, state) do
    if who != state.player_name do
      state.output_fn.("#{who} drops #{what}.")
    end
  end

  defp render_event(%{kind: :give, who: who, what: what, to: to}, state) do
    cond do
      who == state.player_name -> :ok
      to == state.player_name -> state.output_fn.("#{who} gives you #{what}.")
      true -> state.output_fn.("#{who} gives #{what} to #{to}.")
    end
  end

  defp render_event(%{kind: :verb_error, verb: verb, reason: reason}, state) do
    state.output_fn.("(verb #{verb} crashed: #{reason})")
  end

  defp render_event(%{kind: :custom, text: text}, state) do
    state.output_fn.(text)
  end

  defp render_event(other, state) do
    state.output_fn.("(event: #{inspect(other)})")
  end

  ## Bootstrap player

  defp bootstrap_player(name, root_uuid, store) do
    with {:ok, players_dir_uuid} <- ensure_players_dir(root_uuid, store),
         {:ok, %{player_dir_uuid: pdir, inventory_uuid: inv}} <-
           ensure_player_dir(name, players_dir_uuid, store),
         {:ok, room_uuid, presence_uuid} <- ensure_player_in_world(name, root_uuid, store) do
      {:ok,
       %{
         player_dir_uuid: pdir,
         inventory_uuid: inv,
         room_uuid: room_uuid,
         presence_uuid: presence_uuid
       }}
    end
  end

  defp ensure_players_dir(root_uuid, store) do
    {:ok, root_schema} = Schemas.load_dir_schema(root_uuid, store)

    case Schema.get_entry(root_schema, @players_dir) do
      {:ok, entry} ->
        {:ok, entry.node_id}

      :error ->
        new_uuid = Schemas.create_dir_with_meta(nil, nil, store)
        :ok = add_dir_entry(root_uuid, @players_dir, new_uuid, store)
        {:ok, new_uuid}
    end
  end

  defp ensure_player_dir(name, players_dir_uuid, store) do
    {:ok, players_schema} = Schemas.load_dir_schema(players_dir_uuid, store)

    case Schema.get_entry(players_schema, name) do
      {:ok, entry} ->
        {:ok, schema} = Schemas.load_dir_schema(entry.node_id, store)

        inv_uuid =
          case Schema.get_entry(schema, "inventory") do
            {:ok, e} ->
              e.node_id

            :error ->
              new_uuid = Schemas.create_dir_with_meta(nil, nil, store)
              :ok = add_dir_entry(entry.node_id, "inventory", new_uuid, store)
              new_uuid
          end

        {:ok, %{player_dir_uuid: entry.node_id, inventory_uuid: inv_uuid}}

      :error ->
        json = Schemas.encode_player(%Player{name: name, title: name, description: "A traveler."})
        player_dir_uuid = Schemas.create_dir_with_meta(Schemas.player_filename(), json, store)
        inv_uuid = Schemas.create_dir_with_meta(nil, nil, store)
        :ok = add_dir_entry(player_dir_uuid, "inventory", inv_uuid, store)
        :ok = add_dir_entry(players_dir_uuid, name, player_dir_uuid, store)
        {:ok, %{player_dir_uuid: player_dir_uuid, inventory_uuid: inv_uuid}}
    end
  end

  defp ensure_player_in_world(name, root_uuid, store) do
    presence_filename = Presence.filename(name, :usr)

    case find_presence(root_uuid, presence_filename, store) do
      {:ok, room_uuid, presence_uuid} ->
        {:ok, room_uuid, presence_uuid}

      :not_found ->
        {:ok, start_room_uuid} = ensure_start_room(root_uuid, store)
        {:ok, presence_uuid} = Presence.create(name, :usr, start_room_uuid, store)
        {:ok, start_room_uuid, presence_uuid}
    end
  end

  defp find_presence(root_uuid, filename, store) do
    walk_for_presence(root_uuid, filename, store, MapSet.new())
  end

  defp walk_for_presence(uuid, filename, store, seen) do
    if MapSet.member?(seen, uuid) do
      :not_found
    else
      seen = MapSet.put(seen, uuid)

      case Schemas.load_dir_schema(uuid, store) do
        {:ok, schema} ->
          entries = Schema.list_entries(schema)

          case Enum.find(entries, fn e -> e.name == filename end) do
            %Schema.Entry{node_id: presence_uuid} ->
              {:ok, uuid, presence_uuid}

            nil ->
              entries
              |> Enum.filter(&(&1.type == :dir))
              |> Enum.find_value(:not_found, fn entry ->
                case walk_for_presence(entry.node_id, filename, store, seen) do
                  :not_found -> nil
                  result -> result
                end
              end)
          end

        _ ->
          :not_found
      end
    end
  end

  defp ensure_start_room(root_uuid, store) do
    {:ok, root_schema} = Schemas.load_dir_schema(root_uuid, store)

    case Schema.get_entry(root_schema, @start_room_name) do
      {:ok, entry} ->
        {:ok, entry.node_id}

      :error ->
        json = Schemas.encode_room(%Room{name: "The Start Room", description: "A featureless white room. The world has not been built out yet.", exits: %{}})
        room_uuid = Schemas.create_dir_with_meta(Schemas.room_filename(), json, store)
        :ok = add_dir_entry(root_uuid, @start_room_name, room_uuid, store)
        {:ok, room_uuid}
    end
  end

  defp add_dir_entry(parent_uuid, name, child_uuid, store) do
    {:ok, schema} = Schemas.load_dir_schema(parent_uuid, store)
    schema = Schema.add_directory(schema, name, child_uuid)
    update = Encoding.encode_update(schema)
    CommitStoreClient.create_chained_commit(store, parent_uuid, update)
    :ok
  end

  # silence unused alias warning when DocBuilder isn't referenced
  _ = DocBuilder
end
