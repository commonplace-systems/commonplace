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

  ## Session identity (CX-lg06)

  Resolved ONCE here at `init/1` — never re-derived downstream — mirroring
  the discipline `CommonplaceWebWeb.SessionIdentity.resolve/1` uses for
  the browser door (see `docs/plans/2026-07-06-qat5.2-browser-identity-spec.md`
  §2.3). Two ways in:

    * `opts[:signing_context]` — a pre-resolved `%SigningContext{}`,
      passed directly (tests, embedders that already hold the key).
    * `opts[:player_identity_uuid]` (+ `opts[:secret_store]`, default
      `Commonplace.Store.SecretStore`) — resolved via
      `Commonplace.Crypto.AgentKeys.signing_context/2`. `{:error,
      :not_found}` (no keypair minted for this identity) falls back to
      the anonymous/unsigned behavior — never crashes the session.

  Neither opt given → `signing_context: nil`, and every write this
  session's verbs make stays exactly as unsigned as it is today
  (permissive workspaces must keep working logged-out).

  **Hand model (FLAG):** unlike the browser door's `WriterHand.for_session/2`
  (which needs a nonce persisted across LiveView remounts), a
  `PlayerSession` is a single long-lived GenServer for the whole login —
  there is no reconnect/remount boundary to make a persisted nonce worth
  the complexity. Signed writes instead use
  `WriterHand.for_doc_actor(doc_uuid, signer_id)` at each write site (via
  `Commonplace.MUD.SignedWrite.hand_for/2`) — the deterministic
  per-(doc, actor) funnel hand already used for docs with genuinely
  concurrent distinct writers (shared room/dir schemas edited by several
  players' separate session processes). See `WriterHand`'s moduledoc for
  why this family is the correct one for concurrent-writer docs.

  **Cert selection (FLAG):** `opts[:cert_cids]` is a flat list of
  capability CIDs this player is known to hold, threaded into every
  verb's `ctx` and consulted by `Commonplace.MUD.SignedWrite.opts_for/2`
  (linear scan, first cert whose scope covers the write's target doc
  wins — see that module's moduledoc for the full rationale). This
  build does NOT attempt commit-log discovery of a player's certs at
  session start (the mechanism `Sections.auto_extend_for_new_room/3`
  uses for its own candidate search) — callers that already know which
  certs a player holds (tests, a future login flow) pass them directly;
  wiring up automatic discovery at session start is a documented
  follow-up, not required for signed-but-capability-checked writes to
  work end-to-end.
  """

  use GenServer
  require Logger

  alias Commonplace.Crypto.{AgentKeys, Signing}
  alias Commonplace.MUD.{Parser, Schemas, SignedWrite, Topics, Verbs, VerbSource}
  alias Commonplace.MUD.Schemas.{Player, Room}
  alias Commonplace.Presence
  alias Commonplace.Store.{CommitStoreClient, SecretStore}
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
    :signing_context,
    :signer_id,
    mode: :normal,
    buffer: nil,
    cert_cids: []
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
    cert_cids = Keyword.get(opts, :cert_cids, [])
    {signing_context, signer_id} = resolve_identity(opts)
    write_opts = [signing_context: signing_context, cert_cids: cert_cids, signer_id: signer_id, store: store]

    case bootstrap_player(name, root_uuid, write_opts) do
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
          signing_context: signing_context,
          signer_id: signer_id,
          cert_cids: cert_cids,
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

  # CX-gq7a: an empty (or whitespace-only) verb body — most commonly
  # typing '.' as the very first line, before any body text — used to
  # reach `Yelixer.Types.Text.insert/4` with `text == ""`, which had no
  # no-op clause and raised `FunctionClauseError`, crashing the
  # PlayerSession. `Text.insert/4` now has a genuine no-op clause for
  # empty text (defense in depth), but we also validate here so an
  # accidental blank save reports a clear message instead of silently
  # writing (or clearing) a verb with no content.
  defp save_verb(ed, state) do
    source_text = Enum.join(ed.lines, "\n")

    if String.trim(source_text) == "" do
      state.output_fn.("(save aborted: verb body is empty — type a body before '.', or '@abort' to cancel)")
      {:noreply, %{state | mode: :normal}}
    else
      do_save_verb(ed, source_text, state)
    end
  end

  # CX-bg1v/CX-fhz4 — `@verb` authoring now goes through the SAFE path
  # (`VerbSource.save_safe_verb/6`: lint + AST allowlist + define-gate +
  # facade-bound execution), not the legacy `save_verb/5` (unlinted,
  # ambient store/ctx access — the RCE surface CX-bg1v closed). The
  # author's text is a bare `run/2` BODY, not a full `defmodule`; see the
  # `{:enter_editor, ...}` prompt below for what's in scope.
  defp do_save_verb(ed, source_text, state) do
    section_scope = [ed.target_uuid]

    case VerbSource.save_safe_verb(
           ed.target_uuid,
           ed.verb_name,
           source_text,
           section_scope,
           state.store,
           session_write_opts(state)
         ) do
      :ok ->
        state.output_fn.("(saved #{ed.target_label}:#{ed.verb_name} — safe verb, compiles cleanly)")
        {:noreply, %{state | mode: :normal}}

      {:error, {:lint_violation, reasons}} ->
        state.output_fn.("(rejected: #{Enum.join(reasons, "; ")})")
        {:noreply, %{state | mode: :normal}}

      {:error, {:unsafe_verb, reason}} ->
        state.output_fn.("(rejected: uses a disallowed operation — #{inspect(reason)})")
        {:noreply, %{state | mode: :normal}}

      {:error, {:compile_error, msg}} ->
        state.output_fn.("(saved with compile error: #{msg})")
        {:noreply, %{state | mode: :normal}}

      {:error, {:execution_denied, _reason}} ->
        state.output_fn.("(save failed: you don't have permission to define verbs here)")
        {:noreply, %{state | mode: :normal}}

      {:error, {:no_run_export, _}} ->
        state.output_fn.("(saved, but the module does not export run/2 — verb won't fire)")
        {:noreply, %{state | mode: :normal}}

      # CX-93ea: the write itself (not just compilation) can now fail —
      # e.g. `{:trust_rejected, _}` under `local_write_gate: :enforce` —
      # surfaced distinctly so the author sees permission language
      # instead of a bare inspect() of an internal tuple.
      {:error, {:trust_rejected, _reason}} ->
        state.output_fn.("(save failed: you don't have permission to edit verbs here)")
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

  # CX-3xwu: retract the player's `.usr` presence on session teardown, so
  # `quit` ({:stop, :normal, state}) and `PlayerSession.stop/1`
  # (GenServer.stop :normal) don't leave a ghost in `who`/room rosters.
  # Presence does NOT relocate on room moves (it stays where it was
  # created), so LOCATE it via `find_presence/3` rather than trusting
  # `current_room_uuid`. Best-effort: teardown must never crash a
  # supervised session, and a missing presence (already reaped, never
  # created) is a no-op. Only the online marker is retracted — the
  # persistent player record (`/players/<name>/` + inventory) is a
  # separate doc and is intentionally left intact so items/character
  # survive a reconnect. (Removal is unsigned, matching the current
  # unsigned-presence write model — see `ensure_player_in_world/3`'s note;
  # under `:enforce` a player without write to the presence's room would
  # not retract, which is the same follow-up the create path carries.)
  @impl true
  def terminate(_reason, %__MODULE__{presence_filename: fname, root_uuid: root, store: store})
      when is_binary(fname) and is_binary(root) do
    case find_presence(root, fname, store) do
      {:ok, room_uuid, _presence_uuid} -> Presence.remove(fname, room_uuid, store)
      _ -> :ok
    end

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  def terminate(_reason, _state), do: :ok

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
          "type a bare run/2 BODY (no defmodule). In scope: `world` (this " <>
          "room/object) and `args` — a MAP %{target, argv, args} (e.g. " <>
          "args.argv is the word list, args.target the object noun). " <>
          "e.g. Commonplace.MUD.World.Facade.say(world, \"hi\")"
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
      signing_context: state.signing_context,
      signer_id: state.signer_id,
      cert_cids: state.cert_cids,
      cmd: cmd
    }
  end

  # CX-lg06: same {store, signing_context, cert_cids, signer_id} shape
  # `Commonplace.MUD.Verbs`' own `write_opts/1` builds from `ctx` — kept
  # here too since the `@verb` editor's save happens outside a single
  # `Verbs.dispatch` call (multi-line input collection in between).
  defp session_write_opts(state) do
    [
      store: state.store,
      signing_context: state.signing_context,
      cert_cids: state.cert_cids,
      signer_id: state.signer_id
    ]
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

  # CX-aw4r: server-attributed action from a safe verb's `emit_action/3`.
  # `who` is server-supplied (the facade's bound ctx), so it cannot be
  # forged by author code; the name is composed per-recipient here, like
  # `:say`. Actor reads "You <first_person>", observers "<who> <third_person>".
  defp render_event(%{kind: :put, who: who, what: what, where: where}, state) do
    if who == state.player_name do
      state.output_fn.("You put #{what} in #{where}.")
    else
      state.output_fn.("#{who} puts #{what} in #{where}.")
    end
  end

  defp render_event(%{kind: :get_from, who: who, what: what, from: from}, state) do
    if who == state.player_name do
      state.output_fn.("You get #{what} from #{from}.")
    else
      state.output_fn.("#{who} gets #{what} from #{from}.")
    end
  end

  defp render_event(%{kind: :action, who: who, first_person: fp, third_person: tp}, state) do
    if who == state.player_name do
      state.output_fn.("You #{fp}")
    else
      state.output_fn.("#{who} #{tp}")
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

  ## Session identity resolution (CX-lg06)

  # Returns `{signing_context | nil, signer_id | nil}`. See moduledoc
  # "Session identity" section for the two ways in and the anonymous
  # fallback.
  defp resolve_identity(opts) do
    case Keyword.get(opts, :signing_context) do
      %Commonplace.Crypto.SigningContext{} = ctx ->
        {ctx, Signing.signer_id(ctx.identity_uuid, ctx.public_key)}

      nil ->
        resolve_identity_from_uuid(Keyword.get(opts, :player_identity_uuid), opts)
    end
  end

  defp resolve_identity_from_uuid(nil, _opts), do: {nil, nil}

  defp resolve_identity_from_uuid(identity_uuid, opts) when is_binary(identity_uuid) do
    secret_store = Keyword.get(opts, :secret_store, SecretStore)

    case AgentKeys.signing_context(identity_uuid, secret_store) do
      {:ok, ctx} -> {ctx, Signing.signer_id(ctx.identity_uuid, ctx.public_key)}
      {:error, _} -> {nil, nil}
    end
  end

  ## Bootstrap player

  # `write_opts` is the keyword list `[store:, signing_context:,
  # cert_cids:, signer_id:]` resolved once in `init/1` — threaded
  # through every bootstrap write below (CX-lg06), same shape
  # `Commonplace.MUD.Verbs`' own `write_opts/1` builds from a verb ctx.
  defp bootstrap_player(name, root_uuid, write_opts) do
    store = Keyword.fetch!(write_opts, :store)

    with {:ok, players_dir_uuid} <- ensure_players_dir(root_uuid, write_opts),
         {:ok, %{player_dir_uuid: pdir, inventory_uuid: inv}} <-
           ensure_player_dir(name, players_dir_uuid, write_opts),
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

  defp ensure_players_dir(root_uuid, write_opts) do
    store = Keyword.fetch!(write_opts, :store)
    {:ok, root_schema} = Schemas.load_dir_schema(root_uuid, store)

    case Schema.get_entry(root_schema, @players_dir) do
      {:ok, entry} ->
        {:ok, entry.node_id}

      :error ->
        with {:ok, new_uuid} <- Schemas.create_dir_with_meta(nil, nil, store, write_opts),
             :ok <- add_dir_entry(root_uuid, @players_dir, new_uuid, write_opts) do
          {:ok, new_uuid}
        end
    end
  end

  defp ensure_player_dir(name, players_dir_uuid, write_opts) do
    store = Keyword.fetch!(write_opts, :store)
    {:ok, players_schema} = Schemas.load_dir_schema(players_dir_uuid, store)

    case Schema.get_entry(players_schema, name) do
      {:ok, entry} ->
        {:ok, schema} = Schemas.load_dir_schema(entry.node_id, store)

        case Schema.get_entry(schema, "inventory") do
          {:ok, e} ->
            {:ok, %{player_dir_uuid: entry.node_id, inventory_uuid: e.node_id}}

          :error ->
            with {:ok, new_uuid} <- Schemas.create_dir_with_meta(nil, nil, store, write_opts),
                 :ok <- add_dir_entry(entry.node_id, "inventory", new_uuid, write_opts) do
              {:ok, %{player_dir_uuid: entry.node_id, inventory_uuid: new_uuid}}
            end
        end

      :error ->
        json = Schemas.encode_player(%Player{name: name, title: name, description: "A traveler."})

        with {:ok, player_dir_uuid} <- Schemas.create_dir_with_meta(Schemas.player_filename(), json, store, write_opts),
             {:ok, inv_uuid} <- Schemas.create_dir_with_meta(nil, nil, store, write_opts),
             :ok <- add_dir_entry(player_dir_uuid, "inventory", inv_uuid, write_opts),
             :ok <- add_dir_entry(players_dir_uuid, name, player_dir_uuid, write_opts) do
          {:ok, %{player_dir_uuid: player_dir_uuid, inventory_uuid: inv_uuid}}
        end
    end
  end

  # Presence creation (`Presence.create/4`) is NOT threaded with signing
  # opts in this build — it's a core module shared with chat/other
  # surfaces, out of the MUD composition boundary this bead touches, and
  # it fires at most once ever per player (idempotent thereafter via
  # `find_presence/3` below). Flagged as a follow-up, not required for
  # the acceptance path (an already-registered player's repeat logins
  # never call it again).
  defp ensure_player_in_world(name, root_uuid, store) do
    presence_filename = Presence.filename(name, :usr)

    case find_presence(root_uuid, presence_filename, store) do
      {:ok, room_uuid, presence_uuid} ->
        {:ok, room_uuid, presence_uuid}

      :not_found ->
        with {:ok, start_room_uuid} <- ensure_start_room(root_uuid, store),
             {:ok, presence_uuid} <- Presence.create(name, :usr, start_room_uuid, store) do
          {:ok, start_room_uuid, presence_uuid}
        end
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

  # Unsigned on purpose (see `ensure_player_in_world/3` note above) — the
  # start room, like presence creation, exists at most once ever per
  # workspace and is not part of this bead's signed-write acceptance
  # path.
  defp ensure_start_room(root_uuid, store) do
    {:ok, root_schema} = Schemas.load_dir_schema(root_uuid, store)

    case Schema.get_entry(root_schema, @start_room_name) do
      {:ok, entry} ->
        {:ok, entry.node_id}

      :error ->
        json = Schemas.encode_room(%Room{name: "The Start Room", description: "A featureless white room. The world has not been built out yet.", exits: %{}})

        with {:ok, room_uuid} <- Schemas.create_dir_with_meta(Schemas.room_filename(), json, store),
             :ok <- add_dir_entry(root_uuid, @start_room_name, room_uuid, store: store) do
          {:ok, room_uuid}
        end
    end
  end

  # `write_opts` here is either the bootstrap-wide keyword list (signed
  # path, from `ensure_players_dir/2` / `ensure_player_dir/3`) or a bare
  # `[store: store]` (unsigned path, from `ensure_start_room/2`) —
  # `SignedWrite.opts_for/2` treats a missing/nil `:signing_context`
  # identically either way (empty metadata, empty commit opts).
  defp add_dir_entry(parent_uuid, name, child_uuid, write_opts) do
    store = Keyword.fetch!(write_opts, :store)
    {:ok, schema} = Schemas.load_dir_schema(parent_uuid, store)
    schema = Schema.add_directory(schema, name, child_uuid)
    update = Encoding.encode_update(schema)
    {metadata, commit_opts} = SignedWrite.opts_for(parent_uuid, write_opts)

    case CommitStoreClient.create_chained_commit(store, parent_uuid, update, metadata, commit_opts) do
      {:error, _} = err -> err
      _commit -> :ok
    end
  end

  # silence unused alias warning when DocBuilder isn't referenced
  _ = DocBuilder
end
