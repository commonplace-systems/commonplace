defmodule CommonplaceWebWeb.OutlineLive do
  @moduledoc """
  Workflowy-style outliner LiveView (CX-k8tn, outliner.md §5).

  Mounts `/outline/:name`, resolves the `_outline` doc by walking the
  workspace schema (`Outline.lookup/3` — the same live binding chat
  uses), subscribes to its commit topic, and renders the nested tree
  reconstructed by `Outline.Tree` (pure, cheap — "invalidate" =
  "recompute from the new doc state").

  Keybinds call the `Commonplace.Outline.*` mutation functions DIRECTLY
  (§5: the LiveView does not round-trip through `_view.xml`; that file
  declares the same actions for the MCP/agent surface — one mutation
  implementation, two entry points). Known MVP wart: browser `Tab`
  moves focus as well as indenting (no JS hook yet) — the per-item
  buttons cover every operation regardless.
  """
  use CommonplaceWebWeb, :live_view

  alias Commonplace.Outline
  alias Commonplace.Outline.Tree

  @impl true
  def mount(%{"name" => name}, _session, socket) do
    with {:ok, root} <- Commonplace.Workspace.root_uuid(),
         {:ok, uuid} <- Outline.lookup(name, root) do
      if connected?(socket) do
        Phoenix.PubSub.subscribe(Commonplace.PubSub, "commits:#{uuid}")
      end

      {:ok,
       socket
       |> assign(name: name, uuid: uuid, not_found: false, page_title: "outline: #{name}")
       |> reload()}
    else
      _ ->
        {:ok, assign(socket, name: name, uuid: nil, not_found: true, forest: [])}
    end
  end

  @impl true
  def handle_info({:commit, _doc, _commit_id, _meta}, socket) do
    {:noreply, reload(socket)}
  end

  @impl true
  def handle_event("new_item", params, socket) do
    attrs =
      case params["after"] do
        nil -> %{text: ""}
        after_id -> %{text: "", parent: params["parent"] || "", after: after_id}
      end

    {:ok, _id} = Outline.add_item(store(), socket.assigns.uuid, attrs)
    {:noreply, reload(socket)}
  end

  def handle_event("set_text", %{"id" => id, "value" => value}, socket) do
    :ok = Outline.set_text(store(), socket.assigns.uuid, id, value)
    {:noreply, reload(socket)}
  end

  def handle_event("indent", %{"id" => id}, socket) do
    _ = Outline.indent(store(), socket.assigns.uuid, id)
    {:noreply, reload(socket)}
  end

  def handle_event("outdent", %{"id" => id}, socket) do
    _ = Outline.outdent(store(), socket.assigns.uuid, id)
    {:noreply, reload(socket)}
  end

  def handle_event("move_up", %{"id" => id}, socket) do
    _ = Outline.reorder(store(), socket.assigns.uuid, id, :up)
    {:noreply, reload(socket)}
  end

  def handle_event("move_down", %{"id" => id}, socket) do
    _ = Outline.reorder(store(), socket.assigns.uuid, id, :down)
    {:noreply, reload(socket)}
  end

  def handle_event("toggle_collapse", %{"id" => id}, socket) do
    item = Enum.find(Outline.items(store(), socket.assigns.uuid), &(&1.id == id))
    :ok = Outline.set_collapsed(store(), socket.assigns.uuid, id, not item.collapsed)
    {:noreply, reload(socket)}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    :ok = Outline.delete_item(store(), socket.assigns.uuid, id)
    {:noreply, reload(socket)}
  end

  # Keyboard dispatch from the bullet inputs (outliner.md §3 keybinds).
  def handle_event("keydown", %{"key" => key, "id" => id} = params, socket) do
    case {key, params["shiftKey"], params["altKey"]} do
      {"Enter", _, _} ->
        item = Enum.find(Outline.items(store(), socket.assigns.uuid), &(&1.id == id))
        handle_event("new_item", %{"after" => id, "parent" => item.parent}, socket)

      {"Tab", true, _} -> handle_event("outdent", %{"id" => id}, socket)
      {"Tab", _, _} -> handle_event("indent", %{"id" => id}, socket)
      {"ArrowUp", _, true} -> handle_event("move_up", %{"id" => id}, socket)
      {"ArrowDown", _, true} -> handle_event("move_down", %{"id" => id}, socket)
      {".", _, _} when is_map_key(params, "ctrlKey") ->
        handle_event("toggle_collapse", %{"id" => id}, socket)

      _ ->
        {:noreply, socket}
    end
  end

  defp reload(%{assigns: %{uuid: nil}} = socket), do: socket

  defp reload(socket) do
    forest = store() |> Outline.items(socket.assigns.uuid) |> Tree.reconstruct()
    assign(socket, :forest, forest)
  end

  defp store, do: Commonplace.Store.CommitStoreClient

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-6 max-w-3xl mx-auto">
      <%= if @not_found do %>
        <p class="text-error">No outline named “{@name}”.</p>
      <% else %>
        <h1 class="text-xl font-bold mb-4">{@name}</h1>
        <ul class="outline-root">
          <.outline_node :for={n <- @forest} node={n} />
        </ul>
        <button class="btn btn-sm mt-4" phx-click="new_item">+ item</button>
      <% end %>
    </div>
    """
  end

  attr :node, :map, required: true

  defp outline_node(assigns) do
    ~H"""
    <li class="ml-4" data-item-id={@node.item.id}>
      <div class="flex items-center gap-1 group">
        <button
          :if={@node.children != []}
          phx-click="toggle_collapse"
          phx-value-id={@node.item.id}
          class="w-4 text-xs opacity-60"
        >{if @node.item.collapsed, do: "▸", else: "▾"}</button>
        <span :if={@node.children == []} class="w-4 text-xs opacity-40">•</span>
        <input
          class="bullet-input bg-transparent flex-1 outline-none"
          value={@node.item.text}
          phx-blur="set_text"
          phx-keydown="keydown"
          phx-value-id={@node.item.id}
        />
        <span class="hidden group-hover:inline-flex gap-1 text-xs">
          <button phx-click="indent" phx-value-id={@node.item.id} title="indent">→</button>
          <button phx-click="outdent" phx-value-id={@node.item.id} title="outdent">←</button>
          <button phx-click="move_up" phx-value-id={@node.item.id} title="up">↑</button>
          <button phx-click="move_down" phx-value-id={@node.item.id} title="down">↓</button>
          <button phx-click="delete" phx-value-id={@node.item.id} title="delete">✕</button>
        </span>
      </div>
      <ul :if={@node.children != [] and not @node.item.collapsed}>
        <.outline_node :for={child <- @node.children} node={child} />
      </ul>
    </li>
    """
  end
end
