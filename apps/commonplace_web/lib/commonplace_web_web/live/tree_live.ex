defmodule CommonplaceWebWeb.TreeLive do
  @moduledoc """
  LiveView for browsing the commonplace document tree.

  Shows the directory listing on the left, document content on the right.
  Subscribes to PubSub blue channel for real-time content updates.
  """

  use CommonplaceWebWeb, :live_view

  alias Commonplace.Tree.Schema
  alias Commonplace.Store.CommitStore
  alias Commonplace.Dataflow.PubSub, as: CPPubSub

  @impl true
  def mount(_params, _session, socket) do
    data_dir = Application.get_env(:commonplace, :data_dir, "data")
    root = read_root_uuid(data_dir)

    socket =
      socket
      |> assign(:root_uuid, root)
      |> assign(:current_path, "")
      |> assign(:entries, list_entries(root))
      |> assign(:selected_name, nil)
      |> assign(:selected_uuid, nil)

    {:ok, socket}
  end

  @impl true
  def handle_params(%{"path" => path}, _uri, socket) do
    path = Enum.join(path, "/")

    # Resolve the path to find the directory UUID
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

  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("select", %{"name" => name}, socket) do
    root_doc = load_schema(current_dir_uuid(socket))

    case Schema.get_entry(root_doc, name) do
      {:ok, entry} when entry.type == :doc ->
        # Unsubscribe from old doc
        if socket.assigns.selected_uuid do
          CPPubSub.unsubscribe_blue(socket.assigns.selected_uuid)
        end

        # Subscribe to new doc for live updates
        CPPubSub.subscribe_blue(entry.node_id)

        # Push Yjs binary state to browser
        socket =
          socket
          |> assign(:selected_name, name)
          |> assign(:selected_uuid, entry.node_id)
          |> push_yjs_init(entry.node_id)

        {:noreply, socket}

      {:ok, entry} when entry.type == :dir ->
        # Navigate into directory
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
  def handle_info({_topic, _update}, socket) do
    # Blue channel update — push new Yjs state to browser
    if socket.assigns.selected_uuid do
      {:noreply, push_yjs_init(socket, socket.assigns.selected_uuid)}
    else
      {:noreply, socket}
    end
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
            /<%= @current_path %>
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
                  📁 <%= entry.name %>/
                <% else %>
                  📄 <%= entry.name %>
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
          <h1 class="text-2xl font-bold mb-4"><%= @selected_name %></h1>
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

  defp push_yjs_init(socket, doc_uuid) do
    case CommitStore.latest_commit(doc_uuid) do
      {:ok, commit} ->
        # Send the raw Yjs update binary as base64
        encoded = Base.encode64(commit.update)
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
    segments = String.split(path, "/")

    Enum.reduce_while(segments, root_uuid, fn segment, current_uuid ->
      schema = load_schema(current_uuid)

      case Schema.get_entry(schema, segment) do
        {:ok, %{type: :dir, node_id: uuid}} -> {:cont, uuid}
        _ -> {:halt, nil}
      end
    end)
  end

  defp list_entries(nil), do: []

  defp list_entries(uuid) do
    schema = load_schema(uuid)

    Schema.list_entries(schema)
    |> Enum.reject(&String.starts_with?(&1.name, "__"))
    |> Enum.sort_by(fn e -> {if(e.type == :dir, do: 0, else: 1), e.name} end)
  end

  defp load_schema(uuid) do
    case CommitStore.latest_commit(uuid) do
      {:ok, commit} ->
        doc = Schema.new_schema()
        {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)
        doc

      :none ->
        Schema.new_schema()
    end
  end

  defp read_root_uuid(data_dir) do
    case File.read(Path.join(data_dir, "root")) do
      {:ok, uuid} -> String.trim(uuid)
      {:error, _} -> nil
    end
  end
end
