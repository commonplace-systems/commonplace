defmodule Commonplace.View.ArgResolver do
  @moduledoc """
  CX-azwh (sub-bead i of CX-04d8 M3): substrate-tier resolver for the
  declarative `<arg name="..." from="..."/>` sub-element form on view
  `<action>` declarations.

  Generic across view kinds — chat is one consumer; future view types
  reuse the same primitive without modification.

  ## Three enumerated resolver kinds

  | from | meaning |
  |---|---|
  | `..` | parent dir basename of `view_path` (e.g. `/chat/general/_view.xml` → `general`) |
  | `../{name}` | sibling-doc-by-relative-name lookup (returns sibling's UUID via `sibling_resolver`) |
  | `$session.{key}` | reads `context[key]` (string key first, falling back to existing atom) |

  Anything else returns `{:error, _}`.

  ## Caller-wins maybe_put semantics (M1 banked lesson)

  If the caller's `supplied_args` already contains a key the resolver
  would set, the caller's value wins. Resolver only fills gaps.

  Resolved values that are nil are silently dropped (the arg is omitted
  from the output map, not inserted as nil) — matches M1's
  `maybe_resolve` behavior so missing session keys don't pollute the
  args with null entries.

  ## Sibling resolver injection

  The `../{name}` kind needs a workspace-aware lookup. By default this
  uses `Commonplace.Workspace.root_uuid/0` + `Commonplace.Tree.Walk` +
  `Commonplace.Tree.Schema.get_entry/2` (the same path M1's chat
  resolver used). Tests pass `opts: [sibling_resolver: fn parent, name -> ... end]`
  to substitute a stub.
  """

  alias Commonplace.Document.ViewXml
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.{DocBuilder, Schema, Walk}
  alias Commonplace.Workspace

  @type sibling_resolver :: (String.t(), String.t() -> {:ok, term()} | {:error, term()})

  @doc """
  Resolve the `<arg from="..."/>` declarations on `action_node`.

  Returns `{:ok, resolved_args}` where the keys are the `<arg name>`
  attributes (strings) merged with `supplied_args`. Returns
  `{:error, reason}` on bad `from` syntax, missing `view_path` for
  `..` / `../{name}` kinds, or sibling-resolver failure.
  """
  @spec resolve(
          ViewXml.Node.t(),
          %{optional(String.t()) => term()},
          map(),
          keyword()
        ) :: {:ok, map()} | {:error, String.t() | term()}
  def resolve(action_node, supplied_args, context, opts \\ [])

  def resolve(%ViewXml.Node{tag: :action} = action, supplied_args, context, opts)
      when is_map(supplied_args) and is_map(context) do
    sibling_resolver = Keyword.get(opts, :sibling_resolver, &default_sibling_resolver/2)
    decls = collect_arg_declarations(action)

    Enum.reduce_while(decls, {:ok, supplied_args}, fn {name, from}, {:ok, acc} ->
      cond do
        Map.has_key?(acc, name) ->
          {:cont, {:ok, acc}}

        true ->
          case resolve_from(from, context, sibling_resolver) do
            {:ok, nil} -> {:cont, {:ok, acc}}
            {:ok, value} -> {:cont, {:ok, Map.put(acc, name, value)}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
      end
    end)
  end

  # --- Private ---

  defp collect_arg_declarations(%ViewXml.Node{children: children}) do
    Enum.flat_map(children, fn
      %ViewXml.Node{tag: :arg, attrs: %{"name" => name, "from" => from}} -> [{name, from}]
      _ -> []
    end)
  end

  defp resolve_from("..", context, _sibling_resolver) do
    case Map.get(context, :view_path) do
      path when is_binary(path) and path != "" ->
        {:ok, path |> Path.dirname() |> Path.basename()}

      _ ->
        {:error, "..: view_path missing or empty in context"}
    end
  end

  defp resolve_from("../" <> name, context, sibling_resolver)
       when is_binary(name) and name != "" do
    case Map.get(context, :view_path) do
      path when is_binary(path) and path != "" ->
        sibling_resolver.(Path.dirname(path), name)

      _ ->
        {:error, "../#{name}: view_path missing or empty in context"}
    end
  end

  defp resolve_from("$session." <> key, context, _sibling_resolver)
       when is_binary(key) and key != "" do
    {:ok, lookup_session_key(context, key)}
  end

  defp resolve_from(other, _context, _sibling_resolver) do
    {:error, "unknown arg-from syntax: #{inspect(other)}"}
  end

  # Try string key first; fall back to existing atom key. Avoids the
  # String.to_atom/1 footgun (atom-table exhaustion from arbitrary input).
  defp lookup_session_key(context, key) do
    case Map.fetch(context, key) do
      {:ok, value} ->
        value

      :error ->
        try do
          Map.get(context, String.to_existing_atom(key))
        rescue
          ArgumentError -> nil
        end
    end
  end

  defp default_sibling_resolver(parent_path, name) do
    with {:ok, root_uuid} <- Workspace.root_uuid(),
         loader = &load_schema_for_walk/1,
         {:ok, parent_uuid} <- Walk.resolve_path(root_uuid, parent_path, loader) do
      doc = loader.(parent_uuid)

      case Schema.get_entry(doc, name) do
        {:ok, entry} -> {:ok, entry.node_id}
        :error -> {:error, {:no_sibling, name}}
      end
    end
  end

  defp load_schema_for_walk(uuid) do
    case DocBuilder.reconstruct_snapshot(CommitStoreClient, uuid) do
      {:ok, doc} -> doc
      :none -> Schema.new_schema()
    end
  end
end
