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

  Neither opt given → under `:enforce` the node provisions a server-generated
  EPHEMERAL identity + `{:presence}` cert (a presence-only visitor — CX-sfj8);
  under permissive/off, `signing_context: nil` and every write stays as unsigned
  as it is today (permissive workspaces must keep working logged-out).

  ### 🔑 STANDING CRUX FORWARD-GUARD (CX-sfj8, plan #7820)

  `player_identity_uuid` is honored by resolving the node-held key
  (`AgentKeys` signs on the user's behalf — the web user does NOT hold their own
  private key), so the chokepoint MUST honor a node-backed uuid and CANNOT demand
  proof-of-possession without breaking the web model. Therefore the impersonation
  defense is NOT inside `provision_session_creds` — it is at the ENTRYPOINT:

  > **INVARIANT: no entrypoint may pass a CLIENT-SUPPLIED `player_identity_uuid`
  > to this session. It MUST be SERVER-RESOLVED from authenticated session state.**

  Audited entrypoints: the web door resolves from the authenticated `live_session`
  (never client params); bots resolve on the serve via `register`. The local-stdio
  MCP `name` path is CX-3ab7 (operator-trust today; PROMOTES to a must-fix blocker
  if MCP is ever exposed on a remote transport). **Any NEW session entrypoint MUST
  be audited for where its identity originates before it ships** — a
  client-settable `player_identity_uuid` is total impersonation.

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
  alias Commonplace.MUD.{EngineModule, Parser, Schemas, SignedWrite, Topics, Verbs, VerbSource, World}
  alias Commonplace.MUD.Schemas.{Object, Player, Room}
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

  @doc """
  CX-i9j3 (UI Inc-2): the materialized self-view room-pane sections for
  this session's CURRENT room (name/desc/exits/contents/occupants), for
  `Commonplace.MUD.SessionView.replace_room/2`. Read-only; returns
  `{:ok, sections}` or `{:error, reason}`.
  """
  def room_snapshot(pid), do: GenServer.call(pid, :room_snapshot, 10_000)

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
    # CX-sfj8/CX-jicn — THE session-identity chokepoint (plan #7808 LBD-1): every
    # session gets a resolved identity AND a GUARANTEED {:presence} cert, so no
    # entrypoint and no partial-provision failure can produce an uncertified
    # session (that bypass/failure is exactly the ghost + trust-flood gap).
    {signing_context, signer_id, cert_cids, session_kind} = provision_session_creds(opts, store)

    write_opts = [
      signing_context: signing_context,
      cert_cids: cert_cids,
      signer_id: signer_id,
      store: store,
      # CX-gjpi: spawn-in-home — a browser player is placed in the room
      # they OWN (their `players/<name>/` home, provisioned by
      # `Commonplace.MUD.Citizenship`) on first appearance, not the shared
      # `start` room. `nil` (bots, CLI) reproduces the prior start-room
      # spawn exactly (see `ensure_player_in_world/3`).
      spawn_room_uuid: Keyword.get(opts, :spawn_room_uuid)
    ]

    case bootstrap_for(session_kind, name, root_uuid, write_opts) do
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

  # CX-i9j3 (UI Inc-2): re-project the CURRENT room's state into pane
  # sections (the same data `render_room/1`'s `look` computes). Read-only —
  # no state change.
  def handle_call(:room_snapshot, _from, state) do
    {:reply,
     World.room_snapshot(state.current_room_uuid, state.presence_filename, state.store,
       viewer: session_identity_uuid(state)
     ), state}
  end

  def handle_call({:input, line}, _from, state) do
    case process_input(line, state) do
      {:noreply, new_state} -> {:reply, :ok, new_state}
      {:stop, reason, new_state} -> {:stop, reason, :ok, new_state}
    end
  end

  defp process_input(line, %__MODULE__{mode: :normal} = state) do
    # CX-2xez (MUD-as-documents Inc-1): the ONE behavioral call site routes
    # through the doc-hosted parser (with last-good/floor fallback + crash
    # containment); `Parser.Command`/`Parser.opposite_direction` etc. stay
    # kernel and are used directly elsewhere.
    cmd = EngineModule.parse(line, state.store)

    if cmd.verb == "" do
      {:noreply, state}
    else
      ctx = build_ctx(state, cmd)

      case Verbs.dispatch(cmd, ctx) do
        :unhandled -> handle_unhandled(cmd, ctx, state)
        result -> handle_verb_result(result, state)
      end
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
    # CX-zyee: a buffered session (browser / bot) must have its greeting —
    # the Welcome banner AND the spawn-room render — land in the output
    # buffer SYNCHRONOUSLY in this handler, so the mount's paired drain
    # (MudLive's `:enter`, Bot's settle-then-drain) reliably captures it as
    # the session-open turn. Emitting through `output_fn` (a cast-to-self
    # for buffered sessions) enqueued the render as `{:buffer_append, ...}`
    # messages AFTER an already-queued `:drain_buffer` call, so a fresh
    # `look` returned only the stale "Welcome" banner and the actual room
    # render slipped into a later (dimmed AMBIENT) turn. Composing the
    # lines and appending them to the buffer HERE removes that race. An
    # unbuffered (CLI, `IO.puts`) session keeps writing straight through
    # `output_fn`, exactly as before.
    lines = greet_lines(state)

    state =
      if is_list(state.buffer) do
        %{state | buffer: state.buffer ++ lines}
      else
        Enum.each(lines, state.output_fn)
        state
      end

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
  # survive a reconnect.
  #
  # CX-i9w9 (presence-signing, Model A): the retraction is SIGNED with the
  # session's own creds (`signing_context` + `cert_cids`, which include the
  # citizenship-minted `{:presence, id}` cert). Under `:enforce`, an unsigned
  # remove is `{:trust_rejected, :unsigned}` → the .usr entry never retracts →
  # accumulating ghosts + a stale room "also here". Signed, the CX-0a9a carve
  # authorizes the player's own-presence dir write (bound_identity == signer),
  # so leave actually retracts. (The create path is already signed; this closes
  # the matching remove path the old comment flagged as a follow-up.)
  @impl true
  def terminate(_reason, %__MODULE__{
        presence_filename: fname,
        root_uuid: root,
        store: store,
        signing_context: signing_context,
        cert_cids: cert_cids
      })
      when is_binary(fname) and is_binary(root) do
    case find_presence(root, fname, store) do
      {:ok, room_uuid, _presence_uuid} ->
        Presence.remove(fname, room_uuid, store,
          signing_context: signing_context,
          cert_cids: cert_cids
        )

      _ ->
        :ok
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

  # CX-cj3t: the caller can't author verbs here (a {:write}-only citizen — the
  # write⊥execute belt refuses executable code). Show a READ-ONLY PREVIEW upfront
  # (the current source, so they can still read/learn it) rather than opening a
  # full editor and only denying the save. Do NOT enter :editor mode — subsequent
  # lines are normal commands, not a verb body.
  defp handle_verb_result({:enter_editor, %{editable: false} = ed}, state) do
    state.output_fn.("=== #{ed.target_label}:#{ed.verb_name} (preview — read-only) ===")
    state.output_fn.("(you don't have permission to author verbs here — showing the current source)")

    if ed.current != "" do
      state.output_fn.(ed.current)
    else
      state.output_fn.("(no verb '#{ed.verb_name}' is defined here yet)")
    end

    {:noreply, state}
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
          "room/object) and `args` = %{target, argv, args, rest}.\n" <>
          "  args.target = the FIRST noun word — so 'chant spark' → " <>
          "args.target is \"spark\", args.rest is \"\" (CX-hmmc).\n" <>
          "  args.rest = the text AFTER the first noun — 'play box a waltz' " <>
          "→ args.rest is \"a waltz\".\n" <>
          "  On an OBJECT verb the first noun IS the object it runs on, so your " <>
          "free args start at args.rest — 'bestow handoff mira' (NOT 'bestow mira').\n" <>
          "Common calls (always Commonplace.MUD.World.Facade.<fn>(world, ...)):\n" <>
          "  say(world, text) [ALOUD in room] · notify(world, text) [PRIVATE to the actor — use for puzzle STATUS/feedback, not say] · emit_action(world, \"lift the lid\", \"lifts the lid\")  [attributed: You / <name>]\n" <>
          "  random(world, n) [1..n]  ·  pick(world, list)  ·  actor_carries?(world, name)\n" <>
          "  actor_name(world) [display] · actor_ref(world) [stable per-player KEY]\n" <>
          "  get_state(world, key)  ·  put_state(world, key, value)\n" <>
          "Per-player state: KEY on actor_ref (stable across rename), DISPLAY with actor_name — " <>
          "e.g. put_state(world, \"score:\" <> actor_ref(world), n).\n" <>
          "State rules (CX-drp2): put_state writes IMMEDIATELY and persists at ANY position — " <>
          "many per verb all stick; it need NOT be the last line.\n" <>
          "  value may be a string / number / boolean OR a list / string-keyed map (≤1024 bytes, CX-qexv).\n" <>
          "  Always Facade.fn(world, ...) with `world` the LITERAL first arg — " <>
          "NO `world |> Facade.fn(...)` (pipe) and NO nesting; bind reads first: " <>
          "`n = get_state(world, \"n\"); put_state(world, \"n\", n + 1)`. `world`/`args` can't be reassigned."
      )
    end

    {:noreply, %{state | mode: {:editor, Map.put(ed, :lines, [])}}}
  end

  # CX-wnof — `Verbs.dispatch` returning bare `:unhandled` is a deliberate
  # trust-boundary contract (see `verbs_safe_dispatch_test.exs` pins 4/6):
  # it never says WHY a verb didn't run — a target with no verb defined on
  # it and a target whose verb was refused/never-persisted at authoring
  # both collapse to the same opaque `:unhandled`, so no authorization
  # reasoning ever leaks through the message. This is a pure DISPLAY layer
  # on top of that unchanged contract: if the player's typed target
  # resolves to a real, visible object (the SAME read-only substring
  # matcher `take`/`give`/`unlock` dispatch itself uses — nothing the
  # player couldn't already see via `look`), say "You can't <verb>
  # <name>." instead of the blanket "I don't understand that." A newcomer
  # typing `unlock vault` at a container named "Warded Vault" (partial-
  # name match) now gets a targeted reply instead of a raw parser error,
  # without changing what ran or widening what the message reveals.
  defp handle_unhandled(%Parser.Command{verb: verb, target: target}, ctx, state) when is_binary(target) do
    case resolved_target_display_name(target, ctx, state) do
      {:ok, name} -> state.output_fn.("You can't #{verb} #{name}.")
      :error -> state.output_fn.("I don't understand that.")
    end

    {:noreply, state}
  end

  defp handle_unhandled(_cmd, _ctx, state) do
    state.output_fn.("I don't understand that.")
    {:noreply, state}
  end

  # CX-c6ph — rank by match QUALITY across inventory + room (exact-name
  # beats an alias/partial match in the other dir), inventory-first order
  # breaking ties (mirrors `Verbs.find_entry_in_dirs/3`).
  defp resolved_target_display_name(target, ctx, state) do
    [ctx.inventory_uuid, ctx.current_room_uuid]
    |> Enum.map(fn dir -> World.find_entry_ranked(dir, target, state.store) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.max_by(fn {s, _} -> s end, fn -> nil end)
    |> case do
      {_score, entry} -> {:ok, object_display_name(entry, state.store)}
      nil -> :error
    end
  end

  defp object_display_name(entry, store) do
    case Schemas.load_object(entry.node_id, store) do
      {:ok, %Object{name: name}} when is_binary(name) and name != "" -> name
      _ -> entry.name
    end
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

  # The greet turn's lines: the Welcome banner followed by the spawn-room
  # render (the same `look` projection `render_room/1` emits), as plain
  # values so `handle_info(:greet, ...)` can place them in the buffer
  # synchronously (CX-zyee). A `look` that doesn't render (unexpected)
  # degrades to just the banner rather than crashing the greet.
  defp greet_lines(state) do
    welcome = "Welcome, #{state.player_name}.\n"

    case Verbs.dispatch(%Parser.Command{verb: "look"}, build_ctx(state, %Parser.Command{})) do
      {:reply, room} when is_binary(room) -> [welcome, room]
      _ -> [welcome]
    end
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

  # CX-ydmv: emote text is author-written THIRD-person, meant to complete a
  # sentence after the actor's NAME ("sets the firefly jar down"). The actor's
  # own self-echo must therefore ALSO render "<name> <text>", not "You <text>" —
  # the server can't conjugate "sets"->"set" for arbitrary text, so "You sets
  # the jar down" is grammatically broken. Classic-MUD emote: everyone,
  # including the actor, reads the name form (this matches the observer branch
  # the room already saw). Contrast `:action`/`emit_action`, which carries a
  # distinct author-conjugated first-person string and so keeps its "You <fp>".
  defp render_event(%{kind: :emote, who: who, text: text}, state) do
    state.output_fn.("#{who} #{text}")
  end

  # CX-cj3t.10 — directed private messaging. Delivered via `World.tell/2`
  # (the recipient's own actor-only tell topic), so only the recipient's
  # session ever renders this — no actor-vs-observer split needed.
  defp render_event(%{kind: :whisper, who: who, text: text}, state) do
    state.output_fn.("#{who} whispers: #{text}")
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

  # CX-5ujj — mine (items epic phase 2) had no render_event clause, so
  # the raw `%{kind: :mine, who:, what:, from:}` broadcast fell through
  # to the `inspect/1` catch-all and leaked to bystanders. Mirrors
  # :take's shape (actor already got their own first-person "You extract
  # ..." line from the verb's {:reply}; this is observers only).
  defp render_event(%{kind: :mine, who: who, what: what, from: from}, state) do
    if who != state.player_name do
      state.output_fn.("#{who} extracts #{what} from the #{from}.")
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
  # The actor already gets the first-person line from the verb's {:reply};
  # this broadcast is for OBSERVERS only (mirrors :take/:drop) — rendering
  # it to the actor too doubled the line (boss #5979 nit a).
  defp render_event(%{kind: :put, who: who, what: what, where: where}, state) do
    if who != state.player_name do
      state.output_fn.("#{who} puts #{what} in #{where}.")
    end
  end

  defp render_event(%{kind: :get_from, who: who, what: what, from: from}, state) do
    if who != state.player_name do
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

  # CX-3x5a — a DIM author-diagnostic: a facade method returned {:error, _}
  # that the verb SILENTLY DROPPED (ignored the return). Delivered via
  # `World.tell/2` to the INVOKER only (same actor-only tell topic as
  # :whisper), so only the verb's caller sees it. The text already arrives
  # pre-framed as a parenthetical "(verb note: …)" note — clearly a
  # diagnostic, not gameplay narration.
  defp render_event(%{kind: :verb_diagnostic, text: text}, state) do
    state.output_fn.(text)
  end

  # CX-<notify> — invoker-private, non-speech verb feedback (the puzzle-
  # feedback channel). Plain text, no "You say"/"X whispers" framing — it's
  # the verb's own status/result to the actor.
  defp render_event(%{kind: :notice, text: text}, state) do
    state.output_fn.(text)
  end

  defp render_event(%{kind: :custom, text: text}, state) do
    state.output_fn.(text)
  end

  # CX-jicn.2 (output-hygiene): a raw trust event — `{:trust,
  # :local_write_denied, meta}` (a write rejected by the local-write gate
  # under `:enforce`) or `{:trust, :section_extend_skipped, meta}` —
  # reaches this session via the `red:` PubSub broadcast, delivered to the
  # writer AND every co-present observer subscribed to the room topic. It
  # is an INTERNAL trust-engine signal, never gameplay: the writer already
  # received a graceful synchronous verb reply ("You don't have permission
  # …", CX-93ea) at the denied verb, and an observer must never see another
  # player's write-denial at all. So it is DROPPED SILENTLY here — never
  # `inspect/1`-ed into anyone's pane (the raw `{:trust, :local_write_denied,
  # %{reason:, doc_uuid:, signer_id:}}` leak this fix closes). Same
  # never-surface-raw-internals spine as the safe-verb graceful-refusal
  # discipline (`Commonplace.MUD.World.Facade`). Must precede the
  # `inspect/1` catch-all below.
  defp render_event({:trust, _event, _meta}, _state), do: :ok

  defp render_event(other, state) do
    state.output_fn.("(event: #{inspect(other)})")
  end

  # CX-ivqz (read-scoping P2): the session's own identity_uuid, threaded
  # to `World.room_snapshot/4` as `:viewer` — `nil` for an unsigned
  # session (an unauthenticated viewer, never the same as the room owner,
  # so a gated room correctly refuses them).
  defp session_identity_uuid(%{signing_context: %Commonplace.Crypto.SigningContext{identity_uuid: id}}),
    do: id

  defp session_identity_uuid(_state), do: nil

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

  # CX-sfj8/CX-jicn — provision the session's creds at bootstrap (plan #7808):
  # resolve a DURABLE identity first (a server-resolved signing_context, or a
  # node-key-backed player_identity_uuid), ELSE provision a NODE-GENERATED
  # EPHEMERAL keypair. In BOTH cases GUARANTEE a node-signed {:presence, id} cert
  # for the resolved identity, so the session can sign its own presence add
  # (appear) and remove (retract on quit) under :enforce — no ghost, no
  # trust-flood. Returns {signing_context, signer_id, cert_cids, kind}.
  #
  # CRUX (plan's #1 review item): a durable identity is honored ONLY when the
  # caller supplied the private key (signing_context = proof of possession) or
  # the NODE holds its key (AgentKeys). A bare, node-unbacked player_identity_uuid
  # is NOT fabricated into an identity — it falls to an ephemeral one. Entrypoints
  # MUST server-resolve player_identity_uuid from authenticated session state (web
  # door: authenticated live_session; bot: the serve's own register) — never a
  # client-claimed value (audited; the local-stdio MCP name path is CX-3ab7,
  # tracked separately with a remote-exposure promotion gate).
  #
  # EPHEMERAL KEY CUSTODY (LBD-2): server-side only, held in the session state's
  # signing_context (scrubbed from the verb-facing facade by CX-r8vp, same as any
  # session key), NEVER persisted or client-claimed; it lapses at session-end and
  # a reconnect re-provisions (presence needs no continuity).
  defp provision_session_creds(opts, store) do
    case resolve_identity(opts) do
      {%Commonplace.Crypto.SigningContext{} = ctx, signer_id} ->
        # Durable identity → full player, cert_cids threaded AS-PASSED. Production
        # durable sessions already provision their presence cert upstream (a bot's
        # `Bot.resolve_signing_opts`, a web citizen's `Citizenship.ensure`), so the
        # ghost/flood gap is the IDENTITY-LESS branch below. Extending the
        # chokepoint GUARANTEE to also back-fill a cert for a durable session that
        # arrived cert-less (folding in the upstream provisioning) is a deliberate
        # authority change — deferred to the convergence bead (plan LBD-6) so it
        # doesn't silently flip a cert-less-durable session's authority here.
        {ctx, signer_id, Keyword.get(opts, :cert_cids, []), :durable}

      {nil, nil} ->
        # Identity-less. The ephemeral presence-only path applies ONLY under
        # :enforce, where an unsigned session can't write anything (that's the
        # ghost/flood gap). In permissive/off the LEGACY unsigned full-player
        # bootstrap is preserved unchanged (CLI / dogfood / tests) — an
        # identity-less full player is fine there because unsigned writes land.
        if enforce?() do
          provision_ephemeral(store)
        else
          {nil, nil, Keyword.get(opts, :cert_cids, []), :durable}
        end
    end
  end

  defp enforce?, do: Application.get_env(:commonplace, :local_write_gate) == :enforce

  # A node-generated, server-assigned ephemeral session identity + its presence
  # cert. `[]` cert on provisioning failure → cert_cids stays empty → the presence
  # write is refused under :enforce → the session does NOT appear (FAIL-CLOSED, no
  # ambient-authority ghost, plan LBD-4) and it is LOGGED (observable).
  defp provision_ephemeral(store) do
    {pub, priv} = Signing.generate_keypair()
    id = "session:" <> UUID.uuid4()
    ctx = %Commonplace.Crypto.SigningContext{identity_uuid: id, public_key: pub, private_key: priv}

    case Commonplace.MUD.Citizenship.issue_presence_starter_cert(id, pub, store) do
      [] = cids ->
        Logger.warning(
          "PlayerSession: ephemeral presence-cert provisioning FAILED (id=#{id}) — session fails closed (no presence)"
        )

        {ctx, Signing.signer_id(id, pub), cids, :ephemeral}

      cids ->
        {ctx, Signing.signer_id(id, pub), cids, :ephemeral}
    end
  end

  ## Bootstrap player

  # `write_opts` is the keyword list `[store:, signing_context:,
  # cert_cids:, signer_id:]` resolved once in `init/1` — threaded
  # through every bootstrap write below (CX-lg06), same shape
  # `Commonplace.MUD.Verbs`' own `write_opts/1` builds from a verb ctx.
  # CX-sfj8 SCOPE FORK (plan LBD-3): a DURABLE identity gets the full bootstrap
  # (persistent players/<name>/ home + inventory). An EPHEMERAL throwaway is
  # PRESENCE-ONLY — it appears + can be seen/talk, but has NO durable home or
  # inventory (a home per throwaway = orphan-litter, and it can't be authored
  # under a {:presence}-only cert anyway). Item-holding/building requires
  # upgrading to a durable identity (Citizenship.ensure) — the clean
  # visitor→citizen line.
  defp bootstrap_for(:ephemeral, name, root_uuid, write_opts),
    do: bootstrap_presence_only(name, root_uuid, write_opts)

  defp bootstrap_for(_durable, name, root_uuid, write_opts),
    do: bootstrap_player(name, root_uuid, write_opts)

  # Presence-ONLY bootstrap: just the online marker in the shared start room,
  # signed by the ephemeral identity + its {:presence} cert. No players/ dir, no
  # home, no inventory (nil) — a visitor. `ensure_player_in_world` already does a
  # home-free presence add (spawn_fresh → Presence.create), so reuse it.
  defp bootstrap_presence_only(name, root_uuid, write_opts) do
    with {:ok, room_uuid, presence_uuid} <- ensure_player_in_world(name, root_uuid, write_opts) do
      {:ok, %{player_dir_uuid: nil, inventory_uuid: nil, room_uuid: room_uuid, presence_uuid: presence_uuid}}
    end
  end

  defp bootstrap_player(name, root_uuid, write_opts) do
    with {:ok, players_dir_uuid} <- ensure_players_dir(root_uuid, write_opts),
         {:ok, %{player_dir_uuid: pdir, inventory_uuid: inv}} <-
           ensure_player_dir(name, players_dir_uuid, write_opts),
         {:ok, room_uuid, presence_uuid} <- ensure_player_in_world(name, root_uuid, write_opts) do
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

  # CX-0a9a (presence-carve): `Presence.create/5` now accepts signing
  # opts (`:signing_context` / `:cert_cids` / `:signer_id`) — threaded
  # through here from the session's bootstrap-wide `write_opts` exactly
  # like every other bootstrap write (CX-lg06). Still fires at most once
  # ever per player (idempotent thereafter via `find_presence/3` below);
  # a missing/nil `:signing_context` reproduces the prior unsigned
  # behavior exactly.
  defp ensure_player_in_world(name, root_uuid, write_opts) do
    store = Keyword.fetch!(write_opts, :store)
    presence_filename = Presence.filename(name, :usr)
    my_identity = write_opts_identity(write_opts)

    case find_presence(root_uuid, presence_filename, store) do
      {:ok, room_uuid, presence_uuid} ->
        if presence_belongs_to?(presence_uuid, my_identity, store) do
          {:ok, room_uuid, presence_uuid}
        else
          # CX-vhnj: a `<name>.usr` match whose bound_identity is NOT ours (a
          # stale migration ghost with no bound_identity, or a foreign player's
          # live presence that happens to share our name) must NOT hijack us
          # into THEIR room. Spawn fresh in our own home instead — a name
          # collision can never attach one identity to another's presence.
          spawn_fresh(name, root_uuid, store, write_opts)
        end

      :not_found ->
        spawn_fresh(name, root_uuid, store, write_opts)
    end
  end

  # CX-gjpi: spawn in the player's own home room when one was provisioned +
  # passed (`:spawn_room_uuid`, a browser citizen's `players/<name>/` home).
  # Falls back to the shared `start` room for bots / CLI / anyone who didn't
  # pass one — unchanged behavior.
  defp spawn_fresh(name, root_uuid, store, write_opts) do
    with {:ok, spawn_room_uuid} <- resolve_spawn_room(root_uuid, store, write_opts),
         {:ok, presence_uuid} <- Presence.create(name, :usr, spawn_room_uuid, store, write_opts) do
      {:ok, spawn_room_uuid, presence_uuid}
    end
  end

  # CX-vhnj: a found `<name>.usr` is OURS to reuse IFF its bound_identity equals
  # this session's identity. Symmetric on both nils: a SIGNED session reuses only
  # its OWN presence (bound == our id); an UNSIGNED/anonymous session (identity
  # nil) reuses only an anonymous presence (bound nil == nil) and never inherits
  # a signed player's. A stale permissive-era ghost (bound nil) is thus never
  # reused by a signed citizen → the spawn-in-home fix.
  defp presence_belongs_to?(presence_uuid, my_identity, store) do
    bound =
      case Commonplace.Presence.read(presence_uuid, store) do
        %{"bound_identity" => id} when is_binary(id) -> id
        _ -> nil
      end

    bound == my_identity
  end

  defp write_opts_identity(write_opts) do
    case Keyword.get(write_opts, :signing_context) do
      %Commonplace.Crypto.SigningContext{identity_uuid: id} -> id
      _ -> nil
    end
  end

  # The room a first-appearing player is placed in: their own home
  # (`:spawn_room_uuid`, if provisioned + it actually resolves to a room)
  # else the shared start room. Verifying the passed uuid is a real room
  # keeps a stale/garbage opt from stranding the player in a non-room.
  defp resolve_spawn_room(root_uuid, store, write_opts) do
    case Keyword.get(write_opts, :spawn_room_uuid) do
      uuid when is_binary(uuid) ->
        case World.get_room(uuid, store) do
          {:ok, _room} -> {:ok, uuid}
          _ -> ensure_start_room(root_uuid, store)
        end

      _ ->
        ensure_start_room(root_uuid, store)
    end
  end

  # Delegates to the shared locator in `Commonplace.MUD.World` (the walk
  # itself lives there now, used by both this teardown path and verb
  # dispatch's post-move_self room reconciliation — CX-oh5k).
  defp find_presence(root_uuid, filename, store) do
    World.find_presence(root_uuid, filename, store)
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
