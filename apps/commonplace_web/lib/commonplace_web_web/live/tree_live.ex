defmodule CommonplaceWebWeb.TreeLive do
  @moduledoc """
  LiveView for browsing the commonplace document tree.

  Directory listing on the left, the selected document's content on the
  right. Selecting a document subscribes to *that doc's* blue channel so
  its content updates live; changing selection (and `terminate/2`)
  unsubscribes the previous one.

  Side effect: while a connected session is open it registers a
  `browser-<id>.usr` presence actor under the workspace root (with a
  15s heartbeat), so an open tree-browser tab is visible to others as a
  live `.usr` presence. The actor is stopped on `terminate/2`.

  Author identity resolves once per mount via
  `CommonplaceWebWeb.SessionIdentity.resolve/1` (CX-nn4y, following the
  CX-qat5.2 pattern `ChatRoomLive` established): a logged-in session's
  `signing_context` reaches the `yjs_edit` save-path commit. There is NO
  reconstruction-client_id seam to thread a session hand into here — the
  saved update's Yjs client_id is already baked in by the browser's own
  Y.Doc (assigned by the Yjs JS library at document-load time), not
  chosen server-side, same residual noted in `WikiLive`. An anonymous
  session (no cookie, or one that no longer resolves) falls back to
  exactly today's behavior: no signing_context.
  """

  use CommonplaceWebWeb, :live_view

  alias Commonplace.Tree.{Schema, Walk, DocBuilder}
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Dataflow.PubSub, as: CPPubSub
  alias Commonplace.Presence
  alias CommonplaceWebWeb.{SessionIdentity, WriteRateLimit}

  @impl true
  def mount(_params, session, socket) do
    # CX-qat5.2 §2.3 discipline (per CX-nn4y): resolve identity ONCE
    # here, thread by argument — no downstream re-derivation.
    identity = SessionIdentity.resolve(session)

    data_dir = Application.get_env(:commonplace, :data_dir, "data")
    root = read_root_uuid(data_dir)

    # Start presence for this browser session
    presence_pid =
      if connected?(socket) and root do
        session_id = socket.id |> String.slice(0, 6)

        {:ok, pid} =
          Presence.Server.start_link(
            name: "browser-#{session_id}",
            type: :usr,
            dir_uuid: root,
            store: CommitStoreClient,
            heartbeat_interval: 15_000
          )

        pid
      else
        nil
      end

    socket =
      socket
      |> assign(:root_uuid, root)
      |> assign(:current_path, "")
      |> assign(:entries, list_entries(root))
      |> assign(:selected_name, nil)
      |> assign(:selected_uuid, nil)
      |> assign(:presence_pid, presence_pid)
      |> assign(:identity, identity)

    {:ok, socket}
  end

  @impl true
  def terminate(_reason, socket) do
    if socket.assigns[:selected_uuid] do
      CPPubSub.unsubscribe_blue(socket.assigns.selected_uuid)
    end

    if socket.assigns[:presence_pid] && Process.alive?(socket.assigns.presence_pid) do
      GenServer.stop(socket.assigns.presence_pid)
    end

    :ok
  end

  @impl true
  def handle_params(%{"path" => path}, _uri, socket) do
    path = Enum.join(path, "/")

    if String.contains?(path, "..") do
      {:noreply, push_navigate(socket, to: ~p"/tree")}
    else
      dir_uuid =
        if path == "" do
          socket.assigns.root_uuid
        else
          resolve_dir(socket.assigns.root_uuid, path)
        end

      entries = if dir_uuid, do: list_entries(dir_uuid), else: []

      socket =
        socket
        |> assign(:current_path, path)
        |> assign(:entries, entries)
        |> assign(:selected_name, nil)
        |> assign(:selected_uuid, nil)

      {:noreply, socket}
    end
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("select", %{"name" => name}, socket) do
    root_doc = load_schema(current_dir_uuid(socket))

    case Schema.get_entry(root_doc, name) do
      {:ok, entry} when entry.type == :doc ->
        if socket.assigns.selected_uuid do
          CPPubSub.unsubscribe_blue(socket.assigns.selected_uuid)
        end

        CPPubSub.subscribe_blue(entry.node_id)

        socket =
          socket
          |> assign(:selected_name, name)
          |> assign(:selected_uuid, entry.node_id)
          |> push_yjs_init(entry.node_id)

        {:noreply, socket}

      {:ok, entry} when entry.type == :dir ->
        new_path =
          if socket.assigns.current_path == "" do
            name
          else
            socket.assigns.current_path <> "/" <> name
          end

        {:noreply, push_patch(socket, to: ~p"/tree/#{String.split(new_path, "/")}")}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("navigate_up", _params, socket) do
    path = socket.assigns.current_path

    new_path =
      case String.split(path, "/") do
        [""] -> ""
        parts -> parts |> Enum.drop(-1) |> Enum.join("/")
      end

    if new_path == "" do
      {:noreply, push_patch(socket, to: ~p"/tree")}
    else
      {:noreply, push_patch(socket, to: ~p"/tree/#{String.split(new_path, "/")}")}
    end
  end

  @impl true
  def handle_event("yjs_edit", %{"update" => encoded}, socket) do
    case WriteRateLimit.check_and_record(self()) do
      :ok ->
        with uuid when not is_nil(uuid) <- socket.assigns.selected_uuid,
             {:ok, update} <- Base.decode64(encoded) do
          commit =
            CommitStoreClient.create_chained_commit(
              CommitStoreClient,
              uuid,
              update,
              %{},
              commit_opts(socket)
            )

          case commit do
            %{id: _} ->
              CPPubSub.broadcast_blue(uuid, update)
              {:noreply, socket}

            {:error, {:trust_rejected, _reason}} ->
              {:noreply, put_flash(socket, :error, "You don't have permission to edit this")}

            _ ->
              {:noreply, put_flash(socket, :error, "Failed to save")}
          end
        else
          _ ->
            {:noreply, put_flash(socket, :error, "Invalid edit data")}
        end

      {:error, :rate_limited, _retry_after_ms} ->
        {:noreply, put_flash(socket, :error, "Too many edits — slow down")}
    end
  end

  @impl true
  def handle_event("yjs_request_init", _params, socket) do
    {:noreply, push_yjs_init(socket, socket.assigns.selected_uuid)}
  end

  @impl true
  def handle_info({:commit, _uuid, _commit_id, _meta}, socket) do
    if socket.assigns.selected_uuid do
      {:noreply, push_yjs_init(socket, socket.assigns.selected_uuid)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-screen">
      <!-- Sidebar: directory listing -->
      <div class="w-64 border-r bg-gray-50 p-4 overflow-y-auto">
        <h2 class="text-lg font-bold mb-2">
          <%= if @current_path == "" do %>
            /
          <% else %>
            /{@current_path}
          <% end %>
        </h2>

        <%= if @current_path != "" do %>
          <button phx-click="navigate_up" class="text-blue-600 hover:underline mb-2 block">
            ../ (up)
          </button>
        <% end %>

        <ul class="space-y-1">
          <%= for entry <- @entries do %>
            <li>
              <button
                phx-click="select"
                phx-value-name={entry.name}
                class={"block w-full text-left px-2 py-1 rounded #{if entry.name == @selected_name, do: "bg-blue-100 font-bold", else: "hover:bg-gray-100"}"}
              >
                <%= if entry.type == :dir do %>
                  📁 {entry.name}/
                <% else %>
                  📄 {entry.name}
                <% end %>
              </button>
            </li>
          <% end %>
        </ul>

        <%= if @entries == [] do %>
          <p class="text-gray-400 italic">Empty directory</p>
        <% end %>
      </div>
      
    <!-- Main content area -->
      <div class="flex-1 p-6 overflow-y-auto">
        <%= if @selected_name do %>
          <h1 class="text-2xl font-bold mb-4">{@selected_name}</h1>
          <div id="yjs-content" phx-hook="YjsHook" phx-update="ignore">
            <p class="text-gray-400">Loading document...</p>
          </div>
        <% else %>
          <p class="text-gray-400 text-lg">Select a document to view</p>
        <% end %>
      </div>
    </div>
    """
  end

  # Private helpers

  defp push_yjs_init(socket, nil), do: socket

  defp push_yjs_init(socket, doc_uuid) do
    case DocBuilder.reconstruct_doc(CommitStoreClient, doc_uuid) do
      {:ok, doc} ->
        update = Yelixer.Encoding.encode_update(doc)
        encoded = Base.encode64(update)
        push_event(socket, "yjs_init", %{update: encoded})

      :none ->
        socket
    end
  end

  defp current_dir_uuid(socket) do
    if socket.assigns.current_path == "" do
      socket.assigns.root_uuid
    else
      resolve_dir(socket.assigns.root_uuid, socket.assigns.current_path) ||
        socket.assigns.root_uuid
    end
  end

  defp resolve_dir(root_uuid, path) do
    loader = &load_schema/1

    case Walk.resolve_path(root_uuid, path, loader) do
      {:ok, uuid} -> uuid
      {:error, _} -> nil
    end
  end

  defp list_entries(nil), do: []

  defp list_entries(uuid) do
    schema = load_schema(uuid)

    Schema.list_entries(schema)
    |> Enum.reject(&String.starts_with?(&1.name, "__"))
    |> Enum.sort_by(fn e -> {if(e.type == :dir, do: 0, else: 1), e.name} end)
  end

  defp load_schema(uuid) do
    case DocBuilder.reconstruct_snapshot(CommitStoreClient, uuid) do
      {:ok, doc} -> doc
      :none -> Schema.new_schema()
    end
  end

  defp read_root_uuid(data_dir) do
    case File.read(Path.join(data_dir, "root")) do
      {:ok, uuid} -> String.trim(uuid)
      {:error, _} -> nil
    end
  end

  # CX-nn4y: commit opts for the current socket's resolved identity —
  # just `:signing_context` (no `:client_id` seam here; see the
  # moduledoc note on the browser-Yjs-owned client_id).
  defp commit_opts(socket) do
    case socket.assigns[:identity] do
      {:ok, %{signing_context: ctx}} -> [signing_context: ctx]
      _ -> []
    end
  end
end
