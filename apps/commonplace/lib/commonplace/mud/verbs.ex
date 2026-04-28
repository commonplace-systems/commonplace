defmodule Commonplace.MUD.Verbs do
  @moduledoc """
  Built-in verbs for MUD v0.

  Verbs receive a `ctx` map (see `Commonplace.MUD.PlayerSession` for the
  shape) and return one of:

    * `:ok` — verb completed, no state change
    * `{:moved, new_room_uuid}` — player moved rooms; session updates
    * `{:reply, text}` — print text to the player's local stdout
    * `{:error, reason_text}` — show error to the player
    * `:unhandled` — verb name unknown to this module

  The session is responsible for interpreting move outcomes and updating
  its in-memory state + Phoenix PubSub subscriptions. All world-visible
  side effects go through `Commonplace.MUD.World`.
  """

  alias Commonplace.MUD.{Parser, Schemas, VerbSource, World}
  alias Commonplace.MUD.Schemas.{Object, Player, Room}
  alias Commonplace.Tree.Schema
  alias Commonplace.Store.CommitStoreClient

  @builders ~w(@dig @create @desc @name @listen @dump @verb)

  @doc "Dispatch a parsed command. Returns one of the verb-result tuples."
  def dispatch(%Parser.Command{verb: ""}, _ctx), do: :ok

  def dispatch(%Parser.Command{verb: verb} = cmd, ctx) do
    cond do
      verb in @builders ->
        dispatch_builder(verb, cmd, ctx)

      true ->
        case dispatch_user_verb(verb, cmd, ctx) do
          :unhandled -> dispatch_builtin(verb, cmd, ctx)
          other -> other
        end
    end
  end

  # ---- User-authored verbs (P3) ----

  defp dispatch_user_verb(verb_name, _cmd, ctx) do
    case find_verb_in_scope(verb_name, ctx) do
      {:ok, host_kind, host_uuid, host_name} ->
        run_user_verb(host_kind, host_uuid, host_name, verb_name, ctx)

      :not_found ->
        :unhandled
    end
  end

  defp find_verb_in_scope(verb_name, ctx) do
    inventory_objects = World.list_objects_in(ctx.inventory_uuid, ctx.store)
    room_objects = World.list_objects_in(ctx.current_room_uuid, ctx.store)

    candidates =
      Enum.map(inventory_objects, &{:object, &1.node_id, &1.name}) ++
        Enum.map(room_objects, &{:object, &1.node_id, &1.name}) ++
        [{:room, ctx.current_room_uuid, "here"}]

    Enum.find_value(candidates, :not_found, fn {kind, uuid, name} ->
      case VerbSource.find_source(uuid, verb_name, ctx.store) do
        {:ok, _} -> {:ok, kind, uuid, name}
        _ -> nil
      end
    end)
  end

  defp run_user_verb(host_kind, host_uuid, host_name, verb_name, ctx) do
    verb_ctx = build_user_verb_ctx(host_kind, host_uuid, host_name, ctx)

    case VerbSource.run_verb(host_uuid, verb_name, verb_ctx, ctx.store) do
      {:ok, _} ->
        :ok

      {:error, {:compile_error, msg}} ->
        emit_verb_error(verb_name, "compile error: #{msg}", ctx)
        {:error, "(verb #{verb_name} failed to compile)"}

      {:error, {:runtime_error, msg}} ->
        emit_verb_error(verb_name, msg, ctx)
        {:error, "(verb #{verb_name} crashed: #{msg})"}

      {:error, {:no_run_export, _}} ->
        {:error, "(verb #{verb_name} has no run/1)"}

      :not_found ->
        :unhandled

      _ ->
        :unhandled
    end
  end

  defp build_user_verb_ctx(:object, host_uuid, _host_name, ctx) do
    object =
      case Schemas.load_object(host_uuid, ctx.store) do
        {:ok, obj} -> obj
        _ -> nil
      end

    Map.merge(ctx, %{object_uuid: host_uuid, object: object})
  end

  defp build_user_verb_ctx(:room, _host_uuid, _host_name, ctx) do
    Map.merge(ctx, %{object_uuid: nil, object: nil})
  end

  defp emit_verb_error(verb_name, reason, ctx) do
    World.broadcast_room(ctx.current_room_uuid, %{
      kind: :verb_error,
      verb: verb_name,
      reason: reason
    })

    World.tell(ctx.player_uuid, %{kind: :verb_error, verb: verb_name, reason: reason})
  end

  # ---- Built-in verbs ----

  defp dispatch_builtin("look", cmd, ctx), do: do_look(cmd, ctx)
  defp dispatch_builtin("say", cmd, ctx), do: do_say(cmd, ctx)
  defp dispatch_builtin("emote", cmd, ctx), do: do_emote(cmd, ctx)
  defp dispatch_builtin("take", cmd, ctx), do: do_take(cmd, ctx)
  defp dispatch_builtin("get", cmd, ctx), do: do_take(cmd, ctx)
  defp dispatch_builtin("drop", cmd, ctx), do: do_drop(cmd, ctx)
  defp dispatch_builtin("give", cmd, ctx), do: do_give(cmd, ctx)
  defp dispatch_builtin("inventory", _cmd, ctx), do: do_inventory(ctx)
  defp dispatch_builtin("who", _cmd, ctx), do: do_who(ctx)
  defp dispatch_builtin("quit", _cmd, _ctx), do: {:reply, :quit}
  defp dispatch_builtin("help", _cmd, _ctx), do: {:reply, help_text()}
  defp dispatch_builtin("go", cmd, ctx), do: do_go(List.first(cmd.argv), ctx)

  defp dispatch_builtin(dir, _cmd, ctx) when dir in ~w(north south east west up down in out) do
    do_go(dir, ctx)
  end

  defp dispatch_builtin(_verb, _cmd, _ctx), do: :unhandled

  # ---- look ----

  defp do_look(%Parser.Command{argv: []}, ctx) do
    {:reply, render_room(ctx)}
  end

  defp do_look(%Parser.Command{target: target}, ctx) do
    case find_in_scope(target, ctx) do
      {:ok, :object, %Object{} = obj} ->
        {:reply, "#{obj.name}\n#{obj.description}"}

      {:ok, :player, %Player{} = pl} ->
        title = if pl.title == "", do: pl.name, else: pl.title
        {:reply, "#{title}\n#{pl.description}"}

      :not_found ->
        {:error, "You don't see \"#{target}\" here."}
    end
  end

  defp render_room(ctx) do
    case World.get_room(ctx.current_room_uuid, ctx.store) do
      {:ok, %Room{} = room} ->
        players = list_other_players(ctx)
        objects = list_room_objects(ctx)
        exits = room.exits |> Map.keys() |> Enum.sort()

        IO.iodata_to_binary([
          "== ", room.name, " ==\n",
          room.description, "\n",
          if(exits == [], do: "Exits: (none)\n", else: ["Exits: ", Enum.join(exits, ", "), "\n"]),
          if(objects == [], do: "", else: ["You see: ", Enum.join(objects, ", "), "\n"]),
          if(players == [], do: "", else: ["Players: ", Enum.join(players, ", "), "\n"])
        ])

      {:error, _} ->
        "(this place has no description)"
    end
  end

  defp list_other_players(ctx) do
    self_name = ctx.presence_filename

    World.list_players_in(ctx.current_room_uuid, ctx.store)
    |> Enum.reject(fn e -> e.name == self_name end)
    |> Enum.map(fn e -> e.name |> String.replace_suffix(".usr", "") end)
  end

  defp list_room_objects(ctx) do
    World.list_objects_in(ctx.current_room_uuid, ctx.store)
    |> Enum.map(fn e ->
      case Schemas.load_object(e.node_id, ctx.store) do
        {:ok, %Object{name: name}} -> name
        _ -> e.name |> String.replace_suffix(".obj", "")
      end
    end)
  end

  # ---- say / emote ----

  defp do_say(%Parser.Command{args: ""}, _ctx), do: {:error, "Say what?"}

  defp do_say(%Parser.Command{args: text}, ctx) do
    World.broadcast_room(ctx.current_room_uuid, %{kind: :say, who: ctx.player_name, text: text})
    :ok
  end

  defp do_emote(%Parser.Command{args: ""}, _ctx), do: {:error, "Emote what?"}

  defp do_emote(%Parser.Command{args: text}, ctx) do
    World.broadcast_room(ctx.current_room_uuid, %{kind: :emote, who: ctx.player_name, text: text})
    :ok
  end

  # ---- take / drop / give ----

  defp do_take(%Parser.Command{target: nil}, _ctx), do: {:error, "Take what?"}

  defp do_take(%Parser.Command{target: target}, ctx) do
    with {:ok, entry} <- World.find_entry_by_name(ctx.current_room_uuid, target, ctx.store),
         true <- takable_entry?(entry) || {:error, "You can't take that."},
         {:ok, %Object{} = obj} <- Schemas.load_object(entry.node_id, ctx.store),
         :ok <- ensure_not_fixed(obj),
         :ok <- World.move(entry.node_id, entry.name, ctx.current_room_uuid, ctx.inventory_uuid) do
      World.broadcast_room(ctx.current_room_uuid, %{
        kind: :take,
        who: ctx.player_name,
        what: obj.name
      })

      {:reply, "You take #{obj.name}."}
    else
      :error -> {:error, "You don't see \"#{target}\" here."}
      {:error, :gone} -> {:error, "Someone else grabbed it first."}
      {:error, :collision} -> {:error, "You're already carrying one of those."}
      {:error, msg} when is_binary(msg) -> {:error, msg}
      _ -> {:error, "You can't take that."}
    end
  end

  defp takable_entry?(%Schema.Entry{type: :dir, name: name}), do: String.ends_with?(name, ".obj")
  defp takable_entry?(_), do: false

  defp ensure_not_fixed(%Object{fixed: true, name: name}), do: {:error, "#{name} is fixed in place."}
  defp ensure_not_fixed(_), do: :ok

  defp do_drop(%Parser.Command{target: nil}, _ctx), do: {:error, "Drop what?"}

  defp do_drop(%Parser.Command{target: target}, ctx) do
    with {:ok, entry} <- World.find_entry_by_name(ctx.inventory_uuid, target, ctx.store),
         {:ok, %Object{} = obj} <- Schemas.load_object(entry.node_id, ctx.store),
         :ok <- World.move(entry.node_id, entry.name, ctx.inventory_uuid, ctx.current_room_uuid) do
      World.broadcast_room(ctx.current_room_uuid, %{
        kind: :drop,
        who: ctx.player_name,
        what: obj.name
      })

      {:reply, "You drop #{obj.name}."}
    else
      :error -> {:error, "You aren't carrying \"#{target}\"."}
      {:error, :collision} -> {:error, "There's already one of those here."}
      {:error, :gone} -> {:error, "It slipped from your grasp."}
      _ -> {:error, "You can't drop that."}
    end
  end

  defp do_give(%Parser.Command{argv: argv}, _ctx) when length(argv) < 2 do
    {:error, "Give what to whom? Try: give <obj> <player>"}
  end

  defp do_give(%Parser.Command{argv: [obj_name, target_name | _]}, ctx) do
    with {:ok, obj_entry} <- World.find_entry_by_name(ctx.inventory_uuid, obj_name, ctx.store),
         {:ok, %Object{} = obj} <- Schemas.load_object(obj_entry.node_id, ctx.store),
         {:ok, target_inv_uuid, target_player_name} <- find_player_inventory(target_name, ctx),
         :ok <- World.move(obj_entry.node_id, obj_entry.name, ctx.inventory_uuid, target_inv_uuid) do
      World.broadcast_room(ctx.current_room_uuid, %{
        kind: :give,
        who: ctx.player_name,
        what: obj.name,
        to: target_player_name
      })

      {:reply, "You give #{obj.name} to #{target_player_name}."}
    else
      :error -> {:error, "You aren't carrying \"#{obj_name}\"."}
      {:error, :no_such_player} -> {:error, "You don't see \"#{target_name}\" here."}
      {:error, :collision} -> {:error, "#{target_name} is already carrying one of those."}
      {:error, :gone} -> {:error, "It slipped from your grasp."}
      _ -> {:error, "You can't give that."}
    end
  end

  defp find_player_inventory(target_name, ctx) do
    needle = String.downcase(target_name)

    presence_entries =
      World.list_players_in(ctx.current_room_uuid, ctx.store)
      |> Enum.filter(fn e ->
        bare = e.name |> String.replace_suffix(".usr", "") |> String.downcase()
        String.contains?(bare, needle) and bare != String.downcase(ctx.player_name)
      end)

    case presence_entries do
      [entry] ->
        bare = entry.name |> String.replace_suffix(".usr", "")
        case lookup_player_inventory(bare, ctx) do
          {:ok, inv_uuid} -> {:ok, inv_uuid, bare}
          err -> err
        end

      [] ->
        {:error, :no_such_player}

      _ ->
        {:error, :no_such_player}
    end
  end

  defp lookup_player_inventory(player_name, ctx) do
    path = "players/#{player_name}/inventory"
    World.resolve_path(path, ctx.root_uuid, ctx.store)
    |> case do
      {:ok, uuid} -> {:ok, uuid}
      _ -> {:error, :no_such_player}
    end
  end

  # ---- inventory / who ----

  defp do_inventory(ctx) do
    items =
      World.list_objects_in(ctx.inventory_uuid, ctx.store)
      |> Enum.map(fn e ->
        case Schemas.load_object(e.node_id, ctx.store) do
          {:ok, %Object{name: name}} -> name
          _ -> e.name
        end
      end)

    text =
      case items do
        [] -> "You are carrying nothing."
        _ -> "You are carrying:\n  - " <> Enum.join(items, "\n  - ")
      end

    {:reply, text}
  end

  defp do_who(ctx) do
    names = walk_collect_players(ctx.root_uuid, ctx.store) |> Enum.sort() |> Enum.uniq()

    text =
      case names do
        [] -> "Nobody is logged in."
        _ -> "Players online:\n  - " <> Enum.join(names, "\n  - ")
      end

    {:reply, text}
  end

  defp walk_collect_players(dir_uuid, store) do
    case Schemas.load_dir_schema(dir_uuid, store) do
      {:ok, schema} ->
        Schema.list_entries(schema)
        |> Enum.flat_map(fn entry ->
          cond do
            String.ends_with?(entry.name, ".usr") ->
              [entry.name |> String.replace_suffix(".usr", "")]

            entry.type == :dir ->
              walk_collect_players(entry.node_id, store)

            true ->
              []
          end
        end)

      _ ->
        []
    end
  end

  # ---- movement ----

  defp do_go(nil, _ctx), do: {:error, "Go where?"}

  defp do_go(direction, ctx) do
    with {:ok, %Room{} = room} <- World.get_room(ctx.current_room_uuid, ctx.store),
         {:ok, dest_uuid} <- Map.fetch(room.exits, direction) |> wrap_fetch(),
         :ok <- World.move(ctx.player_uuid, ctx.presence_filename, ctx.current_room_uuid, dest_uuid) do
      World.broadcast_room(ctx.current_room_uuid, %{
        kind: :depart,
        who: ctx.player_name,
        to: direction
      })

      from_dir = Parser.opposite_direction(direction) || "elsewhere"

      World.broadcast_room(dest_uuid, %{
        kind: :arrive,
        who: ctx.player_name,
        from: from_dir
      })

      {:moved, dest_uuid}
    else
      :error -> {:error, "You can't go #{direction}."}
      {:error, :gone} -> {:error, "The way #{direction} closed behind you."}
      {:error, :collision} -> {:error, "Something blocks the way #{direction}."}
      _ -> {:error, "You can't go #{direction}."}
    end
  end

  defp wrap_fetch({:ok, _} = ok), do: ok
  defp wrap_fetch(:error), do: :error

  # ---- Builder verbs ----

  defp dispatch_builder("@dig", cmd, ctx), do: do_dig(cmd, ctx)
  defp dispatch_builder("@create", cmd, ctx), do: do_create(cmd, ctx)
  defp dispatch_builder("@desc", cmd, ctx), do: do_desc(cmd, ctx)
  defp dispatch_builder("@name", cmd, ctx), do: do_rename(cmd, ctx)
  defp dispatch_builder("@listen", _cmd, ctx), do: {:reply, "Now listening to room #{ctx.current_room_uuid}. (Debug: red events will appear inline.)"}
  defp dispatch_builder("@verb", cmd, ctx), do: do_verb_edit(cmd, ctx)

  defp dispatch_builder("@dump", cmd, ctx) do
    case cmd.target do
      nil ->
        case World.get_room(ctx.current_room_uuid, ctx.store) do
          {:ok, room} -> {:reply, inspect(room, pretty: true)}
          _ -> {:error, "no room"}
        end

      target ->
        case find_in_scope(target, ctx) do
          {:ok, :object, obj} -> {:reply, inspect(obj, pretty: true)}
          {:ok, :player, pl} -> {:reply, inspect(pl, pretty: true)}
          _ -> {:error, "Can't find \"#{target}\"."}
        end
    end
  end

  defp do_verb_edit(%Parser.Command{argv: argv}, _ctx) when length(argv) < 1 do
    {:error, "Try: @verb <target>:<verbname>"}
  end

  defp do_verb_edit(%Parser.Command{argv: [spec | _]}, ctx) do
    case String.split(spec, ":", parts: 2) do
      [target, verb_name] when verb_name != "" ->
        cond do
          target in ["here", "room"] ->
            current = read_current_source(ctx.current_room_uuid, verb_name, ctx)
            {:enter_editor, %{target_uuid: ctx.current_room_uuid, target_label: "here", verb_name: verb_name, current: current}}

          true ->
            case World.find_entry_by_name(ctx.current_room_uuid, target, ctx.store) do
              {:ok, %Schema.Entry{type: :dir, name: name, node_id: uuid}} ->
                if String.ends_with?(name, ".obj") do
                  current = read_current_source(uuid, verb_name, ctx)
                  {:enter_editor, %{target_uuid: uuid, target_label: target, verb_name: verb_name, current: current}}
                else
                  {:error, "Can only edit verbs on objects (or here/room)."}
                end

              _ ->
                case World.find_entry_by_name(ctx.inventory_uuid, target, ctx.store) do
                  {:ok, %Schema.Entry{type: :dir, name: name, node_id: uuid}} ->
                    if String.ends_with?(name, ".obj") do
                      current = read_current_source(uuid, verb_name, ctx)
                      {:enter_editor, %{target_uuid: uuid, target_label: target, verb_name: verb_name, current: current}}
                    else
                      {:error, "Can only edit verbs on objects (or here/room)."}
                    end

                  _ ->
                    {:error, "You don't see \"#{target}\" here or in inventory."}
                end
            end
        end

      _ ->
        {:error, "Try: @verb <target>:<verbname>"}
    end
  end

  defp read_current_source(target_uuid, verb_name, ctx) do
    case VerbSource.read_source(target_uuid, verb_name, ctx.store) do
      {:ok, text} -> text
      _ -> ""
    end
  end

  defp do_dig(%Parser.Command{argv: argv}, _ctx) when length(argv) < 2 do
    {:error, "Try: @dig <direction> <name>"}
  end

  defp do_dig(%Parser.Command{argv: [direction, name | _]}, ctx) do
    direction = String.downcase(direction)
    opposite = Parser.opposite_direction(direction)

    cond do
      not Parser.direction?(direction) ->
        {:error, "Unknown direction: #{direction}"}

      opposite == nil ->
        {:error, "No opposite for #{direction}"}

      true ->
        json = Schemas.encode_room(%Room{name: name, description: "(no description yet)", exits: %{opposite => ctx.current_room_uuid}})
        new_room_uuid = Schemas.create_dir_with_meta(Schemas.room_filename(), json, ctx.store)

        :ok = add_dir_entry(ctx.root_uuid, name, new_room_uuid, ctx.store)
        :ok = update_room_exit(ctx.current_room_uuid, direction, new_room_uuid, ctx.store)

        {:reply, "You carve out a new room (#{name}). #{String.capitalize(direction)} leads there."}
    end
  end

  defp do_create(%Parser.Command{argv: argv}, _ctx) when length(argv) < 2 do
    {:error, "Try: @create <object|room> <name>"}
  end

  defp do_create(%Parser.Command{argv: ["object", name | _]}, ctx) do
    obj_json = Schemas.encode_object(%Object{name: name, description: "(no description yet)"})
    new_obj_uuid = Schemas.create_dir_with_meta(Schemas.object_filename(), obj_json, ctx.store)
    :ok = add_dir_entry(ctx.current_room_uuid, "#{name}.obj", new_obj_uuid, ctx.store)
    {:reply, "You create a #{name}."}
  end

  defp do_create(%Parser.Command{argv: ["room", name | _]}, ctx) do
    json = Schemas.encode_room(%Room{name: name, description: "(no description yet)"})
    new_uuid = Schemas.create_dir_with_meta(Schemas.room_filename(), json, ctx.store)
    :ok = add_dir_entry(ctx.root_uuid, name, new_uuid, ctx.store)
    {:reply, "You create a new disconnected room (#{name})."}
  end

  defp do_create(%Parser.Command{argv: [other | _]}, _ctx) do
    {:error, "Unknown kind: #{other} (try object or room)"}
  end

  defp do_desc(%Parser.Command{argv: argv}, _ctx) when length(argv) < 2, do: {:error, "Try: @desc <target> <text>"}

  defp do_desc(%Parser.Command{argv: [target | _], args: args}, ctx) do
    text = strip_first_word(args)
    update_meta_description(target, text, ctx)
  end

  defp do_rename(%Parser.Command{argv: argv}, _ctx) when length(argv) < 2, do: {:error, "Try: @name <target> <new name>"}

  defp do_rename(%Parser.Command{argv: [target, new_name | _]}, ctx) do
    update_meta(target, "name", new_name, ctx)
  end

  defp update_meta_description(target, text, ctx) do
    update_meta(target, "description", text, ctx)
  end

  defp update_meta(target, key, value, ctx) do
    cond do
      target in ["here", "room"] ->
        :ok = World.set_meta(ctx.current_room_uuid, Schemas.room_filename(), key, value, ctx.store)
        {:reply, "Updated room #{key}."}

      true ->
        case World.find_entry_by_name(ctx.current_room_uuid, target, ctx.store) do
          {:ok, entry} ->
            filename =
              cond do
                String.ends_with?(entry.name, ".obj") -> Schemas.object_filename()
                true -> nil
              end

            if filename do
              :ok = World.set_meta(entry.node_id, filename, key, value, ctx.store)
              {:reply, "Updated #{target} #{key}."}
            else
              {:error, "Can't update #{target} #{key}."}
            end

          :error ->
            {:error, "You don't see \"#{target}\" here."}
        end
    end
  end

  defp strip_first_word(args) do
    case String.split(args, ~r/\s+/, parts: 2) do
      [_word, rest] -> rest
      _ -> ""
    end
  end

  defp add_dir_entry(parent_uuid, name, child_uuid, store) do
    {:ok, schema} = Schemas.load_dir_schema(parent_uuid, store)
    schema = Schema.add_directory(schema, name, child_uuid)
    update = Yelixer.Encoding.encode_update(schema)
    CommitStoreClient.create_chained_commit(store, parent_uuid, update)
    :ok
  end

  defp update_room_exit(room_dir_uuid, direction, dest_uuid, store) do
    case World.get_room(room_dir_uuid, store) do
      {:ok, %Room{} = room} ->
        new_exits = Map.put(room.exits, direction, dest_uuid)
        json = Schemas.encode_room(%Room{room | exits: new_exits})
        {:ok, schema} = Schemas.load_dir_schema(room_dir_uuid, store)
        {:ok, entry} = Schema.get_entry(schema, Schemas.room_filename())
        :ok = Schemas.write_meta_doc(entry.node_id, json, store)
        :ok

      err ->
        err
    end
  end

  # ---- Scope resolution ----

  defp find_in_scope(target, ctx) do
    needle = String.downcase(target)

    case World.find_entry_by_name(ctx.inventory_uuid, target, ctx.store) do
      {:ok, entry} -> resolve_entry(entry, ctx)
      :error -> find_in_room(target, needle, ctx)
    end
  end

  defp find_in_room(target, needle, ctx) do
    case World.find_entry_by_name(ctx.current_room_uuid, target, ctx.store) do
      {:ok, entry} ->
        cond do
          String.ends_with?(entry.name, ".usr") ->
            load_player_for_lookup(entry, needle, ctx)

          true ->
            resolve_entry(entry, ctx)
        end

      :error ->
        :not_found
    end
  end

  defp resolve_entry(%Schema.Entry{} = entry, ctx) do
    cond do
      String.ends_with?(entry.name, ".obj") ->
        case Schemas.load_object(entry.node_id, ctx.store) do
          {:ok, obj} -> {:ok, :object, obj}
          _ -> :not_found
        end

      String.ends_with?(entry.name, ".usr") ->
        load_player_for_lookup(entry, "", ctx)

      true ->
        :not_found
    end
  end

  defp load_player_for_lookup(entry, _needle, ctx) do
    bare = entry.name |> String.replace_suffix(".usr", "")
    path = "players/#{bare}"

    with {:ok, player_dir_uuid} <- World.resolve_path(path, ctx.root_uuid, ctx.store),
         {:ok, player} <- Schemas.load_player(player_dir_uuid, ctx.store) do
      {:ok, :player, player}
    else
      _ -> :not_found
    end
  end

  defp help_text do
    """
    Commands:
      look [target]                    look at the room or a target
      n/s/e/w/u/d  or  go <direction>  move
      say <text>  ('<text>)            speak in the room
      emote <text>                     act out
      take <obj> / drop <obj>          pick up / drop an object
      give <obj> <player>              give an object to someone here
      i / inventory                    list what you carry
      who                              list players online
      help                             this help
      quit                             disconnect

    Builders:
      @dig <dir> <name>                carve a new room in <dir>
      @create object|room <name>       create here
      @desc <target> <text>            set description (target: here, or obj name)
      @name <target> <new name>        rename
      @verb <target>:<verbname>        edit a verb on a room/object (line editor;
                                       finish with '.' on its own line, '@abort'
                                       cancels)
      @listen                          subscribe to debug events
      @dump [target]                   dump raw struct
    """
  end
end
