defmodule CommonplaceWebWeb.MudLive do
  @moduledoc """
  CX-gjpi: browser MUD client. Wires a logged-in human's session into
  the curated MUD world (grafted under the workspace root as `"mud"`,
  `@fallback_mud_root`) via a per-LiveView, buffered
  `Commonplace.MUD.PlayerSession`, so it plays under strict+enforce
  trust exactly like the MCP bot bridge (`Commonplace.MUD.Bot`) and the
  CLI's `mud connect` path do.

  ## Identity + citizenship

  Author identity resolves ONCE per mount via
  `CommonplaceWebWeb.SessionIdentity.resolve/1` (the CX-qat5.2 /
  CX-nn4y discipline every other gated LiveView follows — see
  `WikiLive`'s moduledoc). An anonymous session never starts a
  `PlayerSession` at all — the router's `:authenticated` `live_session`
  gate (`CommonplaceWebWeb.RequireAuth`) already redirects anonymous
  dead-renders/mounts to `/`, so reaching `mount/3` here as `:anonymous`
  is a defense-in-depth branch (also exercised directly by
  `MudLiveTest`, which mounts standalone with no session).

  A resolved identity is threaded through
  `Commonplace.MUD.Citizenship.ensure/5` — the shared (bot + browser)
  seam that node-signs a presence-starter capability cert and
  provisions the player's `players/<name>/` home under the MUD root,
  BEFORE the `PlayerSession` itself ever spawns (mirroring
  `Commonplace.MUD.Bot.spawn_session/2`'s own cert-then-spawn order).

  ## One session per LiveView, not globally registered

  Unlike `Bot` (one long-lived session per bot NAME, globally
  registered so repeat MCP calls reuse it) a browser player gets a
  fresh, plain (un-registered) `PlayerSession` GenServer per LiveView
  mount, held only in `socket.assigns.session_pid` — the LiveView
  process itself is the natural one-per-connection lifetime a browser
  tab already has, so there is no cross-call reuse problem to solve.
  Only spawned `if connected?(socket)` (the disconnected-mount static
  render must not stand up a whole game session that then immediately
  gets discarded on the websocket upgrade).
  """

  use CommonplaceWebWeb, :live_view

  require Logger

  alias Commonplace.MUD.{Citizenship, PlayerSession, SessionView, SessionViewLink, SessionViewRegistry}
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.{DocBuilder, Walk}
  alias CommonplaceWebWeb.SessionIdentity
  alias Yelixer.Types.{XMLElement, XMLText}

  # Fallback if the "mud" entry can't be resolved by walking the
  # workspace schema (matches the bead's documented world root).
  @fallback_mud_root "a4f1be2a-3813-4c68-816d-40a8eaf4bbac"
  @tick_ms 1_500

  @impl true
  def mount(_params, session, socket) do
    case SessionIdentity.resolve(session) do
      :anonymous ->
        {:ok,
         socket
         |> assign(:authed, false)
         |> assign(:error, nil)
         |> assign(:view, nil)
         |> assign(:ambient_buffer, nil)
         |> assign(:session_pid, nil)
         |> assign(:input_key, 0)
         |> assign(:home_room_uuid, nil)}

      {:ok, resolved} ->
        mount_authed(resolved, socket)
    end
  end

  defp mount_authed(resolved, socket) do
    name = player_name(resolved.presence_path)
    store = CommitStoreClient

    # CX-i9j3 (UI Inc-1 increment 4b): `mud_root` and the player's
    # `home_room_uuid` (from `Citizenship.ensure/5`) must be resolved
    # BEFORE minting/loading the view — a freshly-minted view needs
    # `home_room_uuid` in hand so it can be tree-linked immediately (see
    # `load_or_new_view/3` / `SessionViewLink`). A resolution failure
    # here degrades to `home_room_uuid: nil`, `mud_root: nil` — the
    # player still gets a *working* (floating, unlinked) view-doc and
    # session, they just can't start a `PlayerSession` without a world
    # root. This mirrors the pre-existing error-only-socket behavior for
    # these two failure cases.
    {mud_root, home_room_uuid, cert_cids, error} = resolve_home(resolved, name, store)

    # CX-i9j3 (UI Inc-1 increment 4): the transcript is a committed
    # `SessionView` (one Yjs-XML view-doc), and now it SURVIVES reconnect —
    # `SessionViewRegistry` remembers this identity's current view_uuid
    # across LiveView remounts (in-memory, serve-lifetime; see the
    # registry's moduledoc). A remembered uuid is reloaded via
    # `SessionView.load/2` — NEVER a raw
    # `Commonplace.Tree.DocBuilder.reconstruct_doc` (load-bearing: load/2
    # applies the root-tag fixup a raw reconstruct doesn't, see
    # `SessionView`'s `reregister_root_tag/1`; skipping it yields a corrupt
    # nil-root doc). A missing/stale pointer (nothing registered yet, or a
    # `load/2` failure) falls back to a fresh `SessionView.new/3`, which is
    # then (re-)registered AND tree-linked (increment 4b) under the
    # player's home — see `load_or_new_view/3`. Uses the same `store`
    # (CommitStoreClient) as the rest of MudLive — SessionView routes its
    # genesis + appends through the client layer.
    view = load_or_new_view(resolved.identity_uuid, store, home_room_uuid)

    socket =
      socket
      |> assign(:authed, true)
      |> assign(:error, error)
      |> assign(:view, view)
      |> assign(:ambient_buffer, SessionView.buffer_new())
      |> assign(:session_pid, nil)
      |> assign(:input_key, 0)
      |> assign(:home_room_uuid, home_room_uuid)
      |> assign(:player_name, name)

    socket =
      if connected?(socket) and is_binary(mud_root) and is_binary(home_room_uuid) do
        start_session(socket, name, mud_root, store, resolved, cert_cids, home_room_uuid)
      else
        socket
      end

    {:ok, socket}
  end

  # Resolves `mud_root` + this player's `home_room_uuid` (via
  # `Citizenship.ensure/5`). Returns `{mud_root, home_room_uuid,
  # cert_cids, error}` — `mud_root`/`home_room_uuid` are `nil` and
  # `error` is a user-facing string on either failure, matching the
  # pre-4b behavior of surfacing a mount-time error for these two cases.
  defp resolve_home(resolved, name, store) do
    case resolve_mud_root(store) do
      {:ok, mud_root} ->
        pub = resolved.signing_context.public_key

        # Idempotent — safe to run on every mount. Degrades to `[]`
        # cert_cids on any failure (Citizenship's own graceful-
        # degradation contract); a home-provisioning failure is
        # surfaced as a mount-time error instead of a half-broken
        # session.
        case Citizenship.ensure(resolved.identity_uuid, pub, name, mud_root, store) do
          {:ok, %{cert_cids: cert_cids, home_room_uuid: home_room_uuid}} ->
            {mud_root, home_room_uuid, cert_cids, nil}

          {:error, reason} ->
            {nil, nil, [], "Could not provision your MUD home: #{inspect(reason)}"}
        end

      {:error, reason} ->
        {nil, nil, [], "The MUD world isn't available right now (#{inspect(reason)})."}
    end
  end

  # CX-i9j3 (UI Inc-1 increment 4): reconnect-persistence lookup. A
  # registered view_uuid is reloaded via `SessionView.load/2` (the ONLY
  # sanctioned reconstruction path — see the call site's comment). A
  # `load/2` failure (`{:error, _}`, e.g. a stale/garbage-collected uuid)
  # falls back to minting a fresh view rather than crashing the mount.
  #
  # CX-i9j3 (UI Inc-1 increment 4b): every MINT branch (fresh identity, or
  # a stale pointer whose `load/2` failed) also tree-links the new view
  # under the player's home (`maybe_link_view/3`) so it's
  # reachable-from-root, not just registry-reachable. The RELOAD branch
  # (`SessionView.load/2` succeeds) deliberately does NOT call the linker
  # — the view was already linked when it was first minted, and
  # re-linking on every reconnect would be redundant (idempotent, but
  # pointless) work.
  defp load_or_new_view(identity_uuid, store, home_room_uuid) do
    case SessionViewRegistry.get(identity_uuid) do
      nil ->
        mint_and_link(identity_uuid, store, home_room_uuid)

      view_uuid ->
        case SessionView.load(view_uuid, store) do
          {:ok, view} ->
            view

          {:error, _reason} ->
            mint_and_link(identity_uuid, store, home_room_uuid)
        end
    end
  end

  defp mint_and_link(identity_uuid, store, home_room_uuid) do
    view = SessionView.new(identity_uuid, store)
    SessionViewRegistry.put(identity_uuid, view.uuid)
    maybe_link_view(view, home_room_uuid, store)
    view
  end

  # `home_room_uuid` is `nil` when `resolve_home/3` failed — nothing to
  # link under, skip silently (the mount-level `error` assign already
  # surfaces that failure to the player).
  defp maybe_link_view(_view, nil, _store), do: :ok

  # A linking failure (e.g. a commit rejected under enforce) must never
  # crash the mount — the player still has a perfectly usable (if
  # floating/unlinked) view-doc. Log and move on.
  defp maybe_link_view(view, home_room_uuid, store) do
    case SessionViewLink.link(home_room_uuid, view.uuid, store) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "MudLive: failed to tree-link session view #{view.uuid} under home #{home_room_uuid}: #{inspect(reason)}"
        )

        :ok
    end
  rescue
    e ->
      Logger.warning(
        "MudLive: exception tree-linking session view #{view.uuid} under home #{home_room_uuid}: #{Exception.message(e)}"
      )

      :ok
  end

  defp start_session(socket, name, mud_root, store, resolved, cert_cids, home_room_uuid) do
    opts = [
      player_name: name,
      root_uuid: mud_root,
      store: store,
      buffered: true,
      signing_context: resolved.signing_context,
      signer_id: resolved.signer_id,
      cert_cids: cert_cids,
      # CX-gjpi: spawn the player IN the home room they own (not the
      # shared start room) so "edit your own room" works from the first
      # `look`.
      spawn_room_uuid: home_room_uuid
    ]

    case GenServer.start(PlayerSession, opts, []) do
      {:ok, pid} ->
        send(self(), :enter)
        Process.send_after(self(), :tick, @tick_ms)
        assign(socket, :session_pid, pid)

      {:error, reason} ->
        assign(socket, :error, "Could not start your MUD session: #{inspect(reason)}")
    end
  end

  @impl true
  def handle_event("command", %{"line" => line}, socket) do
    line = String.trim(line)

    if line == "" or is_nil(socket.assigns.session_pid) do
      {:noreply, socket}
    else
      pid = socket.assigns.session_pid
      # `home` is a browser-side convenience: teleport back to the room
      # you own (the one-way "out" exit means there's no walk-back path
      # yet). Rewrites to the engine's own @teleport verb.
      command = home_command(line, socket.assigns.home_room_uuid)
      :ok = PlayerSession.input_sync(pid, command)
      events = drain(pid)

      # ORDERING GATE (load-bearing): flush any pending ambient FIRST, so
      # ambient that arrived before this command lands in scrollback
      # BEFORE the command's own turn.
      {view, buffer} = SessionView.buffer_flush(socket.assigns.view, socket.assigns.ambient_buffer)
      view = SessionView.append_command_turn(view, line, Enum.join(events, "\n"))

      socket =
        socket
        |> assign(:view, view)
        |> assign(:ambient_buffer, buffer)
        |> update(:input_key, &(&1 + 1))

      {:noreply, socket}
    end
  catch
    :exit, _ ->
      view = SessionView.append_ambient_turn(socket.assigns.view, ["(session ended)"])
      {:noreply, assign(socket, :view, view)}
  end

  @impl true
  def handle_info(:enter, socket) do
    pid = socket.assigns.session_pid

    socket =
      if pid do
        # PlayerSession's own `:greet` (sent from its init) already renders
        # the spawn room. Just DRAIN it — a drain call is mailbox-ordered
        # AFTER `:greet` in the session, so it reliably captures that render
        # with no race. Sending our own "look" here rendered the room a
        # SECOND time (the double-description bug).
        #
        # The spawn-room render lands as the FIRST turn in the view-doc, a
        # command-style turn (cmd = "look", the implicit look a spawn is)
        # rather than an ambient turn — it reads cleanly as "here's what
        # you see" and keeps the ambient buffer reserved for genuinely
        # unprompted world events.
        case drain(pid) do
          [] ->
            socket

          events ->
            view = SessionView.append_command_turn(socket.assigns.view, "look", Enum.join(events, "\n"))
            assign(socket, :view, view)
        end
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_info(:tick, socket) do
    pid = socket.assigns.session_pid

    socket =
      if pid && Process.alive?(pid) do
        Process.send_after(self(), :tick, @tick_ms)

        # Ambient path (this poll IS the debounce window): route drained
        # events through the coalescing buffer so a burst since the last
        # tick lands as ONE ambient turn (M events -> 1 commit), never one
        # `append_ambient_turn` per event.
        buffer =
          Enum.reduce(drain(pid), socket.assigns.ambient_buffer, &SessionView.buffer_add(&2, &1))

        {view, buffer} = SessionView.buffer_flush(socket.assigns.view, buffer)

        socket
        |> assign(:view, view)
        |> assign(:ambient_buffer, buffer)
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, socket) do
    case socket.assigns[:session_pid] do
      pid when is_pid(pid) ->
        if Process.alive?(pid), do: PlayerSession.stop(pid)

      _ ->
        :ok
    end

    :ok
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-screen bg-base-100 items-center justify-center">
      <%= if @authed do %>
        <div class="flex flex-col h-full w-full max-w-3xl p-4">
          <h1 class="text-lg font-bold text-base-content/70 mb-2 font-mono">The Emberlight Vault</h1>

          <%= if @error do %>
            <div class="alert alert-error text-sm mb-2"><%= @error %></div>
          <% end %>

          <style>
            #mud-scrollback .turn { margin-bottom: 0.5rem; }
            #mud-scrollback .cmd { color: #9ca3af; }
            #mud-scrollback .cmd::before { content: "> "; }
            #mud-scrollback .out { white-space: pre-wrap; }
            #mud-scrollback .ambient .line { opacity: 0.85; }
          </style>

          <div
            id="mud-scrollback"
            class="flex-1 overflow-y-auto bg-black text-green-400 font-mono text-sm p-4 rounded whitespace-pre-wrap"
          >
            <%= for turn <- render_turns(@view) do %>
              <%= case turn do %>
                <% {:command, cmd, out} -> %>
                  <div class="turn command">
                    <div class="cmd"><%= cmd %></div>
                    <div class="out"><%= out %></div>
                  </div>
                <% {:ambient, lines} -> %>
                  <div class="turn ambient">
                    <%= for line <- lines do %>
                      <div class="line"><%= line %></div>
                    <% end %>
                  </div>
              <% end %>
            <% end %>
          </div>

          <form phx-submit="command" class="mt-2 flex gap-2">
            <input
              id={"mud-input-#{@input_key}"}
              type="text"
              name="line"
              autocomplete="off"
              autofocus
              disabled={is_nil(@session_pid)}
              placeholder="type a command…"
              class="input input-bordered flex-1 font-mono"
              phx-mounted={JS.focus()}
            />
            <button type="submit" class="btn btn-primary" disabled={is_nil(@session_pid)}>Send</button>
          </form>
        </div>
      <% else %>
        <div class="text-center">
          <h1 class="text-xl font-bold mb-2">You must be logged in to play.</h1>
          <p class="text-base-content/60 mb-4">
            Ask for an invite, or if you already have one, use your invite link.
          </p>
          <a href="/wiki" class="btn btn-primary btn-sm">Back to the wiki</a>
        </div>
      <% end %>
    </div>
    """
  end

  # --- helpers ---

  defp drain(pid) do
    PlayerSession.drain_buffer(pid) |> Enum.map(&render_line/1)
  catch
    :exit, _ -> ["(session ended)"]
  end

  defp render_line(line) when is_binary(line), do: line
  defp render_line(%{text: text}), do: text
  defp render_line(other), do: inspect(other)

  # SECURITY (CX-i9j3 increment 3): `SessionView.to_html/1` (and the
  # `Yelixer.Types.XMLElement.to_string/2` it's built on) does NOT
  # HTML-escape attribute values or text content — it's a raw XML
  # serializer, not a safe-render helper. Piping that string through
  # `Phoenix.HTML.raw/1` would let a player-typed command or game-output
  # line containing `<script>`/`&`/etc. inject live markup into every
  # other viewer's page (this is a public-IP live web app). So instead of
  # rendering the XHTML blob, we walk the view-doc's own `<scrollback>`
  # children with Yelixer's public accessors and hand each turn's text
  # fields to the `~H` template as ordinary interpolated values —
  # `Phoenix.HTML` auto-escapes those, so `<`, `>`, `&` in user input
  # render as literal text, never as tags. This still satisfies "render
  # FROM the committed view-doc" — it just doesn't trust `to_html`'s
  # unescaped serialization for a viewer-facing surface.
  defp render_turns(%SessionView{doc: doc, scrollback_name: scrollback_name}) do
    doc
    |> XMLElement.children(scrollback_name)
    |> Enum.map(fn {:element, "turn", turn_name} ->
      case XMLElement.get_attribute(doc, turn_name, "kind") do
        "ambient" ->
          lines =
            doc
            |> XMLElement.children(turn_name)
            |> Enum.map(&child_text(doc, &1))

          {:ambient, lines}

        _command_or_other ->
          [cmd_child, out_child] = XMLElement.children(doc, turn_name)
          {:command, child_text(doc, cmd_child), child_text(doc, out_child)}
      end
    end)
  end

  defp child_text(doc, {:element, _tag, elem_name}) do
    case XMLElement.children(doc, elem_name) do
      [{:text, text_name}] -> XMLText.to_string(doc, text_name)
      _ -> ""
    end
  end

  defp player_name(presence_path) when is_binary(presence_path) do
    String.replace_suffix(presence_path, ".usr", "")
  end

  defp home_command(line, home_room_uuid) when is_binary(home_room_uuid) do
    if String.downcase(line) == "home", do: "@teleport #{home_room_uuid}", else: line
  end

  defp home_command(line, _), do: line

  defp resolve_mud_root(store) do
    with {:ok, workspace_root} <- Commonplace.Workspace.root_uuid() do
      loader = fn uuid ->
        case DocBuilder.reconstruct_doc(store, uuid) do
          {:ok, doc} -> doc
          _ -> Yelixer.Doc.new()
        end
      end

      case Walk.resolve_path(workspace_root, "mud", loader) do
        {:ok, mud_root} -> {:ok, mud_root}
        {:error, _} -> {:ok, @fallback_mud_root}
      end
    end
  end
end
