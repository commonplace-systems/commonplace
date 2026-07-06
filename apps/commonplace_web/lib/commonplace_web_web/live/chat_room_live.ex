defmodule CommonplaceWebWeb.ChatRoomLive do
  @moduledoc """
  CX-71o3 / CX-lok1 (M3 sub-bead iv): chat-room LiveView, thinned to
  a generic wrapper around `CommonplaceWebWeb.ViewRenderer`.

  Per the M3 spec architectural anchor (views.md): view-XML IS the
  rendered semantic output. ChatRoomLive's job:

  1. Look up the room's `_view.xml` doc UUID via `Chat.Rooms.lookup`.
  2. Ensure the per-room `Chat.ChatViewComputeSupervisor` ViewCompute
     instance is running (lazy-start trigger from the LiveView path,
     mirroring how `Chat.Actions.commit_entry` triggers the onramp).
     Skipped for pre-M5 rooms that have no `_compute` doc — they fall
     back to whatever static `_view.xml` already holds.
  3. Subscribe to commits on the view doc (so the LiveView re-renders
     whenever ViewCompute writes new view-XML).
  4. Fetch view-XML content, pipe through `ViewRenderer.render_view/2`.
  5. Translate user interactions (`phx-click="view_action"` and
     `phx-submit="view_action"`) into substrate-resolved dispatch via
     `Commonplace.View.ArgResolver` + `CommonplaceWebWeb.ViewActions`.

  ## Re-render is roundtrip-driven, not optimistic

  After mount, `view_xml` is re-assigned in exactly one place: the
  `handle_info` for a `{:commit, …}` on the subscribed view doc
  (step 3). The action handler (step 5) dispatches and commits but does
  NOT push fresh view-XML into the socket itself — the new render
  arrives only once ViewCompute has recomputed `_view.xml` and that
  commit echoes back over the subscription. So a user's own action and
  a remote peer's both reach the screen through the *same* recompute
  path, and every connected tab converges to identical view-XML instead
  of each rendering an optimistic guess.

  Author identity is a placeholder until CX-88mw lands per-session
  signing infrastructure (the dispatch context carries a placeholder
  `signer_id`/`presence_path`, not a `signing_context` — see
  chat-room.md "v1: placeholder signers").
  """

  use CommonplaceWebWeb, :live_view

  alias Commonplace.Chat.{ChatViewComputeSupervisor, Rooms}
  alias Commonplace.Document.ContentType
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.DocBuilder
  alias Commonplace.View.ArgResolver
  alias Commonplace.Document.ViewXml
  alias Commonplace.ViewActionDispatch
  alias CommonplaceWebWeb.{ViewActions, ViewRenderer, WriteRateLimit}

  # Placeholder until CX-88mw substrate per-session key minting lands.
  @placeholder_signer_id "web-user@local"
  @placeholder_presence_path "web-user.usr"

  @impl true
  def mount(%{"room" => room_name}, _session, socket) do
    case lookup_workspace_root() do
      {:ok, root_uuid} ->
        case Rooms.lookup(root_uuid, room_name) do
          {:ok, room} ->
            if connected?(socket) do
              # Subscribe to view-doc commits so each ViewCompute write
              # re-renders the LiveView (cross-tab convergence + own-write
              # roundtrip both flow through the same path).
              Phoenix.PubSub.subscribe(Commonplace.PubSub, "commits:#{room.view_uuid}")
            end

            # Lazy-start the ViewCompute so this room's _view.xml stays
            # in sync with _messages. ensure_started is idempotent.
            # CX-h4mc (M5 sub-bead iv): :spec_uuid path now drives the
            # chat compute (ChatViewCompute Elixir module deleted; per-room
            # `_compute` doc IS the spec). For pre-M5 rooms missing
            # _compute, skip the start (display will fall back to whatever
            # `_view.xml` currently has — typically the static template).
            if room.compute_uuid do
              ChatViewComputeSupervisor.ensure_started(room_name,
                source_uuid: room.messages_uuid,
                target_uuid: room.view_uuid,
                spec_uuid: room.compute_uuid
              )
            end

            socket =
              socket
              |> assign(:room_name, room_name)
              |> assign(:room, room)
              |> assign(:view_xml, load_view_xml(room.view_uuid))
              |> assign(:page_title, "##{room_name}")
              |> assign(:not_found, false)

            {:ok, socket}

          {:error, :not_found} ->
            {:ok,
             socket
             |> assign(:room_name, room_name)
             |> assign(:not_found, true)
             |> assign(:page_title, "Room not found")}
        end

      {:error, _reason} ->
        {:ok,
         socket
         |> assign(:room_name, room_name)
         |> assign(:not_found, true)
         |> assign(:page_title, "No workspace")}
    end
  end

  # R10 (CX-tdkq.10): unsubscribe the room's view-doc commits topic on
  # teardown. Phoenix auto-drops the sub when the LiveView dies, but the
  # explicit pairing matches tree_live and closes the §5.7 edge-debt item.
  @impl true
  def terminate(_reason, socket) do
    case socket.assigns[:room] do
      %{view_uuid: view_uuid} when is_binary(view_uuid) ->
        Phoenix.PubSub.unsubscribe(Commonplace.PubSub, "commits:#{view_uuid}")

      _ ->
        :ok
    end

    :ok
  end

  # Unified handler for both phx-click (action without args) and
  # phx-submit (action with args). The dispatched form/button payload
  # is shaped the same way: `action` + optional `target` + the rest are
  # action args. Substrate ArgResolver fills resolution gaps.
  @impl true
  def handle_event("view_action", payload, socket) do
    case WriteRateLimit.check_and_record(self()) do
      :ok -> do_view_action(payload, socket)
      {:error, :rate_limited, _retry_after_ms} ->
        {:noreply, put_flash(socket, :error, "Too many edits — slow down")}
    end
  end

  defp do_view_action(payload, socket) do
    %{room: room, room_name: room_name} = socket.assigns

    action_name = payload["action"] || ""
    target = payload["target"]
    supplied_args = Map.drop(payload, ["action", "target"])

    view_path = "/chat/#{room_name}/_view.xml"

    resolver_context = %{
      view_path: view_path,
      presence_path: @placeholder_presence_path
    }

    with {:ok, view_node} <- ViewXml.parse(load_view_xml(room.view_uuid)),
         {:ok, resolved_args} <-
           ArgResolver.resolve_action(view_node, action_name, supplied_args, resolver_context) do
      context = %{
        view_path: view_path,
        view_uuid: room.view_uuid,
        target: target,
        args: resolved_args,
        signer_id: @placeholder_signer_id,
        source: "chat_room_live"
      }

      case ViewActions.dispatch(action_name, context, socket) do
        {:ok, updated_socket} ->
          {:noreply, updated_socket}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, reason)}
      end
    else
      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, "view_action #{action_name} failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_info({:commit, _doc_uuid, _commit_id, _metadata}, socket) do
    case socket.assigns[:room] do
      nil -> {:noreply, socket}
      room -> {:noreply, assign(socket, :view_xml, load_view_xml(room.view_uuid))}
    end
  end

  # --- Private ---

  defp lookup_workspace_root do
    Commonplace.Workspace.root_uuid()
  end

  defp load_view_xml(view_uuid) do
    case DocBuilder.reconstruct_snapshot(CommitStoreClient, view_uuid) do
      {:ok, doc} -> ContentType.get_content(doc) || ""
      :none -> ""
    end
  end

  # ViewActionDispatch is referenced via ViewActions.dispatch indirection
  # but keep the alias load-bearing so the moduledoc explanation is
  # accurate when readers grep.
  _ = ViewActionDispatch

  # --- Render ---

  @impl true
  def render(assigns) do
    ~H"""
    <div class="cp-chat-room max-w-3xl mx-auto p-4">
      <%= if @not_found do %>
        <div class="alert alert-warning">
          <h2 class="text-lg font-bold">Chat room not found</h2>
          <p>No room named <code>{@room_name}</code> exists at <code>/chat/{@room_name}/</code>.</p>
        </div>
      <% else %>
        {ViewRenderer.render_view(@view_xml, "/chat/" <> @room_name)}
      <% end %>
    </div>
    """
  end
end
