defmodule CommonplaceCubDBReadPerimeter do
  @moduledoc false

  # BUILD-2a's load-bearing half: the source guard that makes the
  # CommitReader seam real. It fails CI when PRODUCT code reaches CubDB
  # directly — either a `CubDB.<fn>(...)` call, or a
  # `CommitStore.db_handle/1` call (the escape hatch that hands out the raw
  # `CubDB.t()`) — OUTSIDE the storage adapter. A chokepoint product code can
  # bypass is decoration; this is what turns "we have a reader" into "reads
  # MUST go through the reader," the only version that survives a year of new
  # callers.
  #
  # This is the READ perimeter. Its sibling
  # `check_commonplace_commit_row_writes.exs` is the WRITE perimeter (guards
  # `{:commit, id}` row writes). Two single-purpose checkers, not one.
  #
  # ── Why AST, not grep ──────────────────────────────────────────────────
  # It parses each source and matches CALL nodes, so a `CubDB.` mention in a
  # comment or `@doc`/`@moduledoc` string is not a violation (measured
  # 2026-08-21: `commonplace.ex`, `tree/doc_builder.ex`, `gold/chain.ex` all
  # name CubDB in prose; none is an access). A grep would flag all three.
  #
  # ── Why every umbrella app, not just `commonplace` ─────────────────────
  # Carried verbatim from the write perimeter's hard-won lesson (2026-08-09):
  # with the glob scoped to one app, an identical violation placed in another
  # app PASSED while the same code in `commonplace` was caught. A control that
  # can only fire where the guard already looks says nothing about the guard's
  # boundary. So the glob is `apps/*/lib`, and the read-perimeter test injects
  # its violation into `commonplace_web` to exercise exactly that boundary.
  @source_glob ["apps", "*", "lib", "**", "*.ex"]

  # The allowlist is a DIRECTORY prefix + one named file, NOT an enumeration
  # of every allowed access site. Deliberate: the adapter cluster holds ~134
  # legitimate CubDB access lines; enumerating each would be a count-to-bump
  # that goes red on correct refactors inside the adapter. Assert the PROPERTY
  # ("only the adapter + named migration tooling may touch CubDB"), not named
  # instances.
  #
  #   * `apps/commonplace/lib/commonplace/store/` — the storage adapter. It
  #     OWNS the CubDB handle and defines `db_handle/1`; raw access here is the
  #     whole point of the layer.
  #   * `mixed_plane_history_fixture.ex` — the `@moduledoc false` incident
  #     fixture (migration/repair tooling), already an allowlisted WRITER in
  #     the sibling checker: it mints exact content-addressed ids and
  #     hand-rolls the index. Not product surface.
  @adapter_prefix "apps/commonplace/lib/commonplace/store/"
  @allowed_files [
    "apps/commonplace/lib/commonplace/projection/mixed_plane_history_fixture.ex"
  ]

  def run(root) do
    root = Path.expand(root)

    findings =
      @source_glob
      |> then(&Path.join([root | &1]))
      |> Path.wildcard()
      |> Enum.sort()
      |> Enum.reduce(%{violations: [], allowed: [], parse_errors: []}, &scan_file(&1, root, &2))

    errors = boundary_errors(findings)

    case errors do
      [] ->
        IO.puts("commonplace cubdb read-perimeter check passed")
        IO.puts("adapter prefix: #{@adapter_prefix}")

        Enum.each(@allowed_files, &IO.puts("allowed file: #{&1}"))

        # Positive control: the count of allowed adapter access sites the
        # scanner actually saw. A green with ZERO here would mean the scanner
        # matched no CubDB access at all — blind, not clean — so the test
        # asserts this is > 0 (the corpus was non-empty and the classifier
        # fired). It is a count REPORTED, never a count asserted-by-equality.
        IO.puts("allowed adapter access sites: #{length(findings.allowed)}")
        :ok

      errors ->
        IO.puts(:stderr, "commonplace cubdb read-perimeter check failed")
        Enum.each(errors, &IO.puts(:stderr, &1))
        :error
    end
  end

  defp scan_file(path, root, findings) do
    relative_path = Path.relative_to(path, root)
    allowed_location? = allowed_location?(relative_path)

    case path |> File.read!() |> Code.string_to_quoted(columns: true) do
      {:ok, ast} ->
        walk(ast, relative_path, nil, allowed_location?, findings)

      {:error, error} ->
        update_in(findings.parse_errors, &[{relative_path, error} | &1])
    end
  end

  defp allowed_location?(relative_path) do
    String.starts_with?(relative_path, @adapter_prefix) or relative_path in @allowed_files
  end

  # Track the enclosing function name for legible findings, then recurse.
  defp walk({kind, _meta, [head, body]}, path, _function, allowed?, findings)
       when kind in [:def, :defp] do
    function = function_name(head)
    walk(body, path, function, allowed?, findings)
  end

  defp walk(node, path, function, allowed?, findings) do
    findings = classify(node, path, function, allowed?, findings)

    case node do
      {_, _meta, args} when is_list(args) ->
        Enum.reduce(args, findings, &walk(&1, path, function, allowed?, &2))

      {left, right} ->
        findings
        |> then(&walk(left, path, function, allowed?, &1))
        |> then(&walk(right, path, function, allowed?, &1))

      list when is_list(list) ->
        Enum.reduce(list, findings, &walk(&1, path, function, allowed?, &2))

      _ ->
        findings
    end
  end

  defp classify(node, path, function, allowed?, findings) do
    case raw_access(node) do
      nil ->
        findings

      shape ->
        entry = %{path: path, function: function, line: ast_line(node), shape: shape}

        if allowed? do
          update_in(findings.allowed, &[entry | &1])
        else
          update_in(findings.violations, &[entry | &1])
        end
    end
  end

  # A direct `CubDB.<fn>(...)` call.
  defp raw_access(
         {{:., _dot_meta, [{:__aliases__, _alias_meta, [:CubDB]}, fun]}, _call_meta, _args}
       )
       when is_atom(fun),
       do: {:cubdb, fun}

  # A `CommitStore.db_handle(...)` call — the escape hatch that hands out the
  # raw CubDB handle. Matched on the aliased module's LAST segment so both
  # `CommitStore.db_handle` and `Commonplace.Store.CommitStore.db_handle`
  # (and any test alias ending in `CommitStore`) are caught.
  defp raw_access(
         {{:., _dot_meta, [{:__aliases__, _alias_meta, segments}, :db_handle]}, _call_meta, _args}
       ) do
    if List.last(segments) == :CommitStore, do: {:db_handle, :escape_hatch}, else: nil
  end

  defp raw_access(_node), do: nil

  defp boundary_errors(findings) do
    parse_errors =
      Enum.map(findings.parse_errors, fn {path, error} ->
        "#{path}: could not parse source: #{inspect(error)}"
      end)

    violations =
      findings.violations
      |> Enum.sort_by(&{&1.path, &1.line})
      |> Enum.map(fn v ->
        case v.shape do
          {:cubdb, fun} ->
            "#{v.path}:#{v.line}:#{v.function}/…: unexpected raw CubDB access (CubDB.#{fun}) " <>
              "outside the storage adapter — route through CommitReader/CommitStoreClient"

          {:db_handle, :escape_hatch} ->
            "#{v.path}:#{v.line}:#{v.function}/…: unexpected CommitStore.db_handle/1 escape hatch " <>
              "outside the storage adapter — route through CommitReader/CommitStoreClient"
        end
      end)

    Enum.sort(parse_errors ++ violations)
  end

  defp function_name({:when, _meta, [head | _guards]}), do: function_name(head)

  defp function_name({name, _meta, args}) when is_atom(name) and is_list(args),
    do: Atom.to_string(name)

  defp function_name(_head), do: "unknown"

  defp ast_line({_, meta, _args} = node) when is_list(meta) do
    node |> collect_lines([]) |> Enum.min(fn -> 0 end)
  end

  defp ast_line(_node), do: 0

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

case CommonplaceCubDBReadPerimeter.run(root) do
  :ok -> System.halt(0)
  :error -> System.halt(1)
end
