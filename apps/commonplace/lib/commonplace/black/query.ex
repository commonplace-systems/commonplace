defmodule Commonplace.Black.Query do
  @moduledoc """
  CX-vt9l.1 (epic CX-vt9l slice 1): F3 ephemeral queries +
  query-result-as-witness-doc. Source: commonplace-plan
  `docs/plans/2026-08-04-relational-search-ideation.md` §2c ("the
  composed object: a query result is a witness doc over a pin") and
  §3 ("ad-hoc queries ... an ad-hoc query is an ephemeral query doc
  (scratch namespace) evaluated once at a pin, emitting a
  result-witness doc").

  ## What this is NOT

  Not a new subsystem, not a second query language, not a REPL. The
  query surface is the existing Black M1 verbs — `Commonplace.Black.select/3`
  (extended additively here with `opts[:with_pin]` / `opts[:at_pin]`,
  see that module's doc). This module composes `select/3` with a pin
  capture/replay discipline and a witness-doc minting step; it adds no
  new read primitive of its own.

  ## The pin-capture / at-pin design

  `run/3` evaluates `pattern` against `root_uuid`'s CURRENT tree
  (`Black.select/3` with `with_pin: true`, no `at_pin`) and returns
  the hits alongside the exact pin the walk observed — one entry per
  doc actually read (every schema directory visited, every matched
  leaf), reusing `Black.select/3`'s own bookkeeping rather than a
  second walk. `run_at/4` re-evaluates the SAME pattern against a
  previously-captured pin (`Black.select/3` with `at_pin: pin`,
  `with_pin: true`) — every read is forced through that pin, and a
  uuid missing from it is NOT PRESENT at that cut (see `Black.select/3`
  moduledoc), never silently re-resolved at `:latest`. That is what
  makes `run_at/4` deterministic: re-running against the same pin
  cannot see anything that happened after the pin was captured, no
  matter what mutated in the meantime.

  This deliberately reuses the CX-0t2r pin vocabulary
  (`Commonplace.Reflog.Restore.resolve/3` / `resolve_anchored/4`) at
  the concept level — "a path -> (doc, commit) cut, read per-commit,
  never chain-replayed" — without importing that module's code: a
  query pin only ever needs ONE commit id per doc (the exact commit
  `DocBuilder.reconstruct_doc_at/4` should replay to), which is
  exactly what `Black.select/3`'s new `with_pin`/`at_pin` opts already
  produce and consume. Building a second resolver here would duplicate
  that discipline instead of reusing it.

  ## The witness (the non-negotiable shape, 2026-08-03 tree-pins summit)

  `witness/2` builds CONTENT that is entirely `@`-refs plus labels —
  the "query" (the pattern text, itself a doc-worthy string per M6
  code-as-doc, but not resolved/read here — F3 does not need a
  separate query DOC to make this true, see "Deviations" in this
  module's build history), the "pin" (`%{uuid => hex commit id}`),
  the "hits" (`[%{"path", "uuid", "commit"}]` — each a content-address
  pointer: `uuid` says which doc, `commit` says which exact commit of
  it, openable via a single-commit read exactly like
  `Commonplace.Reflog.Restore`'s "never chain-replay a pin doc"
  discipline; a hit whose leaf doc had no commits yet carries
  `"commit" => nil`, honestly, rather than a fabricated one), the
  "evaluator" version, and a "cut_label". NOTHING here is computed
  state: no scores, no counts presented as facts (the epic's aggregate
  rule) — every value is a ref, a label, or a map/list of refs. When
  `opts[:signing_context]` is given, `witness/2` mints this content as
  a real signed doc and returns its uuid; otherwise it returns the
  content map itself for the caller to inspect, embed, or mint later.

  ## Honest labeling (the coherence bound, verbatim)

  Any user-facing rendering of a result must say it is
  AS-SEEN-AT-A-CUT and must NOT imply invariant-safety: a pin is
  coherent-with-what-the-witness-saw, NOT invariant-satisfying. Two
  concurrent writers can each observe a state that passes their own
  local check and still jointly violate an invariant after merge — the
  same bound `Commonplace.Reflog.Restore.materialize_dir/4` and
  `Commonplace.Reflog.Snapshot` already carry for checkpoints. The
  `cut_label` this module writes ("as seen at cut <hash>") is that
  label; nothing produced by this module should ever be presented
  without it.

  A cut label answers "as seen when" — it does NOT answer "did the
  scan that produced this see everything below that cut". Those are
  independent questions (CX-vt9l.6): `Black.select/3` walks under two
  silent caps, `limit` and `max_depth`, and `run/3`/`run_at/4` always
  report which (if either) fired via `result.truncated` — `:none` is
  the explicit, positive "complete" answer, never an absent key.
  `witness/2` carries that same fact into the minted content as
  `"truncated"`, because a result-witness that labels its cut but
  omits "this scan was capped" is exactly the dishonest-label failure
  this module exists to avoid. A truncated result is NOT a complete
  answer and MUST NOT be used as the basis of a count or other
  aggregate — the epic's two-tier aggregate rule cannot be honest
  about a cut it does not know was truncated.
  """

  alias Commonplace.Black
  alias Commonplace.Crypto.SigningContext
  alias Commonplace.Document.ContentType
  alias Commonplace.Store.CommitStoreClient

  @evaluator_version "black-query-v1"

  @type hit :: %{path: String.t(), uuid: String.t()}
  @type pin :: %{optional(String.t()) => binary()}
  @type truncated :: :none | %{limit: boolean(), depth: [String.t()]}
  @type result :: %{hits: [hit()], pin: pin(), evaluator: String.t(), truncated: truncated()}

  @doc """
  Evaluate `pattern` against `root_uuid`'s CURRENT tree, capturing the
  pin the walk observed. Returns
  `{:ok, %{hits:, pin:, evaluator:, truncated:}}`.

  `opts` accepts `:store`, `:max_depth`, `:limit` (forwarded to
  `Black.select/3` unchanged).

  `truncated` is ALWAYS present (no back-compat burden — this is F3's
  own new result shape, not `Black.select/3`'s back-compat-gated
  return): `:none` when the walk hit neither the `limit` nor the
  `max_depth` cap, or `%{limit: boolean(), depth: [String.t()]}`
  otherwise — see `Black.select/3`'s `opts[:with_truncation]` doc for
  what each field means. Absence of a key is never how "complete" is
  spelled here; `:none` is.
  """
  @spec run(String.t(), String.t(), keyword()) :: {:ok, result()}
  def run(root_uuid, pattern, opts \\ [])
      when is_binary(root_uuid) and is_binary(pattern) and is_list(opts) do
    store = Keyword.get(opts, :store, CommitStoreClient)

    select_opts =
      opts
      |> Keyword.take([:max_depth, :limit])
      |> Keyword.merge(store: store, with_pin: true, with_truncation: true)

    %{matches: hits, pin: observed_pin, truncated: truncated} =
      Black.select(root_uuid, pattern, select_opts)

    {:ok, %{hits: hits, pin: observed_pin, evaluator: @evaluator_version, truncated: truncated}}
  end

  @doc """
  Re-evaluate `pattern` against `root_uuid` deterministically at a
  previously-recorded `pin` (from `run/3` or a prior `run_at/4`'s own
  returned pin). Every doc read during the walk resolves via `pin`;
  see `Black.select/3`'s `opts[:at_pin]` doc for the "absent from the
  pin is NOT PRESENT, never :latest" rule this relies on for
  determinism. Returns `{:ok, %{hits:, pin:, evaluator:, truncated:}}`
  — the returned `pin` is the (sub)set of `pin` actually touched by
  this walk, so it composes with `witness/2` the same way `run/3`'s
  does. `truncated` follows the same always-present, `:none`-is-
  explicit rule documented on `run/3`.
  """
  @spec run_at(String.t(), String.t(), pin(), keyword()) :: {:ok, result()}
  def run_at(root_uuid, pattern, pin, opts \\ [])
      when is_binary(root_uuid) and is_binary(pattern) and is_map(pin) and is_list(opts) do
    store = Keyword.get(opts, :store, CommitStoreClient)

    select_opts =
      opts
      |> Keyword.take([:max_depth, :limit])
      |> Keyword.merge(store: store, with_pin: true, at_pin: pin, with_truncation: true)

    %{matches: hits, pin: observed_pin, truncated: truncated} =
      Black.select(root_uuid, pattern, select_opts)

    {:ok, %{hits: hits, pin: observed_pin, evaluator: @evaluator_version, truncated: truncated}}
  end

  @doc """
  Build the result-witness CONTENT for `result` (a `run/3` or
  `run_at/4` result map) — `opts[:query]` (required) is the pattern
  text the result was produced from.

  Returns the content map (entirely refs/strings/maps-of-refs — see
  moduledoc) when `opts[:signing_context]` is absent. When
  `opts[:signing_context]` (a `%Commonplace.Crypto.SigningContext{}`)
  is given, mints the content as a fresh node-signed `:map` doc
  (unchained — a witness doc is a new scratch artifact, not an edit to
  an existing chain) and returns `{:ok, uuid}` instead. `opts[:store]`
  (default `CommitStoreClient`) is where the mint lands.
  """
  @spec witness(result(), keyword()) :: map() | {:ok, String.t()} | {:error, term()}
  def witness(%{hits: hits, pin: pin, evaluator: evaluator, truncated: truncated}, opts \\ [])
      when is_list(opts) do
    query = Keyword.fetch!(opts, :query)
    content = build_content(query, hits, pin, evaluator, truncated)

    case Keyword.get(opts, :signing_context) do
      nil -> content
      %SigningContext{} = sc -> mint(content, sc, opts)
    end
  end

  defp build_content(query, hits, pin, evaluator, truncated) do
    hex_pin = Map.new(pin, fn {uuid, commit_id} -> {uuid, hex(commit_id)} end)

    %{
      "query" => query,
      "pin" => hex_pin,
      "hits" => Enum.map(hits, &hit_ref(&1, pin)),
      "evaluator" => evaluator,
      "cut_label" => "as seen at cut " <> cut_hash(pin),
      "truncated" => truncated_content(truncated)
    }
  end

  # `truncated` travels into the witness content as content-doc-safe
  # values (strings/maps/lists/bools — no bare atoms) rather than the
  # Elixir-side `:none` atom, but preserves the same "complete is an
  # explicit positive value" shape: `"none"` (the string) means both
  # axes were checked and neither was hit, never an absent key. A
  # witness that labels its cut but omits whether the SCAN itself was
  # capped is exactly the dishonest label this module's moduledoc
  # warns against — see "Honest labeling" above.
  defp truncated_content(:none), do: "none"
  defp truncated_content(%{limit: limit, depth: depth}), do: %{"limit" => limit, "depth" => depth}

  defp hit_ref(%{path: path, uuid: uuid}, pin) do
    %{"path" => path, "uuid" => uuid, "commit" => hex(Map.get(pin, uuid))}
  end

  defp hex(nil), do: nil
  defp hex(binary) when is_binary(binary), do: Base.encode16(binary, case: :lower)

  # A deterministic label for the whole observed cut, independent of
  # map key order: sort by uuid, join "uuid:hexcommit" pairs, hash.
  # Not a security boundary (the witness doc's own signature is) —
  # just a short, stable, human-showable stand-in for "this exact pin".
  defp cut_hash(pin) do
    pin
    |> Enum.sort_by(fn {uuid, _commit_id} -> uuid end)
    |> Enum.map(fn {uuid, commit_id} -> uuid <> ":" <> hex(commit_id) end)
    |> Enum.join(",")
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp mint(content, signing_context, opts) do
    store = Keyword.get(opts, :store, CommitStoreClient)
    uuid = UUID.uuid4()

    doc =
      Yelixer.Doc.new()
      |> ContentType.create(:map, "query-result-witness")

    doc = Enum.reduce(content, doc, fn {k, v}, acc -> ContentType.set_key(acc, k, v) end)
    update = Yelixer.Encoding.encode_update(doc)

    case CommitStoreClient.create_commit(store, uuid, update, nil, %{}, signing_context: signing_context) do
      {:error, _} = err -> err
      _commit -> {:ok, uuid}
    end
  end
end
