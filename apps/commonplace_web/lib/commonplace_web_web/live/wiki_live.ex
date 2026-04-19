defmodule CommonplaceWebWeb.WikiLive do
  @moduledoc """
  Wiki-style LiveView for browsing, creating, and editing commonplace documents.

  Pages are CRDT documents in the tree. Wiki links [[PageName]] navigate between them.
  Supports view mode (rendered content) and edit mode (CodeMirror + Yjs).
  """

  use CommonplaceWebWeb, :live_view

  alias Commonplace.Tree.{Schema, Walk, DocBuilder, DocCache}
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Document.{ContentType, ViewDetect}
  alias Commonplace.Dataflow.PubSub, as: CPPubSub
  alias Commonplace.Presence
  alias Commonplace.Presence.Identity
  alias CommonplaceWebWeb.{ViewRenderer, ViewActions}
  import CommonplaceWebWeb.PresenceCard, only: [presence_card: 1]

  @impl true
  def mount(_params, _session, socket) do
    data_dir = Application.get_env(:commonplace, :data_dir, "data")
    root = read_root_uuid(data_dir)

    socket =
      socket
      |> assign(:root_uuid, root)
      |> assign(:current_path, "")
      |> assign(:page_name, nil)
      |> assign(:page_uuid, nil)
      |> assign(:page_content, nil)
      |> assign(:mode, :view)
      |> assign(:entries, list_entries(root))
      |> assign(:show_create, false)
      |> assign(:show_history, false)
      |> assign(:history, [])
      |> assign(:page_title, "Commonplace Wiki")

    {:ok, socket}
  end

  @impl true
  def handle_params(%{"path" => path_parts}, _uri, socket) do
    path = Enum.join(path_parts, "/")

    if String.contains?(path, "..") do
      {:noreply, push_navigate(socket, to: ~p"/wiki")}
    else
      socket = load_page(socket, path)
      {:noreply, socket}
    end
  end

  def handle_params(_params, _uri, socket) do
    # /wiki with no path — show home or page listing
    socket = load_page(socket, "")
    {:noreply, socket}
  end

  # --- Events ---

  @impl true
  def handle_event("navigate", %{"page" => page}, socket) do
    target =
      if socket.assigns.current_path == "" do
        page
      else
        socket.assigns.current_path <> "/" <> page
      end

    {:noreply, push_patch(socket, to: wiki_path(target))}
  end

  @impl true
  def handle_event("edit", _params, socket) do
    if socket.assigns.page_uuid do
      # Don't push yjs_init here — the YjsHook div hasn't been rendered yet.
      # Instead, the hook will request data via "yjs_request_init" when mounted.
      {:noreply, assign(socket, :mode, :edit)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("yjs_request_init", _params, socket) do
    # Hook has mounted and is ready for data
    require Logger
    Logger.debug("yjs_request_init: page_uuid=#{inspect(socket.assigns.page_uuid)}")
    {:noreply, push_yjs_state(socket)}
  end

  @impl true
  def handle_event("view", _params, socket) do
    # Refresh content from store before switching to view
    socket =
      if socket.assigns.page_uuid do
        content = read_and_enrich(socket.assigns.page_uuid, socket)
        assign(socket, mode: :view, page_content: content)
      else
        assign(socket, :mode, :view)
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("show_create", _params, socket) do
    {:noreply, assign(socket, :show_create, true)}
  end

  @impl true
  def handle_event("cancel_create", _params, socket) do
    {:noreply, assign(socket, :show_create, false)}
  end

  @impl true
  def handle_event("create_page", %{"name" => name}, socket) do
    name = String.trim(name)

    if name == "" do
      {:noreply, put_flash(socket, :error, "Page name cannot be empty")}
    else
      dir_uuid = current_dir_uuid(socket)
      filename = sanitize_page_name(name)

      # Check if page already exists
      schema = load_schema(dir_uuid)

      case Schema.get_entry(schema, filename) do
        {:ok, _} ->
          # Page exists — navigate to it
          target =
            if socket.assigns.current_path == "" do
              filename
            else
              socket.assigns.current_path <> "/" <> filename
            end

          {:noreply,
           socket
           |> assign(:show_create, false)
           |> push_patch(to: wiki_path(target))}

        :error ->
          # Create new document
          uuid = UUID.uuid4()
          doc = Yelixer.Doc.new()
          doc = ContentType.create(doc, :text, filename)
          doc = ContentType.insert_text(doc, 0, "# #{name}\n\nWrite your content here.\n")
          update = Yelixer.Encoding.encode_update(doc)
          CommitStoreClient.create_commit(uuid, update, nil)

          # Add to schema via chained commit
          schema = Schema.add_file(schema, filename, uuid)
          schema_update = Yelixer.Encoding.encode_update(schema)
          CommitStoreClient.create_chained_commit(dir_uuid, schema_update)

          target =
            if socket.assigns.current_path == "" do
              filename
            else
              socket.assigns.current_path <> "/" <> filename
            end

          {:noreply,
           socket
           |> assign(:show_create, false)
           |> put_flash(:info, "Created #{name}")
           |> push_patch(to: wiki_path(target))}
      end
    end
  end

  @impl true
  def handle_event("toggle_history", _params, socket) do
    if socket.assigns.show_history do
      {:noreply, assign(socket, :show_history, false)}
    else
      history =
        if socket.assigns.page_uuid do
          CommitStoreClient.commit_log(socket.assigns.page_uuid, limit: 20)
        else
          []
        end

      {:noreply, assign(socket, show_history: true, history: history)}
    end
  end

  @impl true
  def handle_event("yjs_edit", %{"update" => encoded}, socket) do
    with uuid when not is_nil(uuid) <- socket.assigns.page_uuid,
         {:ok, update} <- Base.decode64(encoded) do
      commit = CommitStoreClient.create_chained_commit(uuid, update)

      case commit do
        %{id: _} ->
          CPPubSub.broadcast_blue(uuid, update)
          {:noreply, socket}

        _ ->
          {:noreply, put_flash(socket, :error, "Failed to save")}
      end
    else
      _ -> {:noreply, socket}
    end
  end

  @impl true
  def handle_event("recent_changes", _params, socket) do
    {:noreply, push_navigate(socket, to: ~p"/wiki/special/recent-changes")}
  end

  @impl true
  def handle_event("view_action", params, socket) do
    # Views Pass A (CX-vaw): view <action> buttons phx-click into this
    # handler. We build a context map and delegate to ViewActions.dispatch.
    # Identity is a placeholder ("wiki-user@local") until real session
    # identity propagation lands alongside signed-commit wiring.
    action_name = params["action"] || ""
    target = params["target"]
    extra_args = Map.drop(params, ["action", "target"])

    view_path =
      case {socket.assigns.current_path, socket.assigns.page_name} do
        {"", name} when is_binary(name) -> name
        {path, name} when is_binary(name) -> path <> "/" <> name
        _ -> ""
      end

    context = %{
      view_path: view_path,
      view_uuid: socket.assigns.page_uuid,
      target: target,
      args: extra_args,
      signer_id: "wiki-user@local",
      source: "wiki_live"
    }

    case ViewActions.dispatch(action_name, context, socket) do
      {:ok, updated_socket} ->
        {:noreply, updated_socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, reason)}
    end
  end

  # --- PubSub ---

  @impl true
  def handle_info({:commit, _uuid, _commit_id, _meta}, socket) do
    # Use && (truthy) not `and` (strict boolean) — page_uuid is a UUID
    # string, which would crash `and` with BadBooleanError.
    if socket.assigns.page_uuid && socket.assigns.mode == :view do
      content = read_and_enrich(socket.assigns.page_uuid, socket)
      {:noreply, assign(socket, :page_content, content)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # --- Render ---

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-screen bg-base-100">
      <!-- Sidebar -->
      <aside class="w-64 border-r border-base-300 bg-base-200 flex flex-col">
        <div class="p-4 border-b border-base-300">
          <a href="/wiki" class="text-xl font-bold text-primary">Commonplace</a>
          <p class="text-xs text-base-content/60 mt-1">CRDT Wiki</p>
        </div>

        <!-- Navigation -->
        <nav class="flex-1 overflow-y-auto p-3">
          <div class="mb-3">
            <button phx-click="show_create" class="btn btn-sm btn-primary w-full gap-1">
              <.icon name="hero-plus-micro" class="size-4" /> New Page
            </button>
          </div>

          <%= if @current_path != "" do %>
            <a
              href={wiki_path(parent_path(@current_path))}
              class="flex items-center gap-1 text-sm text-base-content/60 hover:text-primary mb-2 px-2"
            >
              <.icon name="hero-arrow-left-micro" class="size-3" /> Back
            </a>
            <div class="text-xs text-base-content/40 px-2 mb-2 font-mono">
              /<%= @current_path %>
            </div>
          <% end %>

          <ul class="space-y-0.5">
            <%= for entry <- @entries do %>
              <li>
                <%= if entry.type == :dir do %>
                  <a
                    href={wiki_path(join_path(@current_path, entry.name))}
                    class="flex items-center gap-2 px-2 py-1.5 rounded text-sm hover:bg-base-300 transition-colors"
                  >
                    <.icon name="hero-folder-micro" class="size-4 text-warning" />
                    <span><%= entry.name %>/</span>
                  </a>
                <% else %>
                  <a
                    href={wiki_path(join_path(@current_path, entry.name))}
                    class={"flex items-center gap-2 px-2 py-1.5 rounded text-sm transition-colors " <>
                      if(entry.name == @page_name, do: "bg-primary/10 text-primary font-medium", else: "hover:bg-base-300")}
                  >
                    <.icon name="hero-document-text-micro" class="size-4 text-base-content/40" />
                    <span><%= display_name(entry.name) %></span>
                  </a>
                <% end %>
              </li>
            <% end %>
          </ul>

          <%= if @entries == [] do %>
            <p class="text-sm text-base-content/40 italic px-2">No pages yet</p>
          <% end %>
        </nav>

        <!-- Sidebar footer -->
        <div class="p-3 border-t border-base-300">
          <a href="/wiki/special/recent-changes" class="flex items-center gap-2 text-sm text-base-content/60 hover:text-primary px-2 py-1">
            <.icon name="hero-clock-micro" class="size-4" /> Recent Changes
          </a>
          <div class="flex items-center gap-2 text-sm text-base-content/60 px-2 py-1 mt-1">
            <.icon name="hero-document-duplicate-micro" class="size-4" />
            <span><%= length(@entries) %> pages</span>
          </div>
        </div>
      </aside>

      <!-- Main content -->
      <main class="flex-1 flex flex-col overflow-hidden">
        <!-- Page header / toolbar -->
        <%= if @page_name do %>
          <header class="flex items-center justify-between px-6 py-3 border-b border-base-300 bg-base-100">
            <div>
              <h1 class="text-2xl font-bold"><%= display_name(@page_name) %></h1>
              <p class="text-xs text-base-content/50 font-mono">/<%= join_path(@current_path, @page_name) %></p>
            </div>
            <div class="flex items-center gap-2">
              <button phx-click="toggle_history" class={"btn btn-sm btn-ghost gap-1 " <> if(@show_history, do: "btn-active", else: "")}>
                <.icon name="hero-clock-micro" class="size-4" /> History
              </button>
              <%= if @mode == :view do %>
                <button phx-click="edit" class="btn btn-sm btn-primary gap-1">
                  <.icon name="hero-pencil-micro" class="size-4" /> Edit
                </button>
              <% else %>
                <button phx-click="view" class="btn btn-sm btn-ghost gap-1">
                  <.icon name="hero-eye-micro" class="size-4" /> View
                </button>
              <% end %>
            </div>
          </header>
        <% else %>
          <header class="flex items-center justify-between px-6 py-3 border-b border-base-300 bg-base-100">
            <div>
              <h1 class="text-2xl font-bold">
                <%= if @current_path == "" do %>
                  Welcome
                <% else %>
                  <%= Path.basename(@current_path) %>
                <% end %>
              </h1>
            </div>
          </header>
        <% end %>

        <!-- Content area -->
        <div class="flex-1 overflow-y-auto flex">
          <div class={"flex-1 " <> if(@show_history, do: "border-r border-base-300", else: "")}>
            <%= if @mode == :edit and @page_uuid do %>
              <div id="yjs-content" phx-hook="YjsHook" phx-update="ignore" class="h-full">
                <p class="p-6 text-base-content/40">Loading editor...</p>
              </div>
            <% else %>
              <div class="p-6 max-w-4xl">
                <%= if match?({:special, :recent_changes, _}, @page_content) do %>
                  <.recent_changes_page changes={elem(@page_content, 2)} />
                <% else %>
                  <%= if @page_content do %>
                    <%= cond do %>
                      <% presence_render?(@page_name, @page_content) -> %>
                        <article class="max-w-4xl">
                          <.presence_card
                            presence={@page_content}
                            name={presence_display_name(@page_name)}
                            honorific={presence_honorific(@page_name)}
                            identity={@page_content[:__identity__]}
                          />
                        </article>
                      <% ViewDetect.is_view?(@page_content) -> %>
                        <article class="max-w-none">
                          <%= ViewRenderer.render_view(@page_content, @current_path) %>
                        </article>
                      <% true -> %>
                        <article class="prose prose-lg max-w-none">
                          <%= render_wiki_content(@page_content, @current_path) %>
                        </article>
                    <% end %>
                  <% else %>
                    <%= if @page_name do %>
                      <p class="text-base-content/40">This page is empty.</p>
                      <button phx-click="edit" class="btn btn-primary btn-sm mt-4 gap-1">
                        <.icon name="hero-pencil-micro" class="size-4" /> Start writing
                      </button>
                    <% else %>
                      <.wiki_home entries={@entries} current_path={@current_path} />
                    <% end %>
                  <% end %>
                <% end %>
              </div>
            <% end %>
          </div>

          <!-- History panel -->
          <%= if @show_history do %>
            <aside class="w-72 overflow-y-auto bg-base-200/50 p-4">
              <h3 class="font-bold text-sm mb-3">Page History</h3>
              <%= if @history == [] do %>
                <p class="text-sm text-base-content/40">No history</p>
              <% else %>
                <ul class="space-y-2">
                  <%= for commit <- @history do %>
                    <li class="text-xs border-l-2 border-primary/30 pl-3 py-1">
                      <div class="font-mono text-base-content/60">
                        <%= String.slice(Base.encode16(commit.id, case: :lower), 0, 8) %>
                      </div>
                      <div class="text-base-content/40">
                        <%= format_timestamp(commit.timestamp) %>
                      </div>
                    </li>
                  <% end %>
                </ul>
              <% end %>
            </aside>
          <% end %>
        </div>
      </main>

      <!-- Create page modal -->
      <%= if @show_create do %>
        <div class="fixed inset-0 z-50 flex items-center justify-center">
          <div class="absolute inset-0 bg-black/50" phx-click="cancel_create"></div>
          <div class="relative bg-base-100 rounded-lg shadow-xl p-6 w-96 mx-4">
            <h2 class="text-lg font-bold mb-4">Create New Page</h2>
            <form phx-submit="create_page">
              <input
                type="text"
                name="name"
                placeholder="Page name"
                autofocus
                class="input input-bordered w-full mb-4"
                phx-mounted={JS.focus()}
              />
              <div class="flex justify-end gap-2">
                <button type="button" phx-click="cancel_create" class="btn btn-ghost btn-sm">Cancel</button>
                <button type="submit" class="btn btn-primary btn-sm">Create</button>
              </div>
            </form>
          </div>
        </div>
      <% end %>
    </div>

    """
  end

  # Wiki home page component
  defp wiki_home(assigns) do
    ~H"""
    <div>
      <h2 class="text-xl font-semibold mb-4">Pages</h2>
      <%= if @entries == [] do %>
        <p class="text-base-content/50">
          No pages yet. Click <strong>New Page</strong> to create your first wiki page.
        </p>
      <% else %>
        <div class="grid gap-2">
          <%= for entry <- @entries do %>
            <a
              href={wiki_path(join_path(@current_path, entry.name))}
              class="flex items-center gap-3 p-3 rounded-lg hover:bg-base-200 transition-colors border border-base-300"
            >
              <%= if entry.type == :dir do %>
                <.icon name="hero-folder-micro" class="size-5 text-warning" />
              <% else %>
                <.icon name="hero-document-text-micro" class="size-5 text-primary" />
              <% end %>
              <span class="font-medium"><%= display_name(entry.name) %></span>
            </a>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  # Recent changes page component
  defp recent_changes_page(assigns) do
    ~H"""
    <div>
      <h2 class="text-xl font-semibold mb-4">Recent Changes</h2>
      <%= if @changes == [] do %>
        <p class="text-base-content/50">No changes recorded yet.</p>
      <% else %>
        <div class="space-y-1">
          <%= for change <- @changes do %>
            <a
              href={wiki_path(change.path)}
              class="flex items-center justify-between p-3 rounded-lg hover:bg-base-200 transition-colors border border-base-300"
            >
              <div class="flex items-center gap-3">
                <.icon name="hero-document-text-micro" class="size-5 text-primary" />
                <div>
                  <span class="font-medium"><%= display_name(change.name) %></span>
                  <span class="text-xs text-base-content/40 ml-2 font-mono"><%= change.path %></span>
                </div>
              </div>
              <span class="text-xs text-base-content/50">
                <%= format_timestamp(change.commit.timestamp) %>
              </span>
            </a>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  # --- Wiki content rendering ---

  defp render_wiki_content(content, current_path) when is_binary(content) do
    content
    |> String.split("\n")
    |> Enum.map(&render_line(&1, current_path))
    |> Enum.intersperse(raw("<br>"))
    |> then(&raw(Enum.map_join(&1, "", fn
      {:safe, s} -> IO.iodata_to_binary(s)
      s when is_binary(s) -> s
    end)))
  end

  defp render_wiki_content(_, _), do: raw("")

  defp render_line(line, current_path) do
    cond do
      String.starts_with?(line, "### ") ->
        text = String.trim_leading(line, "### ")
        raw("<h3 class=\"text-lg font-semibold mt-4 mb-2\">#{escape(text)}</h3>")

      String.starts_with?(line, "## ") ->
        text = String.trim_leading(line, "## ")
        raw("<h2 class=\"text-xl font-semibold mt-5 mb-2\">#{escape(text)}</h2>")

      String.starts_with?(line, "# ") ->
        text = String.trim_leading(line, "# ")
        raw("<h1 class=\"text-2xl font-bold mt-6 mb-3\">#{escape(text)}</h1>")

      String.starts_with?(line, "- ") or String.starts_with?(line, "* ") ->
        text = String.slice(line, 2..-1//1)
        raw("<li class=\"ml-4\">#{render_inline(text, current_path)}</li>")

      line == "" ->
        raw("<br>")

      true ->
        raw("<p>#{render_inline(line, current_path)}</p>")
    end
  end

  defp render_inline(text, current_path) do
    # Replace [[PageName]] and [[PageName|Display]] with links
    Regex.replace(~r/\[\[([^\]]+)\]\]/, text, fn _, inner ->
      {page, display} =
        case String.split(inner, "|", parts: 2) do
          [page, display] -> {String.trim(page), String.trim(display)}
          [page] -> {String.trim(page), String.trim(page)}
        end

      href = wiki_path(join_path(current_path, sanitize_page_name(page)))
      "<a href=\"#{escape(href)}\" class=\"text-primary hover:underline font-medium\">#{escape(display)}</a>"
    end)
    |> then(fn text ->
      # Bold
      text = Regex.replace(~r/\*\*(.+?)\*\*/, text, "<strong>\\1</strong>")
      # Italic
      text = Regex.replace(~r/\*(.+?)\*/, text, "<em>\\1</em>")
      # Code
      Regex.replace(~r/`(.+?)`/, text, "<code class=\"bg-base-300 px-1 rounded text-sm\">\\1</code>")
    end)
  end

  # --- Helpers ---

  defp load_page(socket, path) do
    root = socket.assigns.root_uuid

    # Unsubscribe from previous page
    if socket.assigns.page_uuid do
      CPPubSub.unsubscribe_blue(socket.assigns.page_uuid)
    end

    # Handle special pages
    if String.starts_with?(path, "special/") do
      load_special_page(socket, path)
    else
      {dir_path, page_name} = split_page_path(path)

      dir_uuid =
        if dir_path == "" do
          root
        else
          resolve_dir(root, dir_path)
        end

      entries = if dir_uuid, do: list_entries(dir_uuid), else: []

      if page_name do
        # Try to load the specific page
        schema = if dir_uuid, do: load_schema(dir_uuid), else: Schema.new_schema()

        case Schema.get_entry(schema, page_name) do
          {:ok, entry} when entry.type == :dir ->
            # It's a directory — show its contents
            dir_entries = list_entries(entry.node_id)

            socket
            |> assign(
              current_path: path,
              page_name: nil,
              page_uuid: nil,
              page_content: nil,
              mode: :view,
              entries: dir_entries,
              show_history: false,
              history: [],
              page_title: "#{page_name} — Commonplace Wiki"
            )

          {:ok, entry} ->
            # It's a document — show it. Centralized enrichment ensures the
            # presence identity panel survives live refreshes (see
            # handle_info({:commit,...}) and the "view" toggle handler).
            content = read_and_enrich(entry.node_id, page_name, root)

            if connected?(socket) do
              CPPubSub.subscribe_blue(entry.node_id)
            end

            socket
            |> assign(
              current_path: dir_path,
              page_name: page_name,
              page_uuid: entry.node_id,
              page_content: content,
              mode: :view,
              entries: entries,
              show_history: false,
              history: [],
              page_title: "#{display_name(page_name)} — Commonplace Wiki"
            )

          :error ->
            # Page doesn't exist — offer to create
            socket
            |> assign(
              current_path: dir_path,
              page_name: page_name,
              page_uuid: nil,
              page_content: nil,
              mode: :view,
              entries: entries,
              show_history: false,
              history: [],
              page_title: "#{display_name(page_name)} (new) — Commonplace Wiki"
            )
        end
      else
        # No page name — show directory listing
        socket
        |> assign(
          current_path: path,
          page_name: nil,
          page_uuid: nil,
          page_content: nil,
          mode: :view,
          entries: entries,
          show_history: false,
          history: [],
          page_title: if(path == "", do: "Commonplace Wiki", else: "#{Path.basename(path)} — Commonplace Wiki")
        )
      end
    end
  end

  defp load_special_page(socket, "special/recent-changes") do
    root = socket.assigns.root_uuid
    changes = collect_recent_changes(root, "", 50)

    socket
    |> assign(
      current_path: "",
      page_name: nil,
      page_uuid: nil,
      page_content: {:special, :recent_changes, changes},
      mode: :view,
      entries: list_entries(root),
      show_history: false,
      history: [],
      page_title: "Recent Changes — Commonplace Wiki"
    )
  end

  defp load_special_page(socket, _), do: socket

  defp push_yjs_state(socket) do
    require Logger
    uuid = socket.assigns.page_uuid
    Logger.debug("push_yjs_state: uuid=#{inspect(uuid)}")

    case DocBuilder.reconstruct_doc(CommitStoreClient, uuid) do
      {:ok, doc} ->
        update = Yelixer.Encoding.encode_update(doc)
        Logger.debug("push_yjs_state: update size=#{byte_size(update)}")
        encoded = Base.encode64(update)
        push_event(socket, "yjs_init", %{update: encoded})

      :none ->
        Logger.debug("push_yjs_state: no commits found for #{inspect(uuid)}")
        socket
    end
  end

  defp read_doc_content(uuid) do
    case DocCache.get_snapshot(CommitStoreClient, uuid) do
      {:ok, doc} -> ContentType.get_content(doc)
      :none -> nil
    end
  end

  # Read the document content and (when the page is a presence doc) attach
  # the cold identity record under `:__identity__`. All sites that refresh
  # `page_content` for a loaded page must go through this helper so the
  # identity panel doesn't vanish on the next heartbeat/status/activity
  # commit or when the user toggles Edit -> View.
  defp read_and_enrich(uuid, page_name, root_uuid) do
    content = read_doc_content(uuid)
    maybe_enrich_presence(page_name, content, root_uuid)
  end

  # Convenience for handlers that only have the socket — pulls page_name
  # and root_uuid out of assigns.
  defp read_and_enrich(uuid, socket) do
    read_and_enrich(uuid, socket.assigns.page_name, socket.assigns.root_uuid)
  end

  defp collect_recent_changes(root_uuid, path, limit) do
    schema = load_schema(root_uuid)
    entries = Schema.list_entries(schema)

    changes =
      Enum.flat_map(entries, fn entry ->
        full_path = if path == "", do: entry.name, else: path <> "/" <> entry.name

        if entry.type == :dir do
          collect_recent_changes(entry.node_id, full_path, limit)
        else
          case CommitStoreClient.latest_commit(entry.node_id) do
            {:ok, commit} ->
              [%{path: full_path, name: entry.name, commit: commit, uuid: entry.node_id}]

            :none ->
              []
          end
        end
      end)

    changes
    |> Enum.sort_by(fn c -> c.commit.timestamp end, {:desc, DateTime})
    |> Enum.take(limit)
  end

  defp split_page_path(""), do: {"", nil}

  defp split_page_path(path) do
    parts = String.split(path, "/")

    if length(parts) == 1 do
      {"", hd(parts)}
    else
      dir = parts |> Enum.drop(-1) |> Enum.join("/")
      page = List.last(parts)
      {dir, page}
    end
  end

  defp resolve_dir(root_uuid, path) do
    loader = &load_schema/1

    case Walk.resolve_path(root_uuid, path, loader) do
      {:ok, uuid} -> uuid
      {:error, _} -> nil
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

  defp list_entries(nil), do: []

  defp list_entries(uuid) do
    schema = load_schema(uuid)

    Schema.list_entries(schema)
    |> Enum.reject(&String.starts_with?(&1.name, "__"))
    |> Enum.reject(&String.starts_with?(&1.name, "."))
    |> Enum.sort_by(fn e -> {if(e.type == :dir, do: 0, else: 1), e.name} end)
  end

  defp load_schema(uuid) do
    case DocCache.get_snapshot(CommitStoreClient, uuid) do
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

  defp sanitize_page_name(name) do
    name
    |> String.trim()
    |> String.replace(~r/[^\w\s\-.]/, "")
    |> String.replace(~r/\s+/, "-")
    |> String.downcase()
  end

  defp display_name(name) when is_binary(name) do
    name
    |> String.replace("-", " ")
    |> String.replace("_", " ")
    |> String.split(" ")
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end

  defp display_name(_), do: ""

  defp wiki_path(""), do: ~p"/wiki"
  defp wiki_path(path), do: "/wiki/#{path}"

  defp join_path("", name), do: name
  defp join_path(path, name), do: path <> "/" <> name

  defp parent_path(path) do
    case String.split(path, "/") do
      [_] -> ""
      parts -> parts |> Enum.drop(-1) |> Enum.join("/")
    end
  end

  # Returns true when the page is a presence file (.bot/.usr/.exe/.who) and
  # the loaded content is the YMap (a plain Elixir map, not a binary).
  defp presence_render?(page_name, %{} = content) when is_binary(page_name) do
    not Map.has_key?(content, :__struct__) and
      match?({:ok, _, _}, Presence.parse_honorific(page_name))
  end

  defp presence_render?(_, _), do: false

  defp presence_honorific(page_name) when is_binary(page_name) do
    case Presence.parse_honorific(page_name) do
      {:ok, _, type} -> type
      _ -> nil
    end
  end

  defp presence_honorific(_), do: nil

  defp presence_display_name(page_name) when is_binary(page_name) do
    case Presence.parse_honorific(page_name) do
      {:ok, name, _} -> name
      _ -> page_name
    end
  end

  defp presence_display_name(_), do: nil

  # If page is a presence doc, look up the cold identity (from __identities__)
  # and attach it to the content map under :__identity__ so the renderer can
  # display first_seen/last_seen/public_keys without a second round-trip.
  #
  # CX-5gp: the page filename can be collision-renamed (e.g. claude-code-abc.bot
  # for the second presence file with actor name "claude-code"). The stored
  # content carries the original actor name under "name", so prefer that for
  # the Identity.lookup. Fall back to the parsed filename only if the stored
  # name is missing (legacy / pre-CX-4ba presence docs).
  defp maybe_enrich_presence(page_name, %{} = content, root_uuid)
       when is_binary(page_name) and not is_nil(root_uuid) do
    case Presence.parse_honorific(page_name) do
      {:ok, parsed_name, type} ->
        actor_name =
          case Map.get(content, "name") do
            stored when is_binary(stored) and stored != "" -> stored
            _ -> parsed_name
          end

        identity =
          case Identity.lookup(actor_name, type, root_uuid) do
            {:ok, identity_uuid} -> Identity.read(identity_uuid)
            _ -> nil
          end

        Map.put(content, :__identity__, identity)

      _ ->
        content
    end
  end

  defp maybe_enrich_presence(_page_name, content, _root), do: content

  defp format_timestamp(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  end

  defp format_timestamp(_), do: ""

  defp escape(text) when is_binary(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end
end
