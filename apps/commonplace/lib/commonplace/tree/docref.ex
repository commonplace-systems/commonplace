defmodule Commonplace.Tree.Docref do
  @moduledoc """
  Flexible document reference resolution.

  Resolves human-friendly references to document UUIDs:

  - **Raw UUID** — returned directly (regex match on standard UUID format)
  - **Single name** (e.g. "main") — looked up in the root schema
  - **Path** (e.g. "main/docs/plans") — walked through nested schemas
  - **`/` prefix** — repo-absolute, resolved from `:repo_root_uuid`
  - **`!` prefix** — tree-absolute, resolved from `:tree_root_uuid`
  - **`../` prefix** — relative traversal, resolved from `:parent_uuid` / `:ancestors`

  The `@commit` syntax is deferred and not yet supported.

  ## Usage

      Docref.resolve("550e8400-e29b-41d4-a716-446655440000", root_uuid: nil, loader: nil)
      # => {:ok, "550e8400-e29b-41d4-a716-446655440000"}

      Docref.resolve("main", root_uuid: root_uuid, loader: loader_fn)
      # => {:ok, "uuid-for-main"}

      Docref.resolve("main/docs/plans", root_uuid: root_uuid, loader: loader_fn)
      # => {:ok, "uuid-for-plans"}

      Docref.resolve("/shared", root_uuid: current, loader: loader, repo_root_uuid: repo_root)
      # => {:ok, "uuid-for-shared"}

      Docref.resolve("!global", root_uuid: current, loader: loader, tree_root_uuid: tree_root)
      # => {:ok, "uuid-for-global"}

      Docref.resolve("../sibling", root_uuid: current, loader: loader, parent_uuid: parent)
      # => {:ok, "uuid-for-sibling"}
  """

  alias Commonplace.Tree.Walk

  @uuid_regex ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

  @doc """
  Resolve a docref string to a UUID.

  Options:
  - `:root_uuid` — UUID of the root schema document
  - `:loader` — function `(uuid) -> Yelixer.Doc` that loads a schema doc
  - `:repo_root_uuid` — UUID of the repository root (for `/` prefix)
  - `:tree_root_uuid` — UUID of the tree root (for `!` prefix)
  - `:parent_uuid` — UUID of the parent directory (for `../` prefix)
  - `:ancestors` — list of ancestor UUIDs from parent upward (for multi-level `../`)

  Returns `{:ok, uuid}` or `{:error, reason}`.
  """
  def resolve(ref, opts) when is_binary(ref) do
    ref = String.trim(ref)

    cond do
      ref == "" ->
        {:error, :empty_ref}

      uuid?(ref) ->
        {:ok, ref}

      String.starts_with?(ref, "!") ->
        path = String.trim_leading(ref, "!")
        resolve_tree_absolute(path, opts)

      String.starts_with?(ref, "/") ->
        path = String.trim_leading(ref, "/")
        resolve_repo_absolute(path, opts)

      String.starts_with?(ref, "../") ->
        resolve_relative(ref, opts)

      true ->
        resolve_by_path(ref, opts)
    end
  end

  defp resolve_repo_absolute(path, opts) do
    loader = Keyword.get(opts, :loader)

    case Keyword.get(opts, :repo_root_uuid) do
      nil -> {:error, :no_repo_root}
      root -> Walk.resolve_path(root, path, loader)
    end
  end

  defp resolve_tree_absolute(path, opts) do
    loader = Keyword.get(opts, :loader)

    case Keyword.get(opts, :tree_root_uuid) do
      nil -> {:error, :no_tree_root}
      root -> Walk.resolve_path(root, path, loader)
    end
  end

  defp resolve_relative(ref, opts) do
    loader = Keyword.get(opts, :loader)
    parent_uuid = Keyword.get(opts, :parent_uuid)
    ancestors = Keyword.get(opts, :ancestors, [])

    # Count the number of ../ prefixes and extract the remaining path
    {levels, remaining_path} = count_parent_levels(ref)

    # Build the full ancestor list: [parent | ancestors]
    all_ancestors =
      if parent_uuid do
        [parent_uuid | ancestors]
      else
        ancestors
      end

    if levels > length(all_ancestors) do
      {:error, :ancestor_out_of_range}
    else
      # The target ancestor is at index (levels - 1)
      target_uuid = Enum.at(all_ancestors, levels - 1)

      if remaining_path == "" do
        {:ok, target_uuid}
      else
        Walk.resolve_path(target_uuid, remaining_path, loader)
      end
    end
  end

  defp count_parent_levels(ref) do
    count_parent_levels(ref, 0)
  end

  defp count_parent_levels("../" <> rest, count) do
    count_parent_levels(rest, count + 1)
  end

  defp count_parent_levels(remaining, count) do
    {count, remaining}
  end

  defp resolve_by_path(ref, opts) do
    root_uuid = Keyword.get(opts, :root_uuid)
    loader = Keyword.get(opts, :loader)

    if is_nil(root_uuid) do
      {:error, :no_root}
    else
      Walk.resolve_path(root_uuid, ref, loader)
    end
  end

  defp uuid?(str) do
    Regex.match?(@uuid_regex, str)
  end
end
