defmodule CommonplaceWebWeb.ChatRoomLive do
  @moduledoc """
  CX-71o3 (C1 of CX-p2qp): chat-room LiveView chrome.

  Per chat-room.md (commit bb83a1b on commonplace-plan/main), MVP uses
  the (β) pragmatic path — a chat-specific LiveView module that loads
  `_messages` directly and renders `Commonplace.Chat.Messages.materialize/1`
  output via HEEX, sidestepping the generic ViewRenderer's
  CRDT-collection-source gap. The substrate followup that introduces a
  generic CRDT-collection renderer (filed in chat-room.md "Future
  hooks") would let this module's render path swap to that mechanism
  without changing the action handlers.

  ## Mount + lookup

  URL is `/chat/:room`. `mount/3` walks the workspace root schema for
  `/chat/{room}/_messages` via `Commonplace.Chat.Rooms.lookup/3`. If
  the room doesn't exist, renders a "room not found" state. (Room
  creation is `Commonplace.Chat.Rooms.create/3` — a separate flow;
  this view doesn't auto-create on first visit.)

  ## Live updates: roundtrip + re-materialize

  Per the spec scope guardrail (msg #3055): roundtrip-only updates, no
  optimistic UI. `handle_event("post_message", ...)` calls
  `Chat.Actions.post_message/3` synchronously and waits for the commit.
  The same commit hits the `commits:{messages_uuid}` PubSub topic; our
  `handle_info({:commit, ...})` re-fetches + re-materializes + re-
  renders. Slightly redundant for the local poster (we'll re-render
  what we just rendered) but ensures cross-tab convergence is a
  free-by-construction consequence of the same path.

  Author identity is a placeholder until CX-88mw lands per-session
  signing infrastructure (see chat-room.md "v1: placeholder signers").
  """

  use CommonplaceWebWeb, :live_view

  alias Commonplace.Chat.{Actions, Messages, Rooms}
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.DocBuilder

  # Placeholder author identity (CX-88mw substrate followup will populate
  # these from the session's bound key + presence record).
  @placeholder_signer_id "web-user@local"
  @placeholder_author_path "web-user.usr"

  @impl true
  def mount(%{"room" => room_name}, _session, socket) do
    case lookup_workspace_root() do
      {:ok, root_uuid} ->
        case Rooms.lookup(root_uuid, room_name) do
          {:ok, room} ->
            if connected?(socket) do
              Phoenix.PubSub.subscribe(Commonplace.PubSub, "commits:#{room.messages_uuid}")
            end

            socket =
              socket
              |> assign(:room_name, room_name)
              |> assign(:room, room)
              |> assign(:messages, load_messages(room.messages_uuid))
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

  @impl true
  def handle_event("post_message", %{"text" => text}, socket) when is_binary(text) do
    # CX-00ze: trim before checking empty so whitespace-only submits
    # ("   " or "\t\n") are no-ops, matching the empty-string case.
    trimmed = String.trim(text)

    if trimmed == "" do
      {:noreply, socket}
    else
      %{room: room, room_name: room_name} = socket.assigns

      Actions.post_message(room.messages_uuid, trimmed,
        room: room_name,
        signer_id: @placeholder_signer_id,
        author_path: @placeholder_author_path,
        messages_log_uuid: room.log_uuid
      )

      # The commits PubSub topic will re-trigger handle_info; we don't
      # need to re-render here.
      {:noreply, socket}
    end
  end

  def handle_event("post_message", _params, socket) do
    # No "text" key in payload — ignore.
    {:noreply, socket}
  end

  @impl true
  def handle_info({:commit, _doc_uuid, _commit_id, _metadata}, socket) do
    # Re-materialize from the latest commit. Per design (msg #3055): no
    # intermediate state — re-fetch + re-render is the simplest correct
    # shape and free cross-tab convergence as a side effect.
    case socket.assigns[:room] do
      nil ->
        {:noreply, socket}

      room ->
        {:noreply, assign(socket, :messages, load_messages(room.messages_uuid))}
    end
  end

  # --- Private ---

  defp lookup_workspace_root do
    Commonplace.Workspace.root_uuid()
  end

  defp load_messages(messages_uuid) do
    case DocBuilder.reconstruct_snapshot(CommitStoreClient, messages_uuid) do
      {:ok, doc} -> Messages.materialize(doc)
      :none -> []
    end
  end

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
        <h1 class="text-2xl font-bold mb-4">#{@room_name}</h1>

        <ul id="messages" class="space-y-2 mb-4">
          <%= for message <- @messages do %>
            <li
              id={"message-" <> message["id"]}
              class={[
                "p-2 rounded",
                if(message["deleted?"], do: "bg-base-200 italic opacity-60", else: "bg-base-100")
              ]}
            >
              <%= if message["deleted?"] do %>
                <em>[deleted]</em>
              <% else %>
                <div class="text-sm text-base-content/60">
                  <span class="font-semibold">{message["author_path"]}</span>
                  <%= if message["edited?"] do %>
                    <span class="text-xs">(edited)</span>
                  <% end %>
                </div>
                <div class="message-text">{message["text"]}</div>
              <% end %>
            </li>
          <% end %>
        </ul>

        <form
          phx-submit="post_message"
          id="composer"
          class="flex gap-2"
        >
          <input
            type="text"
            name="text"
            placeholder="Type a message..."
            class="input input-bordered flex-1"
            autocomplete="off"
          />
          <button type="submit" class="btn btn-primary">Post</button>
        </form>
      <% end %>
    </div>
    """
  end
end
