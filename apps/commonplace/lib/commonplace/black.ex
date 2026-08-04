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

  * Ephemeral/scratch query docs (F3) — M1's `select/3` is the query
    verb; the F3 pin-capture/replay + result-witness-doc composition
    over it landed separately as `Commonplace.Black.Query` (CX-vt9l.1,
    epic CX-vt9l slice 1). This module still adds no query-doc/witness
    machinery of its own — `opts[:with_pin]`/`opts[:at_pin]` here are
    the minimal additive hooks `Query` composes, kept in `select/3`
    because they are properties of the WALK, not of F3 specifically.
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
  previously-linked directory still triggers recomputation.

  ## `opts[:with_truncation]` (CX-vt9l.6 — honest-scan signal)

  Both caps above are silent by default: nothing in the plain return
  shapes distinguishes "these are all the matches" from "the walk hit
  a cap and stopped early". That is a real hazard for anything that
  treats a `select/3` result as a complete answer — most sharply an
  aggregate (COUNT/SUM) computed over a capped scan, which is
  confidently wrong with no way for the caller to tell (see
  `Commonplace.Black.Query`'s moduledoc, "two-tier aggregate rule").

  `opts[:with_truncation]` (boolean, default `false`) makes the scan
  report both axes honestly. When true, the return is ALWAYS a map
  (same "growing shape needs a map" precedent `with_dirs`/`with_pin`
  already establish) with at least `:matches` and `:truncated`, plus
  `:dirs` / `:pin` folded in when `with_dirs` / `with_pin` are also
  set:

    * `truncated: :none` — the walk ran to completion on BOTH axes:
      never hit `limit`, never had to skip a directory for being
      beyond `max_depth`. This is an explicit positive value, not the
      absence of a key — "I checked and it's complete" reads
      differently from "this key happens to be missing", and the
      latter is exactly the silent-truncation failure this option
      exists to close.
    * `truncated: %{limit: boolean(), depth: [String.t()]}` — set
      whenever EITHER axis was hit. `limit: true` means `state.stopped`
      fired (the walk stopped accumulating matches at `opts[:limit]`).
      `depth` is the list of relative paths of directories the walk
      did NOT descend into because they sat at or beyond `max_depth`
      — each entry means "there may be matches under here that were
      never looked at", which is the sharper of the two holes: unlike
      the limit cap, a depth cut has no correlate in the match count
      (fewer rows, no signal). An axis that was NOT hit still reports
      honestly: `limit: false` / `depth: []`.

  Default `false` reproduces today's return shape and cost exactly —
  this option only adds bookkeeping already computed during the walk
  (`state.stopped` was already tracked; `depth`-cut tracking is a new,
  cheap append at the one guard clause that already short-circuits a
  too-deep directory).

  ## `opts[:with_pin]` and `opts[:at_pin]` (CX-vt9l.1 — F3 ephemeral
  queries / result-witness docs)

  Additive, default-off, and independent of each other and of
  `with_dirs` — omitting both reproduces today's behavior exactly
  (same return shape, same reads, same cost).

    * `opts[:with_pin]` (boolean, default `false`) — also return the
      PIN the walk actually observed: a `%{doc_uuid => commit_id}` map
      (raw binary commit ids, same type as `Commit.id` / the
      `commit_id` `resolve/3` and `reconstruct_doc_at/4` take) for
      *every doc read during the walk* — every schema directory
      visited (its own latest-or-pinned commit at read time) AND every
      matched leaf doc (its own latest-or-pinned commit, resolved with
      one extra `latest_commit`/pin lookup per match — `select/3`
      itself never reads a leaf's *content*, only its identity, so
      this is the cheapest read that can stand in as that leaf's
      observed pin).

      Return-shape precedent follows `with_dirs`: with only ONE of
      `with_dirs` / `with_pin` set, the return is still a 2-tuple
      (`{matches, dir_uuids}` or `{matches, pin}`, exactly like the
      existing `with_dirs`-alone shape). When BOTH are set, a growing
      tuple stops being legible, so the return becomes a map instead:
      `%{matches: matches, dirs: dir_uuids, pin: pin}`.

    * `opts[:at_pin]` (a `%{doc_uuid => commit_id}` map, or `nil` —
      default `nil`) — when given, EVERY doc read during the walk
      (schema dirs and matched leaves alike) resolves via
      `DocBuilder.reconstruct_doc_at(store, uuid, pin[uuid])` instead
      of latest. **A uuid absent from `at_pin` is treated as NOT
      PRESENT at that cut — it does NOT fall back to latest.** For a
      directory this means an empty schema (nothing below it can
      match, exactly as if the directory did not exist at this cut);
      for a matched leaf entry this means the match is dropped from
      the result entirely (its parent directory's *pinned* schema may
      still name the entry, but with no pinned commit to point the
      hit's `@`-ref at, honesty requires excluding it rather than
      silently substituting the doc's current `:latest` — see the
      moduledoc-level "repeatable reads" rule this exists to serve).
      This is deliberate and load-bearing for `Commonplace.Black.Query`
      (CX-vt9l.1): re-running the same pattern against the same
      `at_pin` must be byte-identical no matter what has mutated since,
      and a query result must never quietly widen its own cut.

  ## Existing glob matcher search (CX-o1l9 build note)

  The build spec asked to check for an existing glob/fnmatch matcher
  before writing a new one (pointing at "presence honorific globs").
  A repo-wide search (`grep -rn "glob\\|fnmatch\\|wildcard"` across
  `apps/commonplace/lib`) turned up no path-glob matcher — presence's
  honorific check (`Commonplace.Tree.Schema.honorific_extension?/1`) is
  a fixed-suffix check, not a glob. No reusable matcher was found, so
  the segment-glob compiler below is new to this module.
  """
  @type truncation :: :none | %{limit: boolean(), depth: [String.t()]}

  @spec select(String.t(), String.t(), keyword()) ::
          [%{path: String.t(), uuid: String.t()}]
          | {[%{path: String.t(), uuid: String.t()}], MapSet.t()}
          | {[%{path: String.t(), uuid: String.t()}], %{optional(String.t()) => binary()}}
          | %{
              :matches => [%{path: String.t(), uuid: String.t()}],
              optional(:dirs) => MapSet.t(),
              optional(:pin) => %{optional(String.t()) => binary()},
              optional(:truncated) => truncation()
            }
  def select(root_uuid, pattern, opts \\ [])
      when is_binary(root_uuid) and is_binary(pattern) and is_list(opts) do
    store = Keyword.get(opts, :store, CommitStoreClient)
    max_depth = Keyword.get(opts, :max_depth, @default_max_depth)
    limit = Keyword.get(opts, :limit, @default_limit)
    with_dirs = Keyword.get(opts, :with_dirs, false)
    with_pin = Keyword.get(opts, :with_pin, false)
    with_truncation = Keyword.get(opts, :with_truncation, false)
    at_pin = Keyword.get(opts, :at_pin, nil)

    segments = pattern |> String.trim("/") |> String.split("/", trim: true)

    state = %{
      matches: [],
      dirs: MapSet.new(),
      pin: %{},
      count: 0,
      stopped: false,
      limit: limit,
      with_pin: with_pin,
      at_pin: at_pin,
      depth_truncated: []
    }

    state =
      case segments do
        [] -> state
        _ -> expand(store, root_uuid, [], segments, 0, max_depth, state)
      end

    matches = Enum.reverse(state.matches)

    case {with_dirs, with_pin, with_truncation} do
      {false, false, false} ->
        matches

      {true, false, false} ->
        {matches, state.dirs}

      {false, true, false} ->
        {matches, state.pin}

      {true, true, false} ->
        %{matches: matches, dirs: state.dirs, pin: state.pin}

      {_, _, true} ->
        base = %{matches: matches, truncated: truncation(state)}
        base = if with_dirs, do: Map.put(base, :dirs, state.dirs), else: base
        if with_pin, do: Map.put(base, :pin, state.pin), else: base
    end
  end

  # Fold the walk's own bookkeeping (limit hit via `state.stopped`,
  # depth cuts recorded by `expand/7`'s depth-exceeded clause) into the
  # single honest value `opts[:with_truncation]` returns. `:none` is an
  # explicit positive ("checked both axes, neither was hit") — never
  # inferred from a missing key.
  defp truncation(state) do
    depth = state.depth_truncated |> Enum.reverse() |> Enum.uniq()

    if state.stopped or depth != [] do
      %{limit: state.stopped, depth: depth}
    else
      :none
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
  defp expand(_store, _dir_uuid, _path, _segments, _depth, _max_depth, %{stopped: true} = state) do
    state
  end

  # Depth cut: this directory would have been explored (it was worth a
  # recursive `expand/7` call) but sits at or beyond `max_depth`, so it
  # is not descended into — "silently bounded, not an error" per the
  # moduledoc. Recorded here (not inferred later) because this is the
  # one place the walk actually decides to skip a directory for depth
  # reasons; `path` at this point already includes this directory's own
  # name (the recursive call below always appends `entry.name` before
  # incrementing depth).
  defp expand(_store, _dir_uuid, path, _segments, depth, max_depth, state)
       when depth > max_depth do
    %{state | depth_truncated: [Enum.join(path, "/") | state.depth_truncated]}
  end

  defp expand(store, dir_uuid, path, ["**" | rest] = segments, depth, max_depth, state) do
    {doc, state} = read_dir(store, dir_uuid, state)
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
    {doc, state} = read_dir(store, dir_uuid, state)
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

  defp match_segments_here(store, entries, path, [seg], _depth, _max_depth, state) do
    Enum.reduce(entries, state, fn entry, acc ->
      cond do
        acc.stopped -> acc
        glob_match?(seg, entry.name) -> add_match(store, acc, path ++ [entry.name], entry.node_id)
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

  defp add_match(_store, %{stopped: true} = state, _path, _uuid), do: state

  defp add_match(store, state, path_segments, uuid) do
    if state.count >= state.limit do
      %{state | stopped: true}
    else
      case resolve_leaf(store, uuid, state) do
        :exclude ->
          state

        {:include, state} ->
          match = %{path: Enum.join(path_segments, "/"), uuid: uuid}
          %{state | matches: [match | state.matches], count: state.count + 1}
      end
    end
  end

  # Read a directory schema doc, honoring `state.at_pin` when set (see
  # select/3's moduledoc `opts[:at_pin]` section). The plain/default
  # path (no at_pin, no with_pin) is EXACTLY the original `load_schema/2`
  # implementation — one `reconstruct_snapshot/2` call, same as before
  # this change — so default behavior and cost are unchanged.
  defp read_dir(store, dir_uuid, %{at_pin: at_pin} = state) when is_map(at_pin) do
    case Map.fetch(at_pin, dir_uuid) do
      {:ok, commit_id} ->
        doc =
          case DocBuilder.reconstruct_doc_at(store, dir_uuid, commit_id) do
            {:ok, d} -> d
            :none -> Schema.new_schema()
          end

        {doc, maybe_put_pin(state, dir_uuid, commit_id)}

      :error ->
        # Not present in the pin — NOT PRESENT at this cut. No fallback
        # to :latest (that would destroy repeatable reads); an absent
        # directory resolves as though it never existed.
        {Schema.new_schema(), state}
    end
  end

  defp read_dir(store, dir_uuid, %{with_pin: true} = state) do
    case CommitStoreClient.latest_commit(store, dir_uuid) do
      {:ok, commit} ->
        doc =
          case DocBuilder.reconstruct_snapshot(store, dir_uuid) do
            {:ok, d} -> d
            :none -> Schema.new_schema()
          end

        {doc, maybe_put_pin(state, dir_uuid, commit.id)}

      :none ->
        {Schema.new_schema(), state}
    end
  end

  defp read_dir(store, dir_uuid, state) do
    doc =
      case DocBuilder.reconstruct_snapshot(store, dir_uuid) do
        {:ok, d} -> d
        :none -> Schema.new_schema()
      end

    {doc, state}
  end

  # Resolve a matched leaf entry's own observed commit id, per the same
  # at_pin/with_pin rules `read_dir/3` applies to directories. `select/3`
  # never reads a leaf's content, so this is a commit-id-only lookup
  # (cheap), skipped entirely unless with_pin or at_pin is in play —
  # zero extra reads on the default path.
  defp resolve_leaf(_store, uuid, %{at_pin: at_pin} = state) when is_map(at_pin) do
    case Map.fetch(at_pin, uuid) do
      {:ok, commit_id} -> {:include, maybe_put_pin(state, uuid, commit_id)}
      # Not present in the pin — NOT PRESENT at this cut: exclude the
      # match rather than silently resolving it at :latest.
      :error -> :exclude
    end
  end

  defp resolve_leaf(_store, _uuid, %{with_pin: false} = state), do: {:include, state}

  defp resolve_leaf(store, uuid, state) do
    case CommitStoreClient.latest_commit(store, uuid) do
      {:ok, commit} -> {:include, maybe_put_pin(state, uuid, commit.id)}
      # The schema names this entry but the target doc has no commits
      # yet — still a legitimate match (matches the no-with_pin
      # behavior), just nothing to pin it to.
      :none -> {:include, state}
    end
  end

  defp maybe_put_pin(%{with_pin: false} = state, _uuid, _commit_id), do: state
  defp maybe_put_pin(state, uuid, commit_id), do: %{state | pin: Map.put(state.pin, uuid, commit_id)}

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
