defmodule Commonplace.Test.RowKeyWriteScanner do
  @moduledoc """
  Shared AST scanner for "this keyspace row is WRITTEN in exactly one seam"
  source invariants (the choke tests: `{:latest, _}` head pointer,
  `{:accepted_heads, _}` head set, and any future sibling).

  ## Why this exists (CX class-hardening 2026-08-21)

  These invariants used per-test line-text matchers keyed on a line's shape —
  "contains `{:key,` and (`CubDB.put` or starts-with `{{:key,`)". That cannot
  distinguish a WRITE row `[{{:key, u}, v}]` from a READ destructure
  `{{:key, u}, _} -> …` when the pattern sits on its own line: BUILD-1's
  World-B population_scan tripped exactly that false positive, and every such
  matcher carried the same latent bug. This classifies by AST **context**
  (pattern vs expression) instead, so a read is never mistaken for a write
  regardless of source layout — and it lives in one place so the next choke
  reuses it rather than re-deriving the fragile form.

  A WRITE of `{key, _}` is either:

    * a `{{key, _}, _}` row literal in EXPRESSION context (a put_multi row —
      whether written inline or spliced in as a `rows ++ [...]` list), or
    * a `CubDB.put(db, {key, _}, _)` call.

  Everything else — `CubDB.get(db, {key, _})`, `min_key:`/`max_key:` range
  bounds (`{key, ""}` is atom-first, not the nested row shape), and any
  `{{key, _}, _}` in PATTERN context (a `fn`/`case`/reduce clause or a match
  LHS) — is a read and is not flagged.
  """

  @doc """
  Every `{key, _}` write site in the lib tree under `lib_root`, as maps with
  `:file`, `:line`, `:function`, `:shape`, `:text`.
  """
  def writes_under(lib_root, key) when is_atom(key) do
    Path.join(lib_root, "**/*.ex")
    |> Path.wildcard(match_dot: false)
    |> Enum.flat_map(&writes_in_file(&1, key))
  end

  @doc "Every `{key, _}` write site in one source file."
  def writes_in_file(path, key) when is_atom(key) do
    source = File.read!(path)
    lines = String.split(source, "\n")

    case Code.string_to_quoted(source, columns: true) do
      {:ok, ast} ->
        ast
        |> collect(key, nil, :expression, [])
        |> Enum.reverse()
        |> Enum.map(fn %{line: line} = w ->
          Map.merge(w, %{file: path, text: Enum.at(lines, line - 1, "")})
        end)

      {:error, {meta, message, token}} ->
        # A lib file that will not parse is itself a failure a source scan must
        # surface, not swallow into a false green.
        [
          %{
            file: path,
            line: Keyword.get(meta, :line, 0),
            function: "<parse-error>",
            shape: :parse_error,
            text: "#{message}#{token}"
          }
        ]
    end
  end

  @doc "Classify a source STRING — the seam control tests drive this directly."
  def writes_in_source(source, key) when is_atom(key) do
    {:ok, ast} = Code.string_to_quoted(source, columns: true)
    ast |> collect(key, nil, :expression, []) |> Enum.reverse()
  end

  # `def`/`defp` heads are patterns, bodies are expressions.
  defp collect({kind, _meta, [head, body]}, key, _function, _context, acc)
       when kind in [:def, :defp, :defmacro, :defmacrop] do
    function = function_name(head)
    acc = collect(head, key, function, :pattern, acc)
    collect(body, key, function, :expression, acc)
  end

  # `->` clauses: left side is a pattern, body an expression.
  defp collect({:->, _meta, [patterns, body]}, key, function, _context, acc) do
    acc = collect(patterns, key, function, :pattern, acc)
    collect(body, key, function, :expression, acc)
  end

  # `=` and `<-`: left is a pattern, right an expression.
  defp collect({op, _meta, [lhs, rhs]}, key, function, _context, acc)
       when op in [:=, :<-] do
    acc = collect(lhs, key, function, :pattern, acc)
    collect(rhs, key, function, :expression, acc)
  end

  defp collect(node, key, function, context, acc) do
    acc = classify(node, key, function, context, acc)

    cond do
      is_tuple(node) ->
        node |> Tuple.to_list() |> Enum.reduce(acc, &collect(&1, key, function, context, &2))

      is_list(node) ->
        Enum.reduce(node, acc, &collect(&1, key, function, context, &2))

      true ->
        acc
    end
  end

  # `{{key, _}, _}` row literal in EXPRESSION context = a put_multi row (write).
  # The same shape in PATTERN context is a destructure (read) and never reaches
  # here in :expression.
  defp classify({{k, _}, _} = node, key, function, :expression, acc)
       when is_atom(k) and k == key do
    [%{line: node_line(node), function: function, shape: :put_multi_row} | acc]
  end

  # A direct `CubDB.put(db, {key, _}, _)` call.
  defp classify(
         {{:., _dot, [{:__aliases__, _am, [:CubDB]}, :put]}, _cm, [_db, {k, _} | _]} = node,
         key,
         function,
         :expression,
         acc
       )
       when is_atom(k) and k == key do
    [%{line: node_line(node), function: function, shape: :cubdb_put} | acc]
  end

  defp classify(_node, _key, _function, _context, acc), do: acc

  defp function_name({:when, _meta, [head | _guards]}), do: function_name(head)

  defp function_name({name, _meta, args}) when is_atom(name) and is_list(args),
    do: Atom.to_string(name)

  defp function_name(_head), do: "unknown"

  defp node_line(node), do: node |> lines([]) |> Enum.min(fn -> 0 end)

  defp lines({_, meta, args}, acc) when is_list(meta) do
    acc = if line = meta[:line], do: [line | acc], else: acc
    lines(args, acc)
  end

  defp lines(tuple, acc) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.reduce(acc, &lines/2)

  defp lines(list, acc) when is_list(list), do: Enum.reduce(list, acc, &lines/2)
  defp lines(_node, acc), do: acc
end
