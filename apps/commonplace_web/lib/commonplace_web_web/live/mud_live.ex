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

  alias Commonplace.MUD.{Citizenship, PlayerSession}
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.{DocBuilder, Walk}
  alias CommonplaceWebWeb.SessionIdentity

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
         |> assign(:scrollback, [])
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

    socket =
      socket
      |> assign(:authed, true)
      |> assign(:error, nil)
      |> assign(:scrollback, [])
      |> assign(:session_pid, nil)
      |> assign(:input_key, 0)
      |> assign(:home_room_uuid, nil)
      |> assign(:player_name, name)

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
            socket = assign(socket, :home_room_uuid, home_room_uuid)

            socket =
              if connected?(socket) do
                start_session(socket, name, mud_root, store, resolved, cert_cids, home_room_uuid)
              else
                socket
              end

            {:ok, socket}

          {:error, reason} ->
            {:ok, assign(socket, :error, "Could not provision your MUD home: #{inspect(reason)}")}
        end

      {:error, reason} ->
        {:ok, assign(socket, :error, "The MUD world isn't available right now (#{inspect(reason)}).")}
    end
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

      socket =
        socket
        |> append_scrollback(["> " <> line])
        |> append_scrollback(events)
        |> update(:input_key, &(&1 + 1))

      {:noreply, socket}
    end
  catch
    :exit, _ ->
      {:noreply, append_scrollback(socket, ["(session ended)"])}
  end

  @impl true
  def handle_info(:enter, socket) do
    pid = socket.assigns.session_pid

    socket =
      if pid do
        :ok = PlayerSession.input_sync(pid, "look")
        append_scrollback(socket, drain(pid))
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
        append_scrollback(socket, drain(pid))
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

          <div
            id="mud-scrollback"
            class="flex-1 overflow-y-auto bg-black text-green-400 font-mono text-sm p-4 rounded whitespace-pre-wrap"
          >
            <%= for line <- @scrollback do %>
              <div><%= line %></div>
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

  defp append_scrollback(socket, []), do: socket

  defp append_scrollback(socket, lines) when is_list(lines) do
    assign(socket, :scrollback, socket.assigns.scrollback ++ lines)
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
