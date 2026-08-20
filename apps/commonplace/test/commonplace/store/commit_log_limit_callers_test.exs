defmodule Commonplace.Store.CommitLogLimitCallersTest do
  @moduledoc """
  Keeps every commit-history walk's bound visible at its call site.

  This is an alias-resolved AST scan, not a text search: private namesakes are
  ignored, while calls through aliases and fully-qualified module names are
  attributed to the two commit-log APIs.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../../../..", __DIR__)

  @targets MapSet.new([
             [:Commonplace, :Store, :CommitStore],
             [:Commonplace, :Store, :CommitStoreClient]
           ])

  # Freeze-list rule: this ONE allowlist may only shrink, or gain an entry with
  # a call-site-specific reason; an unexplained entry is a lint bypass, not
  # maintenance. Line pins deliberately make every call site
  # independently reviewable, at the accepted cost that source reflow must
  # update a pin without changing its reason.
  @unbounded_allowlist %{
    {"apps/commonplace/lib/commonplace/reflog/restore.ex", 175} =>
      "legacy checkpoint-listing API; frozen for a separately reasoned paging migration",
    {"apps/commonplace/test/commonplace/bd/freeze_pin_test.exs", 66} =>
      "fixture creates only the issue create/close history used by this assertion",
    {"apps/commonplace/test/commonplace/bd/ticket_create_import_verbs_test.exs", 444} =>
      "fixture compares a two-operation no-op history",
    {"apps/commonplace/test/commonplace/bd/ticket_create_import_verbs_test.exs", 450} =>
      "fixture compares a two-operation no-op history",
    {"apps/commonplace/test/commonplace/bd/ticket_create_import_verbs_test.exs", 679} =>
      "fixture searches the just-created imported-close history",
    {"apps/commonplace/test/commonplace/bd/ticket_create_import_verbs_test.exs", 697} =>
      "fixture searches the just-created imported-open history",
    {"apps/commonplace/test/commonplace/bd/ticket_create_import_verbs_test.exs", 707} =>
      "helper searches the single-import history created by its caller",
    {"apps/commonplace/test/commonplace/federation/pull_client_test.exs", 309} =>
      "fixture asserts an exactly two-commit pulled history",
    {"apps/commonplace/test/commonplace/green/bursar_test.exs", 517} =>
      "scale fixture intentionally measures its bounded generated history",
    {"apps/commonplace/test/commonplace/reflog/snapshot_test.exs", 172} =>
      "fixture asserts genesis plus one checkpoint",
    {"apps/commonplace/test/commonplace/reflog/snapshot_test.exs", 372} =>
      "fixture asserts genesis plus two checkpoints",
    {"apps/commonplace/test/commonplace/reflog/snapshot_test.exs", 523} =>
      "fixture compares a locally generated checkpoint history before churn",
    {"apps/commonplace/test/commonplace/reflog/snapshot_test.exs", 541} =>
      "fixture compares the same locally generated checkpoint history after churn",
    {"apps/commonplace/test/commonplace/snapshot_sweeper_test.exs", 99} =>
      "fixture seeds five commits before checking for a snapshot",
    {"apps/commonplace/test/commonplace/snapshot_sweeper_test.exs", 104} =>
      "fixture seeds one commit before checking snapshot absence",
    {"apps/commonplace/test/commonplace/snapshot_sweeper_test.exs", 142} =>
      "polling fixture seeds five commits before checking for a snapshot",
    {"apps/commonplace/test/commonplace/store/commit_store_branch_test.exs", 31} =>
      "fixture asserts an exactly three-commit cross-document chain",
    {"apps/commonplace/test/commonplace/store/commit_store_telemetry_test.exs", 154} =>
      "single-commit fixture only proves the read emits no write telemetry",
    {"apps/commonplace/test/commonplace/store/commit_store_test.exs", 100} =>
      "two-commit fixture only proves reads remain available while the server is suspended",
    {"apps/commonplace/test/commonplace/sync/entry_agent_test.exs", 293} =>
      "fixture compares a short generated history after its first sync",
    {"apps/commonplace/test/commonplace/sync/entry_agent_test.exs", 303} =>
      "fixture compares the same short generated history after its third sync",
    {"apps/commonplace/test/commonplace/tree/doc_builder_lazy_snapshot_test.exs", 65} =>
      "polling helper is used only with locally seeded sub-100-commit histories",
    {"apps/commonplace/test/commonplace/tree/doc_builder_lazy_snapshot_test.exs", 85} =>
      "fixture seeds six commits before checking pre-snapshot state",
    {"apps/commonplace/test/commonplace/tree/doc_builder_lazy_snapshot_test.exs", 102} =>
      "fixture seeds three commits before checking snapshot absence",
    {"apps/commonplace/test/commonplace/tree/fork_test.exs", 71} =>
      "fixture searches a locally generated shallow fork history",
    {"apps/commonplace/test/commonplace/tree/pending_remove_discriminator_test.exs", 119} =>
      "fixture generates exactly seventeen content commits",
    {"apps/commonplace_bots/test/commonplace/bots/note_doc_concurrent_append_test.exs", 316} =>
      "diagnostic corpus fixture generates fewer than one hundred reachable commits"
  }

  test "commit_log calls carry an explicit :limit or a reasoned exception" do
    files = source_files()

    assert length(files) > 500,
           "the commit-log scan found only #{length(files)} source files; refusing a vacuous result"

    unbounded = unbounded_calls(files)
    actual_sites = unbounded |> Enum.map(& &1.site) |> MapSet.new()
    allowed_sites = @unbounded_allowlist |> Map.keys() |> MapSet.new()

    assert Enum.all?(@unbounded_allowlist, fn {_site, reason} ->
             is_binary(reason) and String.trim(reason) != ""
           end),
           "every unbounded allowlist entry must carry a reason"

    assert actual_sites == allowed_sites,
           """
           unbounded commit-log callers changed.

           Offending callsites:
           #{format_calls(unbounded, MapSet.difference(actual_sites, allowed_sites))}

           Missing allowlisted callsites:
           #{format_sites(MapSet.difference(allowed_sites, actual_sites))}
           """
  end

  test "callee resolution keeps aliases and rejects namesakes and store internals" do
    source = """
    defmodule SyntheticCaller do
      alias Commonplace.Store.CommitStoreClient, as: History

      def walk(store), do: History.commit_log(store, "doc")
      defp commit_log(_store, _doc), do: []
      def private_namesake(store), do: commit_log(store, "doc")
    end

    defmodule Commonplace.Store.CommitStoreClient do
      def commit_log(server, doc_uuid, opts), do: []
      def delegate(server, doc_uuid, opts) do
        Commonplace.Store.CommitStore.commit_log(server, doc_uuid, opts)
      end
    end
    """

    assert [%{callee: "Commonplace.Store.CommitStoreClient.commit_log"}] =
             unbounded_calls_in(source, "synthetic_alias_fixture.ex")
  end

  defp source_files do
    ["apps/*/lib/**/*.ex", "apps/*/test/**/*.exs"]
    |> Enum.flat_map(&Path.wildcard(Path.join(@root, &1)))
    |> Enum.sort()
  end

  defp unbounded_calls(files) do
    Enum.flat_map(files, fn path ->
      path
      |> File.read!()
      |> unbounded_calls_in(path)
    end)
  end

  defp unbounded_calls_in(source, path) do
    ast = Code.string_to_quoted!(source, columns: true)
    initial_state = %{aliases: %{}, module: nil}
    {calls, _state} = scan(ast, initial_state, path)
    calls
  end

  defp scan({:__block__, _meta, forms}, state, path) do
    Enum.reduce(forms, {[], state}, fn form, {calls, current_state} ->
      {new_calls, next_state} = scan(form, current_state, path)
      {calls ++ new_calls, next_state}
    end)
  end

  defp scan({:alias, _meta, arguments}, state, _path) do
    {[], %{state | aliases: add_aliases(state.aliases, arguments)}}
  end

  defp scan({:defmodule, _meta, [module_ast | body]}, state, path) do
    inner_state = %{state | module: resolve_module(module_ast, state.aliases)}
    {calls, _inner_state} = scan(body, inner_state, path)
    {calls, state}
  end

  defp scan({kind, _meta, [_head | body]}, state, path)
       when kind in [:def, :defp, :defmacro, :defmacrop] do
    {calls, _inner_state} = scan(body, state, path)
    {calls, state}
  end

  defp scan(
         {{:., _dot_meta, [module_ast, function]}, call_meta, arguments},
         state,
         path
       )
       when function in [:commit_log, :commit_log_from] and is_list(arguments) do
    module = resolve_module(module_ast, state.aliases)

    call =
      if MapSet.member?(@targets, module) and
           not MapSet.member?(@targets, state.module) and
           not explicit_limit?(arguments) do
        relative_path = Path.relative_to(path, @root)

        [
          %{
            site: {relative_path, Keyword.fetch!(call_meta, :line)},
            callee: "#{inspect_module(module)}.#{function}"
          }
        ]
      else
        []
      end

    {nested_calls, _state} = scan(arguments, state, path)
    {call ++ nested_calls, state}
  end

  defp scan(tuple, state, path) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> scan(state, path)
  end

  defp scan(list, state, path) when is_list(list) do
    Enum.reduce(list, {[], state}, fn item, {calls, current_state} ->
      {new_calls, next_state} = scan(item, current_state, path)
      {calls ++ new_calls, next_state}
    end)
  end

  defp scan(_other, state, _path), do: {[], state}

  defp explicit_limit?(arguments) do
    case List.last(arguments) do
      options when is_list(options) -> Keyword.has_key?(options, :limit)
      _other -> false
    end
  end

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

  defp inspect_module(parts), do: Enum.map_join(parts, ".", &Atom.to_string/1)

  defp format_calls(calls, selected_sites) do
    calls
    |> Enum.filter(&MapSet.member?(selected_sites, &1.site))
    |> Enum.sort_by(& &1.site)
    |> Enum.map_join("\n", fn %{site: {file, line}, callee: callee} ->
      "  #{file}:#{line} (#{callee})"
    end)
    |> empty_as_none()
  end

  defp format_sites(sites) do
    sites
    |> Enum.sort()
    |> Enum.map_join("\n", fn {file, line} -> "  #{file}:#{line}" end)
    |> empty_as_none()
  end

  defp empty_as_none(""), do: "  (none)"
  defp empty_as_none(formatted), do: formatted
end
