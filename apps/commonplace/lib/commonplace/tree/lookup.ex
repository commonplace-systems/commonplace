defmodule Commonplace.Tree.Lookup do
  @moduledoc """
  CX-j6ul (sub-bead ii of CX-jfwv M4): substrate-tier composed lookup.

  Two operations + one composed convenience:

  * `lookup_doc_by_path/3` — wrapper over `Commonplace.Tree.Walk.resolve_path/3`
    that returns the path's UUID with a uniform `{:ok, uuid} | {:error, :not_found}`
    error semantic (Walk's raw errors include positional details that aren't
    useful at this layer).
  * `extract_named_children/3` — load a directory schema and pull a list of
    named entries' UUIDs in one call.
  * `lookup_path_and_extract/4` — composes the above. Lifts the
    `Chat.Rooms.lookup` shape into a generic primitive.

  ## Why this lives in `Commonplace.Tree.*`

  Mirrors `Tree.Fork`, `Tree.Walk`, `Tree.Schema` structural pattern. Higher
  level than `Tree.Walk` (which is a pure path-walker) but doesn't depend on
  any chat-tier knowledge. Future view-types (wiki, etc.) consume the same
  primitive when they need "lookup directory + extract named sub-docs."

  ## Error semantics

  All "missing" errors flatten to `{:error, :not_found}` for path-level
  misses or `{:error, {:not_found, name}}` for child-level misses. This
  preserves the `Chat.Rooms.lookup` callsite's `{:error, :not_found}`
  expectation when path lookup fails.
  """

  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.{DocBuilder, Schema, Walk}

  @doc """
  Resolve `path` (relative to `root_uuid`) to its UUID. Returns
  `{:ok, uuid}` on success, `{:error, :not_found}` when any path
  segment is missing.

  Optional opts:
    * `:store` — CommitStore name (defaults to `CommitStoreClient`)
  """
  def lookup_doc_by_path(root_uuid, path, opts \\ [])
      when is_binary(root_uuid) and is_binary(path) and is_list(opts) do
    store = Keyword.get(opts, :store, CommitStoreClient)
    loader = &load_schema(store, &1)

    case Walk.resolve_path(root_uuid, normalize_path(path), loader) do
      {:ok, uuid} -> {:ok, uuid}
      {:error, _reason} -> {:error, :not_found}
    end
  end

  @doc """
  Load the schema at `parent_uuid` and extract a map of `name => uuid`
  for each name in `names`. Returns `{:error, {:not_found, name}}`
  on the first missing name.

  Optional opts:
    * `:store` — CommitStore name (defaults to `CommitStoreClient`)
  """
  def extract_named_children(parent_uuid, names, opts \\ [])
      when is_binary(parent_uuid) and is_list(names) and is_list(opts) do
    store = Keyword.get(opts, :store, CommitStoreClient)
    doc = load_schema(store, parent_uuid)

    Enum.reduce_while(names, {:ok, %{}}, fn name, {:ok, acc} ->
      case Schema.get_entry(doc, name) do
        {:ok, entry} -> {:cont, {:ok, Map.put(acc, name, entry.node_id)}}
        :error -> {:halt, {:error, {:not_found, name}}}
      end
    end)
  end

  @doc """
  Compose `lookup_doc_by_path/3` + `extract_named_children/3` — resolve
  `path` then extract `names` from the resolved doc's schema. The
  shape `Chat.Rooms.lookup` was open-coding (and (iii) refactors).
  """
  def lookup_path_and_extract(root_uuid, path, names, opts \\ [])
      when is_binary(root_uuid) and is_binary(path) and is_list(names) and is_list(opts) do
    with {:ok, dir_uuid} <- lookup_doc_by_path(root_uuid, path, opts) do
      extract_named_children(dir_uuid, names, opts)
    end
  end

  # --- Private ---

  defp normalize_path(path) do
    path
    |> String.trim_leading("/")
    |> String.trim_trailing("/")
  end

  defp load_schema(store, uuid) do
    case DocBuilder.reconstruct_snapshot(store, uuid) do
      {:ok, doc} -> doc
      :none -> Schema.new_schema()
    end
  end
end
