defmodule CommonplaceCommitRowBoundary do
  @moduledoc false

  # Only production sources are in this perimeter. Test modules are deliberately
  # excluded: they are not shipped application code, and some tests must seed
  # impossible content-addressed ids directly (then mark the index dirty) to
  # exercise startup repair. Treating those harness writes as production trust
  # sites would hide the boundary this checker exists to protect.
  # ⛔ EVERY UMBRELLA APP, not just `commonplace`. Measured 2026-08-09: with the
  # glob scoped to apps/commonplace/lib, an identical stray commit-row write
  # placed in apps/commonplace_web/lib PASSED (rc=0) while the same code in
  # apps/commonplace/lib was caught (rc=1). ⇒ The perimeter stopped at one app,
  # and the tamper control could not reveal it because the control injects into
  # the app the guard already scans — a control that can only fire where the
  # guard already looks says nothing about the guard's boundary.
  #
  # No other app writes commit rows today (verified: zero hits for `{{:commit,`
  # across apps/*/lib outside apps/commonplace), so widening is free now and
  # would not be later.
  @source_glob ["apps", "*", "lib", "**", "*.ex"]

  # Every production function allowed to construct a commit row is named here,
  # with both its expected cardinality and the reason it cannot bypass the
  # per-document index. This is a trust-surface enumeration, not a count to bump.
  @allowed_writers %{
    {"apps/commonplace/lib/commonplace/store/commit_store.ex", "commit_rows"} => %{
      count: 1,
      justification:
        "the private persistence choke returns the commit row and its index row as one pair"
    },
    {"apps/commonplace/lib/commonplace/projection/mixed_plane_history_fixture.ex", "seed!"} => %{
      count: 1,
      justification:
        "the incident fixture must mint exact content-addressed ids and hand-rolls the index in the same put_multi"
    }
  }

  def run(root) do
    root = Path.expand(root)

    findings =
      @source_glob
      |> then(&Path.join([root | &1]))
      |> Path.wildcard()
      |> Enum.sort()
      |> Enum.reduce(%{writers: [], readers: [], parse_errors: []}, &scan_file(&1, root, &2))

    errors = boundary_errors(findings)

    case errors do
      [] ->
        IO.puts("commonplace commit-row boundary check passed")

        @allowed_writers
        |> Enum.sort()
        |> Enum.each(fn {{path, function}, %{justification: justification}} ->
          IO.puts("allowed writer #{path}:#{function}/… — #{justification}")
        end)

        findings.readers
        |> Enum.sort_by(&{&1.path, &1.line})
        |> Enum.each(fn reader ->
          IO.puts(
            "ignored read pattern #{reader.path}:#{reader.line}:#{reader.function}/… — pattern match, not a write"
          )
        end)

        :ok

      errors ->
        IO.puts(:stderr, "commonplace commit-row boundary check failed")
        Enum.each(errors, &IO.puts(:stderr, &1))
        :error
    end
  end

  defp scan_file(path, root, findings) do
    relative_path = Path.relative_to(path, root)

    case path |> File.read!() |> Code.string_to_quoted(columns: true) do
      {:ok, ast} -> walk(ast, relative_path, nil, :expression, false, findings)
      {:error, error} -> update_in(findings.parse_errors, &[{relative_path, error} | &1])
    end
  end

  defp walk({kind, _meta, [head, body]}, path, _function, :expression, _paired?, findings)
       when kind in [:def, :defp] do
    function = function_name(head)
    findings = walk(head, path, function, :pattern, false, findings)
    walk(body, path, function, :expression, false, findings)
  end

  defp walk({:->, _meta, [patterns, body]}, path, function, _context, _paired?, findings) do
    findings = walk(patterns, path, function, :pattern, false, findings)
    walk(body, path, function, :expression, false, findings)
  end

  defp walk({operator, _meta, [left, right]}, path, function, _context, _paired?, findings)
       when operator in [:=, :<-] do
    findings = walk(left, path, function, :pattern, false, findings)
    walk(right, path, function, :expression, false, findings)
  end

  defp walk(list, path, function, context, _paired?, findings) when is_list(list) do
    paired? =
      context == :expression and Enum.any?(list, &commit_row?/1) and
        Enum.any?(list, &doc_commit_index_row?/1)

    Enum.reduce(list, findings, fn child, acc ->
      walk(child, path, function, context, paired?, acc)
    end)
  end

  defp walk(node, path, function, context, paired?, findings) do
    findings = classify(node, path, function, context, paired?, findings)

    case node do
      tuple when is_tuple(tuple) ->
        tuple
        |> Tuple.to_list()
        |> Enum.reduce(findings, fn child, acc ->
          walk(child, path, function, context, paired?, acc)
        end)

      _ ->
        findings
    end
  end

  defp classify(node, path, function, :pattern, _paired?, findings) do
    if commit_row?(node) do
      update_in(findings.readers, &[%{path: path, function: function, line: ast_line(node)} | &1])
    else
      findings
    end
  end

  defp classify(node, path, function, :expression, paired?, findings) do
    cond do
      commit_row?(node) ->
        add_writer(findings, path, function, ast_line(node), paired?, :row)

      direct_commit_put?(node) ->
        add_writer(findings, path, function, ast_line(node), false, :direct_put)

      true ->
        findings
    end
  end

  defp add_writer(findings, path, function, line, paired?, shape) do
    writer = %{path: path, function: function, line: line, paired?: paired?, shape: shape}
    update_in(findings.writers, &[writer | &1])
  end

  defp boundary_errors(findings) do
    parse_errors =
      Enum.map(findings.parse_errors, fn {path, error} ->
        "#{path}: could not parse source: #{inspect(error)}"
      end)

    unexpected_or_unpaired =
      Enum.flat_map(findings.writers, fn writer ->
        key = {writer.path, writer.function}

        cond do
          not Map.has_key?(@allowed_writers, key) ->
            [format_writer(writer, "unexpected commit-row write")]

          not writer.paired? ->
            [format_writer(writer, "allowed writer does not bundle a doc-commit index row")]

          true ->
            []
        end
      end)

    missing_or_duplicated =
      Enum.flat_map(@allowed_writers, fn {{path, function}, %{count: expected}} ->
        actual = Enum.count(findings.writers, &(&1.path == path and &1.function == function))

        if actual == expected do
          []
        else
          [
            "#{path}:#{function}/…: allowed writer count changed; expected #{expected}, found #{actual}"
          ]
        end
      end)

    Enum.sort(parse_errors ++ unexpected_or_unpaired ++ missing_or_duplicated)
  end

  defp format_writer(writer, message) do
    "#{writer.path}:#{writer.line}:#{writer.function}/…: #{message} (#{writer.shape})"
  end

  defp function_name({:when, _meta, [head | _guards]}), do: function_name(head)

  defp function_name({name, _meta, args}) when is_atom(name) and is_list(args),
    do: Atom.to_string(name)

  defp function_name(_head), do: "unknown"

  defp commit_row?({{:commit, _id}, _value}), do: true
  defp commit_row?(_node), do: false

  defp doc_commit_index_row?({{:{}, _meta, [:doc_commit, _doc_uuid, _id]}, _value}),
    do: true

  defp doc_commit_index_row?(_node), do: false

  defp direct_commit_put?(
         {{:., _dot_meta, [{:__aliases__, _alias_meta, [:CubDB]}, :put]}, _call_meta,
          [_db, {:commit, _id}, _value]}
       ),
       do: true

  defp direct_commit_put?(_node), do: false

  defp ast_line(node) do
    node
    |> collect_lines([])
    |> Enum.min(fn -> 0 end)
  end

  defp collect_lines({_, meta, args}, acc) when is_list(meta) do
    acc = if line = meta[:line], do: [line | acc], else: acc
    collect_lines(args, acc)
  end

  defp collect_lines(tuple, acc) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> Enum.reduce(acc, &collect_lines/2)
  end

  defp collect_lines(list, acc) when is_list(list), do: Enum.reduce(list, acc, &collect_lines/2)
  defp collect_lines(_node, acc), do: acc
end

root = System.argv() |> List.first() |> then(&(&1 || File.cwd!()))

case CommonplaceCommitRowBoundary.run(root) do
  :ok -> System.halt(0)
  :error -> System.halt(1)
end
