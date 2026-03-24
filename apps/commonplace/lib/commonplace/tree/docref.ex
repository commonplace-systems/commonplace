defmodule Commonplace.Tree.Docref do
  @moduledoc """
  Flexible document reference resolution.

  Resolves human-friendly references to document UUIDs:

  - **Raw UUID** — returned directly (regex match on standard UUID format)
  - **Single name** (e.g. "main") — looked up in the root schema
  - **Path** (e.g. "main/docs/plans") — walked through nested schemas

  The `@commit` syntax is deferred and not yet supported.

  ## Usage

      Docref.resolve("550e8400-e29b-41d4-a716-446655440000", root_uuid: nil, loader: nil)
      # => {:ok, "550e8400-e29b-41d4-a716-446655440000"}

      Docref.resolve("main", root_uuid: root_uuid, loader: loader_fn)
      # => {:ok, "uuid-for-main"}

      Docref.resolve("main/docs/plans", root_uuid: root_uuid, loader: loader_fn)
      # => {:ok, "uuid-for-plans"}
  """

  alias Commonplace.Tree.Walk

  @uuid_regex ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

  @doc """
  Resolve a docref string to a UUID.

  Options:
  - `:root_uuid` — UUID of the root schema document
  - `:loader` — function `(uuid) -> Yelixer.Doc` that loads a schema doc

  Returns `{:ok, uuid}` or `{:error, reason}`.
  """
  def resolve(ref, opts) when is_binary(ref) do
    ref = String.trim(ref)

    cond do
      ref == "" ->
        {:error, :empty_ref}

      uuid?(ref) ->
        {:ok, ref}

      true ->
        resolve_by_path(ref, opts)
    end
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
