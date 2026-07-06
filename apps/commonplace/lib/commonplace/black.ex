defmodule Commonplace.Black do
  @moduledoc """
  CX-o1l9 (Black M1): the query-verb half of the Compute stdlib — a
  peer of `Commonplace.Compute`, callable from the same execute-gated
  code docs.

  ## The one-sentence model (design brief, commonplace-plan
  `docs/plans/2026-07-06-black-channel-brief.md`)

  Black is not a subsystem: a black query is Elixir code in an
  execute-gated code doc, given three new stdlib capabilities — find
  docs by pattern (`select/3`), read any doc's canonical structure
  (`json/2` / `xml/2`), and emit red (`emit_red/2`) — plus one new
  substrate mechanism, compute docs whose SOURCE is a pattern instead
  of an enumerated UUID list (`Commonplace.Black.PatternCompute`).

  This module owns the one-shot verbs. `PatternCompute` (in
  `Commonplace.Black.PatternCompute`) owns the pattern-scoped
  subscription mechanism piece (ii) of the brief.

  ## Composition claim (brief §4.5, settled fork F2)

  There is deliberately **no dedicated trigger machinery** in Black.
  The brief's output-edge trigger family — "when pattern matches → run
  blue compute / emit red" — falls out of pure composition: a
  `PatternCompute` whose `compute_fn` calls `emit_red/2` at the end IS
  that trigger. No new DSL, no second query language (settled fork F2:
  Black is a PEER in the Elixir-DSL-in-documents — one rainbow DSL).

  ## Black senses, green acts (brief §6)

  Black's verbs are all read-only or signal-only: `select/3` walks and
  matches, `json/2` / `xml/2` render, `emit_red/2` announces. None of
  them acquire anything, hold a lock, or gate concurrent writers — that
  is green's job (bursar acquire/release author forms, CX-vfau, out of
  scope for M1). Black is the sensing half of the author-facing verb
  surface; green is the actuating half. A compute that both senses
  (via `select`/`json`) and acts (by writing a target through
  `PatternCompute`, or announcing via `emit_red`) composes both halves
  in user code — neither half needs to know about the other.

  ## No new trust surface

  The only path by which doc-authored code can call `select/3`,
  `json/2`, `xml/2`, or `emit_red/2` is from inside an execute-gated
  compute (Gate B) — exactly like `Commonplace.Compute`. There is no
  additional capability check here; the gate that already decides
  whether a code doc may execute at all is the entire trust story.

  ## Out of scope for M1 (brief-settled forks, spec §4)

  * Ephemeral/scratch query docs (F3).
  * Secondary indexes (F5 — deferred until measured; `select/3` scans).
  * JSONPath/XPath predicate strings (F2 residue) — `json/2` gives a
    stable decoded structure; predicates over it are plain Elixir
    (`get_in/2`, pattern matching, `Enum.filter/2`).
  * Green verbs (CX-vfau).
  * MCP tool exposure.
  * Cross-doc history joins — `select`/`json`/`xml` are current-state
    only.
  """

  alias Commonplace.Dataflow.PubSub, as: CPPubSub
  alias Commonplace.GitBridge.{CanonicalJson, CanonicalXml}
  alias Commonplace.Document.ContentType
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.{DocBuilder, Schema}

  @default_max_depth 32
  @default_limit 10_000

  @doc """
  Walk the schema tree from `root_uuid`, matching a slash-separated
  glob `pattern` against entry names at each level, and return every
  match as `%{path: relative_path, uuid: entry_uuid}` in deterministic
  DFS order (schema entry order — the order `Schema.list_entries/1`
  returns for a given schema doc's content).

  ## Glob semantics (fnmatch-flavored, compiled per path segment)

    * `*`  — any run of characters within ONE path segment (never
      crosses a `/`).
    * `**` — any number of path segments, including zero. A `**` at
      the end of the pattern matches everything below that point, at
      any depth.
    * `?`  — exactly one character.
    * `[abc]` / `[!abc]` — a character class / negated character class.

  Each non-`**` segment compiles to an anchored regex; `**` is handled
  structurally by the walk (zero-match branch tries the remaining
  pattern against the CURRENT directory's entries; one-or-more-match
  branch recurses into every subdirectory with the same `**`-headed
  remainder).

  ## Bounds (this is user code running server-side)

  Two caps, because an unbounded walk driven by pattern text a doc
  author wrote is a resource-exhaustion surface:

    * `opts[:max_depth]` (default #{@default_max_depth}) — maximum
      schema-doc nesting depth explored. A directory beyond this depth
      is simply not descended into (silently bounded, not an error).
    * `opts[:limit]` (default #{@default_limit}) — maximum number of
      matches collected. Once hit, the walk stops accumulating further
      matches. (The walk itself may still visit a few more directories
      already in flight before the cap is noticed — this is a soft
      cap on output size, not a hard step-count budget.)

  ## `opts[:with_dirs]` (internal — `PatternCompute`'s subscription set)

  When `opts[:with_dirs]` is true, returns `{matches, dir_uuids}`
  instead of just `matches` — `dir_uuids` is the `MapSet` of every
  directory schema doc UUID visited during the walk (including
  `root_uuid` itself). `Commonplace.Black.PatternCompute` uses this to
  build its subscription set: every matched doc PLUS every visited
  directory schema, so a doc created after init under a
  previously-visited directory still triggers recomputation.

  ## Existing glob matcher search (CX-o1l9 build note)

  The build spec asked to check for an existing glob/fnmatch matcher
  before writing a new one (pointing at "presence honorific globs").
  A repo-wide search (`grep -rn "glob\\|fnmatch\\|wildcard"` across
  `apps/commonplace/lib`) turned up no path-glob matcher — presence's
  honorific check (`Commonplace.Tree.Schema.honorific_extension?/1`) is
  a fixed-suffix check, not a glob. No reusable matcher was found, so
  the segment-glob compiler below is new to this module.
  """
  @spec select(String.t(), String.t(), keyword()) ::
          [%{path: String.t(), uuid: String.t()}]
          | {[%{path: String.t(), uuid: String.t()}], MapSet.t()}
  def select(root_uuid, pattern, opts \\ [])
      when is_binary(root_uuid) and is_binary(pattern) and is_list(opts) do
    store = Keyword.get(opts, :store, CommitStoreClient)
    max_depth = Keyword.get(opts, :max_depth, @default_max_depth)
    limit = Keyword.get(opts, :limit, @default_limit)
    with_dirs = Keyword.get(opts, :with_dirs, false)

    segments = pattern |> String.trim("/") |> String.split("/", trim: true)

    state = %{matches: [], dirs: MapSet.new(), count: 0, stopped: false, limit: limit}

    state =
      case segments do
        [] -> state
        _ -> expand(store, root_uuid, [], segments, 0, max_depth, state)
      end

    matches = Enum.reverse(state.matches)

    if with_dirs do
      {matches, state.dirs}
    else
      matches
    end
  end

  @doc """
  Return the doc's canonical JSON as a decoded Elixir map/list —
  jes's structured-path extension made real WITHOUT a path language
  (brief F2): canonical render gives a stable structure, and
  predicates over it are plain Elixir (`get_in/2`, pattern matching,
  `Enum.filter/2` — no JSONPath/XPath engine here).

  Delegates to `Commonplace.GitBridge.CanonicalJson.encode/1` (the same
  deterministic renderer GitBridge's exporter uses for `:map` / `:array`
  content docs) and then `Jason.decode/1`. Returns `{:ok, term}` or
  `{:error, reason}` — `{:error, :not_found}` when the doc has no
  commits.
  """
  @spec json(String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def json(uuid, opts \\ []) when is_binary(uuid) and is_list(opts) do
    store = Keyword.get(opts, :store, CommitStoreClient)

    case DocBuilder.reconstruct_doc(store, uuid) do
      {:ok, doc} ->
        content = ContentType.get_content(doc)
        encoded = CanonicalJson.encode(content || %{})
        Jason.decode(encoded)

      :none ->
        {:error, :not_found}
    end
  end

  @doc """
  Return the doc's canonical XML as a string. Delegates to
  `Commonplace.GitBridge.CanonicalXml.encode/1` (the same deterministic
  renderer GitBridge's exporter uses for `:xml` content docs). Returns
  `{:ok, xml_string}` or `{:error, reason}` — `{:error, :not_found}`
  when the doc has no commits.
  """
  @spec xml(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def xml(uuid, opts \\ []) when is_binary(uuid) and is_list(opts) do
    store = Keyword.get(opts, :store, CommitStoreClient)

    case DocBuilder.reconstruct_doc(store, uuid) do
      {:ok, doc} ->
        tree = ContentType.get_content(doc) || []
        CanonicalXml.encode(tree)

      :none ->
        {:error, :not_found}
    end
  end

  @doc """
  Emit an author-facing red signal on `doc_uuid`'s red topic. Thin
  wrapper over `Commonplace.Dataflow.PubSub.broadcast_red/2`, tagging
  the payload so red subscribers can distinguish author-emitted
  signals from substrate events:

      {:black, :signal, %{source: <emitting process>, payload: event_payload}}

  `event_payload` must be a map (payload constraint from the spec).
  `source` is the calling process (`self()`) — the best "emitting
  context" available in M1; there is no richer execution-context
  object yet.

  ## No new trust surface (brief's "trust story pre-built")

  The only path by which doc-authored code can reach this function is
  from inside an execute-gated compute (Gate B) — same posture as
  every other verb in this module. With `Commonplace.Black.PatternCompute`
  (piece ii), the brief's §4.5 output-edge trigger family — "when
  pattern matches → run blue compute / emit red" — is pure composition:
  a `PatternCompute` whose `compute_fn` calls `emit_red/2` needs no
  dedicated trigger machinery of its own.
  """
  @spec emit_red(String.t(), map()) :: :ok | {:error, term()}
  def emit_red(doc_uuid, event_payload) when is_binary(doc_uuid) and is_map(event_payload) do
    CPPubSub.broadcast_red(doc_uuid, {:black, :signal, %{source: self(), payload: event_payload}})
  end

  # --- Private: bounded glob-matching DFS ---

  # `**` heading the remaining pattern: two branches.
  #   1. Zero-match: try the remainder of the pattern (after the `**`)
  #      against THIS directory's own entries (no depth consumed).
  #   2. One-or-more-match: recurse into every subdirectory entry with
  #      the SAME `["**" | rest]` pattern (still open to matching more
  #      levels of `**`).
  defp expand(_store, _dir_uuid, _path, _segments, depth, max_depth, state)
       when depth > max_depth or state.stopped do
    state
  end

  defp expand(store, dir_uuid, path, ["**" | rest] = segments, depth, max_depth, state) do
    doc = load_schema(store, dir_uuid)
    entries = Schema.list_entries(doc)
    state = track_dir(state, dir_uuid)

    state = match_segments_here(store, entries, path, rest, depth, max_depth, state)

    Enum.reduce(entries, state, fn entry, acc ->
      cond do
        acc.stopped -> acc
        entry.type == :dir -> expand(store, entry.node_id, path ++ [entry.name], segments, depth + 1, max_depth, acc)
        true -> acc
      end
    end)
  end

  defp expand(store, dir_uuid, path, segments, depth, max_depth, state) do
    doc = load_schema(store, dir_uuid)
    entries = Schema.list_entries(doc)
    state = track_dir(state, dir_uuid)
    match_segments_here(store, entries, path, segments, depth, max_depth, state)
  end

  # Match `segments` (guaranteed non-empty, head may be "**" when
  # called from the zero-match branch above) against `entries` of the
  # directory already loaded by the caller.
  defp match_segments_here(_store, _entries, _path, [], _depth, _max_depth, state), do: state

  defp match_segments_here(store, entries, path, ["**" | _] = segments, depth, max_depth, state) do
    Enum.reduce(entries, state, fn entry, acc ->
      cond do
        acc.stopped ->
          acc

        entry.type == :dir ->
          expand(store, entry.node_id, path ++ [entry.name], segments, depth + 1, max_depth, acc)

        true ->
          acc
      end
    end)
  end

  defp match_segments_here(_store, entries, path, [seg], _depth, _max_depth, state) do
    Enum.reduce(entries, state, fn entry, acc ->
      cond do
        acc.stopped -> acc
        glob_match?(seg, entry.name) -> add_match(acc, path ++ [entry.name], entry.node_id)
        true -> acc
      end
    end)
  end

  defp match_segments_here(store, entries, path, [seg | rest], depth, max_depth, state) do
    Enum.reduce(entries, state, fn entry, acc ->
      cond do
        acc.stopped ->
          acc

        entry.type == :dir and glob_match?(seg, entry.name) ->
          expand(store, entry.node_id, path ++ [entry.name], rest, depth + 1, max_depth, acc)

        true ->
          acc
      end
    end)
  end

  defp track_dir(state, uuid), do: %{state | dirs: MapSet.put(state.dirs, uuid)}

  defp add_match(%{stopped: true} = state, _path, _uuid), do: state

  defp add_match(state, path_segments, uuid) do
    if state.count >= state.limit do
      %{state | stopped: true}
    else
      match = %{path: Enum.join(path_segments, "/"), uuid: uuid}
      %{state | matches: [match | state.matches], count: state.count + 1}
    end
  end

  defp load_schema(store, uuid) do
    case DocBuilder.reconstruct_snapshot(store, uuid) do
      {:ok, doc} -> doc
      :none -> Schema.new_schema()
    end
  end

  # --- Private: fnmatch-style single-segment glob -> regex ---
  #
  # Compiled per call (not cached): segments are short and select/3 is
  # already bounded by max_depth/limit, so recompiling a handful of
  # small regexes per walk is not a hot-path concern for M1.

  defp glob_match?(glob_segment, name) do
    Regex.match?(compile_segment(glob_segment), name)
  end

  defp compile_segment(seg) do
    body = seg |> String.to_charlist() |> chars_to_regex([]) |> IO.iodata_to_binary()
    Regex.compile!("^" <> body <> "$")
  end

  defp chars_to_regex([], acc), do: Enum.reverse(acc)
  defp chars_to_regex([?* | rest], acc), do: chars_to_regex(rest, [".*" | acc])
  defp chars_to_regex([?? | rest], acc), do: chars_to_regex(rest, ["." | acc])

  defp chars_to_regex([?[ | rest], acc) do
    {class, remaining} = consume_bracket(rest)
    chars_to_regex(remaining, [class | acc])
  end

  defp chars_to_regex([c | rest], acc) do
    chars_to_regex(rest, [Regex.escape(<<c::utf8>>) | acc])
  end

  defp consume_bracket(chars) do
    {negate, chars} =
      case chars do
        [?! | t] -> {true, t}
        [?^ | t] -> {true, t}
        _ -> {false, chars}
      end

    {body, rest} = consume_bracket_body(chars, [])
    class = "[" <> if(negate, do: "^", else: "") <> IO.iodata_to_binary(body) <> "]"
    {class, rest}
  end

  # A `]` as the very first body character (right after `[` or `[!`) is
  # a literal per fnmatch convention, not the closing bracket.
  defp consume_bracket_body([?] | rest], []), do: consume_bracket_body(rest, [?]])
  defp consume_bracket_body([?] | rest], acc), do: {Enum.reverse(acc), rest}
  defp consume_bracket_body([], acc), do: {Enum.reverse(acc), []}
  defp consume_bracket_body([c | rest], acc), do: consume_bracket_body(rest, [c | acc])
end
