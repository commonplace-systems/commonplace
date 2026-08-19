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

  Author identity resolves once per mount via
  `CommonplaceWebWeb.SessionIdentity.resolve/1` (CX-nn4y, following the
  CX-qat5.2 pattern `ChatRoomLive` established): a logged-in session's
  stable W4 session hand threads into every `Commonplace.Outline.*` call
  as `opts[:client_id]` (wins over the shared `WriterHand.for_doc/1`
  funnel hand), and `opts[:signing_context]` reaches the commit. This
  closes the residual hazard where two concurrent anonymous/funnel
  writers sharing one per-doc hand can mint colliding (client_id, clock)
  ops from the same reconstructed base — the loser's write silently
  drops as a "duplicate" on replay. An anonymous session (no cookie, or
  one that no longer resolves) falls back to exactly today's behavior:
  no client_id override, no signing_context.
  """
  use CommonplaceWebWeb, :live_view

  alias Commonplace.Outline
  alias Commonplace.Outline.Tree
  alias CommonplaceWebWeb.{SessionIdentity, WriteRateLimit}

  @impl true
  def mount(%{"name" => name}, session, socket) do
    # CX-qat5.2 §2.3 discipline (per CX-nn4y): resolve identity ONCE
    # here, thread by argument — no downstream re-derivation.
    identity = SessionIdentity.resolve(session)

    with {:ok, root} <- Commonplace.Workspace.root_uuid(),
         {:ok, uuid} <- Outline.lookup(name, root) do
      if connected?(socket) do
        Phoenix.PubSub.subscribe(Commonplace.PubSub, "commits:#{uuid}")
      end

      {:ok,
       socket
       |> assign(
         name: name,
         uuid: uuid,
         not_found: false,
         page_title: "outline: #{name}",
         identity: identity
       )
       |> reload()}
    else
      _ ->
        {:ok,
         assign(socket,
           name: name,
           uuid: nil,
           not_found: true,
           forest: [],
           identity: identity
         )}
    end
  end

  @impl true
  def handle_info({:commit, _doc, _commit_id, _meta}, socket) do
    {:noreply, reload(socket)}
  end

  @impl true
  def handle_event("new_item", params, socket) do
    write_gate(socket, fn ->
      attrs =
        case params["after"] do
          nil -> %{text: ""}
          after_id -> %{text: "", parent: params["parent"] || "", after: after_id}
        end

      # CX-qat5.3: a local-write-gate rejection surfaces as
      # `{:error, {:trust_rejected, _}}` here instead of `{:ok, id}` —
      # flash it rather than crashing the LiveView on the old rigid
      # `{:ok, _id} = ...` match.
      case Outline.add_item(store(), socket.assigns.uuid, attrs, mutate_opts(socket)) do
        {:ok, _id} -> {:noreply, reload(socket)}
        {:error, _reason} -> {:noreply, permission_denied_flash(socket)}
      end
    end)
  end

  def handle_event("set_text", %{"id" => id, "value" => value}, socket) do
    write_gate(socket, fn ->
      case Outline.set_text(store(), socket.assigns.uuid, id, value, mutate_opts(socket)) do
        :ok -> {:noreply, reload(socket)}
        {:error, _reason} -> {:noreply, permission_denied_flash(socket)}
      end
    end)
  end

  def handle_event("indent", %{"id" => id}, socket) do
    write_gate(socket, fn ->
      {:noreply,
       apply_or_flash(
         socket,
         Outline.indent(store(), socket.assigns.uuid, id, mutate_opts(socket))
       )}
    end)
  end

  def handle_event("outdent", %{"id" => id}, socket) do
    write_gate(socket, fn ->
      {:noreply,
       apply_or_flash(
         socket,
         Outline.outdent(store(), socket.assigns.uuid, id, mutate_opts(socket))
       )}
    end)
  end

  def handle_event("move_up", %{"id" => id}, socket) do
    write_gate(socket, fn ->
      {:noreply,
       apply_or_flash(
         socket,
         Outline.reorder(store(), socket.assigns.uuid, id, :up, mutate_opts(socket))
       )}
    end)
  end

  def handle_event("move_down", %{"id" => id}, socket) do
    write_gate(socket, fn ->
      {:noreply,
       apply_or_flash(
         socket,
         Outline.reorder(store(), socket.assigns.uuid, id, :down, mutate_opts(socket))
       )}
    end)
  end

  def handle_event("toggle_collapse", %{"id" => id}, socket) do
    write_gate(socket, fn ->
      item = Enum.find(Outline.items(store(), socket.assigns.uuid), &(&1.id == id))

      case Outline.set_collapsed(
             store(),
             socket.assigns.uuid,
             id,
             not item.collapsed,
             mutate_opts(socket)
           ) do
        :ok -> {:noreply, reload(socket)}
        {:error, _reason} -> {:noreply, permission_denied_flash(socket)}
      end
    end)
  end

  def handle_event("delete", %{"id" => id}, socket) do
    write_gate(socket, fn ->
      case Outline.delete_item(store(), socket.assigns.uuid, id, mutate_opts(socket)) do
        :ok -> {:noreply, reload(socket)}
        {:error, _reason} -> {:noreply, permission_denied_flash(socket)}
      end
    end)
  end

  # Keyboard dispatch from the bullet inputs (outliner.md §3 keybinds).
  def handle_event("keydown", %{"key" => key, "id" => id} = params, socket) do
    case {key, params["shiftKey"], params["altKey"]} do
      {"Enter", _, _} ->
        item = Enum.find(Outline.items(store(), socket.assigns.uuid), &(&1.id == id))
        handle_event("new_item", %{"after" => id, "parent" => item.parent}, socket)

      {"Tab", true, _} ->
        handle_event("outdent", %{"id" => id}, socket)

      {"Tab", _, _} ->
        handle_event("indent", %{"id" => id}, socket)

      {"ArrowUp", _, true} ->
        handle_event("move_up", %{"id" => id}, socket)

      {"ArrowDown", _, true} ->
        handle_event("move_down", %{"id" => id}, socket)

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

  # CX-nn4y: mutation opts for the current socket's resolved identity —
  # `:client_id` (the session hand, wins over `Outline.mutate/4`'s
  # `WriterHand.for_doc/1` fallback) and `:signing_context`. Anonymous
  # sessions get `[]`, matching pre-CX-nn4y behavior exactly.
  defp mutate_opts(socket) do
    case socket.assigns[:identity] do
      {:ok, %{signing_context: ctx, hand: hand}} ->
        [signing_context: ctx, client_id: hand]

      _ ->
        []
    end
  end

  # CX-qat5.6: gate every mutating handler behind the per-connection
  # write rate limiter before it touches the store. `self()` (this
  # LiveView process) is the connection key — identity-independent,
  # stable for the socket's lifetime, and naturally reclaimed by the
  # limiter's sliding window once the connection goes quiet.
  defp write_gate(socket, fun) do
    case WriteRateLimit.check_and_record(self()) do
      :ok ->
        fun.()

      {:error, :rate_limited, _retry_after_ms} ->
        {:noreply, put_flash(socket, :error, "Too many edits — slow down")}
    end
  end

  # CX-qat5.3: `Commonplace.Outline.*` mutations propagate the
  # local-write gate's `{:error, {:trust_rejected, reason}}` instead of
  # swallowing it (see `Outline.mutate/4`) — under the default
  # permissive config this branch never fires; a strict/enforce
  # workspace surfaces it here instead of crashing the LiveView on a
  # rigid `:ok = ...` / `{:ok, _} = ...` match.
  defp permission_denied_flash(socket) do
    put_flash(socket, :error, "You don't have permission to edit this")
  end

  # indent/outdent/reorder can ALSO fail with benign structural
  # no-ops (`:no_preceding_sibling`, `:at_top_level`, `:at_edge` — "can't
  # move further", not a failure worth flashing, pre-existing UX). Only
  # a local-write-gate rejection gets a flash; every other outcome just
  # reloads.
  defp apply_or_flash(socket, {:error, {:trust_rejected, _reason}}),
    do: permission_denied_flash(socket)

  defp apply_or_flash(socket, _result), do: reload(socket)

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-6 max-w-3xl mx-auto">
      <%!-- CX-qat5.6 note (superseded by CX-f89w): flash used to not be
           rendered here because OutlineLive wasn't wrapped by a
           layout. It's now under the gated `:authenticated` live_session
           (`layout: {Layouts, :bare}`), which renders flash itself — an
           extra call here would duplicate ids (e.g. "client-error") and
           break LiveViewTest. Do not re-add this without removing the
           live_session's own flash_group. --%>
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
        >
          {if @node.item.collapsed, do: "▸", else: "▾"}
        </button>
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
