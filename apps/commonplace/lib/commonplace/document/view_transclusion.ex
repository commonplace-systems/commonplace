defmodule Commonplace.Document.ViewTransclusion do
  @moduledoc """
  Resolves `<include>` elements in a parsed view tree by reading the
  referenced document's content and splicing it in as children.

  Per views.md, transclusion is inlined at compute time (or at render
  time if the view is hand-authored). This module is the resolver for
  the render-time path — ViewRenderer calls `expand/2` before walking
  the tree to emit HEEx.

  ## Cycle detection

  Every call maintains a visited-UUIDs set. If an include references a
  doc that's already in the visited set (anywhere up the recursion
  chain), the resolver stops and replaces the include's children with
  a cycle-warning marker entity. The original include element is
  preserved so renderers still emit the transclusion boxing.

  ## Resolution limits

  The default max depth is 4 — deep enough for the common case of
  "wiki page includes user card, user card includes avatar," shallow
  enough to avoid pathological recursion even without cycle
  detection. Callers can override via `expand/2`'s opts keyword.

  ## Resolution failure modes

  When an include cannot be resolved (docref doesn't parse, target
  doesn't exist in the store, content isn't a view and isn't plain
  text), the resolver preserves the include element and inserts a
  single `%Node{tag: :text}` child with a short error description.
  Failed resolutions never raise; they degrade gracefully so the rest
  of the view renders.

  ## Not in scope

  - Path-based docref resolution beyond workspace-root direct lookup
    (no `../` navigation, no `!` tree-root syntax yet — file a
    follow-up if that's needed).
  - Commit-pinning via the `commit` attribute (currently ignored;
    resolver always reads the latest snapshot).
  - Format conversion between view XML and non-view text (if the
    referenced doc is plain text, it's wrapped in a `<text format="plain">`
    child; no markdown parsing).
  """

  alias Commonplace.Document.{ContentType, ViewDetect, ViewXml}
  alias Commonplace.Document.ViewXml.Node
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.{DocBuilder, Schema}

  @default_max_depth 4

  @type opts :: [
          max_depth: non_neg_integer(),
          store: GenServer.server(),
          visited: MapSet.t(),
          root_uuid: String.t() | nil
        ]

  @doc """
  Expand all includes in the given node (recursively). Returns an
  updated node with resolved children. Never raises.
  """
  @spec expand(Node.t(), opts()) :: Node.t()
  def expand(%Node{} = node, opts \\ []) do
    max_depth = Keyword.get(opts, :max_depth, @default_max_depth)
    store = Keyword.get(opts, :store, CommitStoreClient)
    visited = Keyword.get(opts, :visited, MapSet.new())
    root_uuid = Keyword.get(opts, :root_uuid, fetch_root_uuid())

    do_expand(node, store, visited, max_depth, root_uuid)
  end

  # --- Tree walk ---

  defp do_expand(%Node{tag: :include} = node, store, visited, max_depth, root_uuid) do
    cond do
      has_substantive_children?(node) ->
        # Author (or an upstream compute step) already inlined content.
        # Respect it — recurse into children for nested includes but
        # don't re-resolve this one.
        %{node | children: expand_children(node.children, store, visited, max_depth, root_uuid)}

      max_depth <= 0 ->
        %{node | children: [error_child("transclusion depth limit reached")]}

      root_uuid == nil ->
        %{node | children: [error_child("no workspace root available for transclusion")]}

      true ->
        resolve_include(node, store, visited, max_depth, root_uuid)
    end
  end

  defp do_expand(%Node{children: children} = node, store, visited, max_depth, root_uuid) do
    %{node | children: expand_children(children, store, visited, max_depth, root_uuid)}
  end

  defp expand_children(children, store, visited, max_depth, root_uuid) do
    Enum.map(children, fn
      %Node{} = child -> do_expand(child, store, visited, max_depth, root_uuid)
      text when is_binary(text) -> text
    end)
  end

  # --- Include resolution ---

  defp resolve_include(%Node{} = node, store, visited, max_depth, root_uuid) do
    from = Map.get(node.attrs, "from", "")

    with {:ok, target_uuid} <- resolve_docref(from, store, root_uuid),
         {:ok, new_visited} <- cycle_guard(target_uuid, visited),
         {:ok, raw_content} <- read_doc_content(target_uuid, store),
         {:ok, resolved_children} <- parse_or_wrap(raw_content) do
      # Recurse into the resolved subtree with an incremented visited
      # set and decremented depth.
      expanded =
        expand_children(resolved_children, store, new_visited, max_depth - 1, root_uuid)

      %{node | children: expanded}
    else
      {:error, :cycle} ->
        %{node | children: [error_child("transclusion cycle detected: #{from}")]}

      {:error, :not_found} ->
        %{node | children: [error_child("transclusion target not found: #{from}")]}

      {:error, :empty_from} ->
        %{node | children: [error_child("transclusion missing 'from' attribute")]}

      {:error, :no_content} ->
        %{node | children: [error_child("transclusion target has no content: #{from}")]}

      {:error, :parse_failed} ->
        %{node | children: [error_child("transclusion target failed to parse: #{from}")]}

      {:error, reason} ->
        %{node | children: [error_child("transclusion failed: #{inspect(reason)}")]}
    end
  rescue
    e ->
      %{node | children: [error_child("transclusion raised: #{Exception.message(e)}")]}
  end

  # --- Helpers ---

  @doc false
  def has_substantive_children?(%Node{children: children}) do
    Enum.any?(children, fn
      %Node{} -> true
      text when is_binary(text) -> String.trim(text) != ""
      _ -> false
    end)
  end

  # Parse the `from` attribute as a path and look it up via the root
  # schema. MVP: only bare filenames or forward-slash paths starting
  # from the workspace root are supported. Leading slashes and `/wiki/`
  # prefixes are stripped since they're rendering-level decorations.
  defp resolve_docref("", _store, _root_uuid), do: {:error, :empty_from}
  defp resolve_docref(nil, _store, _root_uuid), do: {:error, :empty_from}

  defp resolve_docref(from, store, root_uuid) when is_binary(from) do
    cleaned =
      from
      |> String.trim()
      |> String.trim_leading("/")
      |> strip_wiki_prefix()

    case cleaned do
      "" ->
        {:error, :empty_from}

      path ->
        segments = String.split(path, "/", trim: true)
        walk_schema(segments, root_uuid, store)
    end
  end

  defp strip_wiki_prefix("wiki/" <> rest), do: rest
  defp strip_wiki_prefix(other), do: other

  defp walk_schema([], _uuid, _store), do: {:error, :empty_from}

  defp walk_schema([name], current_uuid, store) do
    case load_schema(current_uuid, store) do
      {:ok, schema} ->
        case Schema.get_entry(schema, name) do
          {:ok, entry} -> {:ok, entry.node_id}
          :error -> {:error, :not_found}
        end

      :error ->
        {:error, :not_found}
    end
  end

  defp walk_schema([name | rest], current_uuid, store) do
    case load_schema(current_uuid, store) do
      {:ok, schema} ->
        case Schema.get_entry(schema, name) do
          {:ok, entry} -> walk_schema(rest, entry.node_id, store)
          :error -> {:error, :not_found}
        end

      :error ->
        {:error, :not_found}
    end
  end

  defp load_schema(uuid, store) do
    case DocBuilder.reconstruct_snapshot(store, uuid) do
      {:ok, doc} -> {:ok, doc}
      :none -> :error
      _ -> :error
    end
  end

  defp read_doc_content(uuid, store) do
    case DocBuilder.reconstruct_snapshot(store, uuid) do
      {:ok, doc} ->
        case ContentType.get_content(doc) do
          nil -> {:error, :no_content}
          "" -> {:error, :no_content}
          content -> {:ok, content}
        end

      :none ->
        {:error, :not_found}

      _ ->
        {:error, :not_found}
    end
  end

  # If the content is view XML, parse it and return the root view's
  # children (splicing it in-place as include's children). Otherwise
  # wrap the content as a plain-text node.
  defp parse_or_wrap(content) when is_binary(content) do
    if ViewDetect.is_view?(content) do
      case ViewXml.parse(content) do
        {:ok, %Node{tag: :view, children: children}} -> {:ok, children}
        {:ok, %Node{} = node} -> {:ok, [node]}
        {:error, _} -> {:error, :parse_failed}
      end
    else
      {:ok, [%Node{tag: :text, attrs: %{"format" => "plain"}, children: [content]}]}
    end
  end

  defp parse_or_wrap(_), do: {:error, :parse_failed}

  defp cycle_guard(uuid, visited) do
    if MapSet.member?(visited, uuid) do
      {:error, :cycle}
    else
      {:ok, MapSet.put(visited, uuid)}
    end
  end

  defp error_child(message) when is_binary(message) do
    %Node{tag: :text, attrs: %{"format" => "plain"}, children: [message]}
  end

  # Best-effort workspace root UUID fetch. Reads `data_dir` from app
  # env and loads the `root` file. Returns nil on any failure.
  defp fetch_root_uuid do
    data_dir = Application.get_env(:commonplace, :data_dir, "data")

    case File.read(Path.join(data_dir, "root")) do
      {:ok, uuid} -> String.trim(uuid)
      {:error, _} -> nil
    end
  rescue
    _ -> nil
  end
end
