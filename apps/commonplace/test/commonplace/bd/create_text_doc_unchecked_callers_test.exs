defmodule Commonplace.Bd.CreateTextDocUncheckedCallersTest do
  @moduledoc """
  CX-3vgy keeps every call to the unchecked text-document creator enumerable.

  This is an AST scan rather than a name scan: aliases are resolved before a
  remote call is attributed to `Commonplace.Bd.Schemas`. That distinction keeps
  private, same-named helpers out while retaining calls nested inside wrappers.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../../../..", __DIR__)
  @target [:Commonplace, :Bd, :Schemas]

  @unchecked_allowlist MapSet.new([
                         {"apps/commonplace/test/commonplace/bd/frontier_server_test.exs", 84}
                       ])

  test "unchecked text-document creation callers equal the explicit allowlist" do
    files = source_files()

    assert length(files) > 500,
           "the caller scan found only #{length(files)} source files; refusing a vacuous result"

    callers = calls_to(files, :create_text_doc)

    assert callers == @unchecked_allowlist,
           """
           unchecked Commonplace.Bd.Schemas.create_text_doc callers changed.

           Offending callsites:
           #{format_sites(MapSet.difference(callers, @unchecked_allowlist))}

           Missing allowlisted callsites:
           #{format_sites(MapSet.difference(@unchecked_allowlist, callers))}
           """
  end

  test "callee resolution retains the wrapped checked call and rejects the private namesake" do
    files = source_files()
    unchecked = calls_to(files, :create_text_doc)
    checked = calls_to(files, :create_text_doc_checked)

    assert MapSet.member?(
             checked,
             {"apps/commonplace/lib/commonplace/bd/comment.ex", 182}
           ),
           "the wrapped Commonplace.Bd.Schemas call was not resolved"

    assert MapSet.member?(
             checked,
             {"apps/commonplace/lib/commonplace/bd/schemas.ex", 676}
           ),
           "the unqualified self-call inside Commonplace.Bd.Schemas was not resolved"

    refute MapSet.member?(
             unchecked,
             {"apps/commonplace/lib/commonplace/cell/manifest.ex", 153}
           ),
           "the manifest module's private create_text_doc/3 was misattributed to Bd.Schemas"
  end

  defp source_files do
    ["apps/*/lib/**/*.ex", "apps/*/test/**/*.exs"]
    |> Enum.flat_map(&Path.wildcard(Path.join(@root, &1)))
    |> Enum.sort()
  end

  defp calls_to(files, function) do
    files
    |> Enum.flat_map(fn path ->
      ast = path |> File.read!() |> Code.string_to_quoted!(columns: true)
      initial_state = %{aliases: %{}, module: nil}
      {sites, _state} = scan(ast, initial_state, path, function)
      sites
    end)
    |> MapSet.new()
  end

  defp scan({:__block__, _meta, forms}, state, path, function) do
    Enum.reduce(forms, {[], state}, fn form, {sites, current_state} ->
      {new_sites, next_state} = scan(form, current_state, path, function)
      {sites ++ new_sites, next_state}
    end)
  end

  defp scan({:alias, _meta, arguments}, state, _path, _function) do
    {[], %{state | aliases: add_aliases(state.aliases, arguments)}}
  end

  defp scan({:defmodule, _meta, [module_ast | body]}, state, path, function) do
    inner_state = %{state | module: resolve_module(module_ast, state.aliases)}
    {sites, _inner_state} = scan(body, inner_state, path, function)
    {sites, state}
  end

  defp scan({kind, _meta, [_head | body]}, state, path, function)
       when kind in [:def, :defp, :defmacro, :defmacrop] do
    {sites, _inner_state} = scan(body, state, path, function)
    {sites, state}
  end

  defp scan(
         {{:., _dot_meta, [module_ast, function]}, call_meta, arguments},
         state,
         path,
         function
       )
       when is_list(arguments) do
    site =
      if resolve_module(module_ast, state.aliases) == @target do
        [{Path.relative_to(path, @root), Keyword.fetch!(call_meta, :line)}]
      else
        []
      end

    {nested_sites, _state} = scan(arguments, state, path, function)
    {site ++ nested_sites, state}
  end

  defp scan({function, call_meta, arguments}, state, path, function)
       when is_list(arguments) do
    site =
      if state.module == @target do
        [{Path.relative_to(path, @root), Keyword.fetch!(call_meta, :line)}]
      else
        []
      end

    {nested_sites, _state} = scan(arguments, state, path, function)
    {site ++ nested_sites, state}
  end

  defp scan(tuple, state, path, function) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> scan(state, path, function)
  end

  defp scan(list, state, path, function) when is_list(list) do
    Enum.reduce(list, {[], state}, fn item, {sites, current_state} ->
      {new_sites, next_state} = scan(item, current_state, path, function)
      {sites ++ new_sites, next_state}
    end)
  end

  defp scan(_other, state, _path, _function), do: {[], state}

  defp add_aliases(aliases, [alias_ast | options]) do
    case grouped_aliases(alias_ast) do
      [] ->
        full = alias_parts(alias_ast)
        alias_options = Enum.find(options, [], &Keyword.keyword?/1)
        short = alias_options |> Keyword.get(:as) |> alias_parts() |> List.last()
        Map.put(aliases, short || List.last(full), full)

      grouped ->
        Enum.reduce(grouped, aliases, fn full, acc ->
          Map.put(acc, List.last(full), full)
        end)
    end
  end

  defp grouped_aliases(
         {{:., _meta, [{:__aliases__, _alias_meta, prefix}, :{}]}, _call_meta, children}
       ) do
    Enum.map(children, fn child -> prefix ++ alias_parts(child) end)
  end

  defp grouped_aliases(_alias_ast), do: []

  defp resolve_module({:__aliases__, _meta, [first | rest] = parts}, aliases) do
    case Map.fetch(aliases, first) do
      {:ok, prefix} -> prefix ++ rest
      :error -> parts
    end
  end

  defp resolve_module(_module_ast, _aliases), do: nil

  defp alias_parts(nil), do: []
  defp alias_parts({:__aliases__, _meta, parts}), do: parts
  defp alias_parts(_other), do: []

  defp format_sites(sites) do
    case sites
         |> Enum.sort()
         |> Enum.map_join("\n", fn {file, line} -> "  #{file}:#{line}" end) do
      "" -> "  (none)"
      formatted -> formatted
    end
  end
end
