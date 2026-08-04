defmodule Commonplace.DerivationRecord do
  @moduledoc """
  CX-vt9l.2: the derivation-record convention (epic CX-vt9l slice 2).
  Source: commonplace-plan `docs/plans/2026-08-04-relational-search-ideation.md`
  §2b. Convention writeup with citations: `docs/derivation-records.md`
  in this repo.

  A derivation record is `(sources pin, transform ref, output ref,
  signer)` — content entirely `@`-refs plus a signature. That shape is
  structurally a WITNESS DOC (per the tree-pins definition, CX-osaf):
  nothing in it is computed state, every field is a pointer or a label.
  The DERIVED ARTIFACT it describes (index bytes, a materialized
  table, a rewritten view doc) is NOT itself a witness doc — it holds
  real computed content — but it is fully regenerable from the record,
  which is what turns "cache, not ground truth" into a checkable
  property: staleness becomes decidable by comparing the record's
  `sources_pin` against current heads, rather than inferred.

  ## Pin shape

  `sources_pin` reuses the SAME shape `Commonplace.Black.Query`
  already produces and documents: `%{optional(doc_uuid) => commit_id
  binary()}`. This module does not invent a second pin type.

  ## Fields

    * `"sources_pin"` — `%{doc_uuid => commit_id}`, the exact cut the
      transform read.
    * `"transform"` — an opaque ref identifying the transform (a code
      doc uuid, an algorithm-version tag, or a `{uuid, commit_id}`
      pair) — whatever names "which computation, which version."
    * `"output"` — an opaque ref identifying the produced artifact
      (typically `{doc_uuid, commit_id}`, but a filesystem path is
      valid for non-doc artifacts like `Reflog.Restore.materialize_dir/4`'s
      plain-file output).
    * `"signer"` — the signer id, or `nil` if unsigned.
    * `"computed_at"` — a `DateTime`, envelope-only (mirrors the
      snapshot ANNOUNCEMENT layer — see the convention doc): NOT
      load-bearing for staleness, just a label.

  No other keys are allowed — `witness?/1` enforces that.
  """

  @type ref :: term()
  @type pin :: %{optional(String.t()) => binary()}
  @type t :: %{
          required(String.t()) => term()
        }

  @allowed_keys ~w(sources_pin transform output signer computed_at)

  @doc """
  Build a canonical derivation record map.

  `sources_pin` is `%{doc_uuid => commit_id}` (the `Black.Query` pin
  shape). `transform_ref` and `output_ref` are opaque refs (see
  moduledoc). `opts`:

    * `:signer` — signer id, default `nil`.
    * `:computed_at` — default `DateTime.utc_now/0`.
  """
  @spec new(pin(), ref(), ref(), keyword()) :: t()
  def new(sources_pin, transform_ref, output_ref, opts \\ []) when is_map(sources_pin) do
    %{
      "sources_pin" => sources_pin,
      "transform" => transform_ref,
      "output" => output_ref,
      "signer" => Keyword.get(opts, :signer),
      "computed_at" => Keyword.get(opts, :computed_at, DateTime.utc_now())
    }
  end

  @doc """
  Structural witness check (CX-osaf): true iff `record` carries ONLY
  the allowed ref/label keys — no computed state (counts, bytes,
  scores, materialized rows) has snuck in alongside the refs. This is
  a SHAPE check, not a signature-verification step; a real witness-doc
  mint (see `Commonplace.Black.Query.witness/2`) is where signing
  happens.
  """
  @spec witness?(term()) :: boolean()
  def witness?(%{} = record) do
    record
    |> Map.keys()
    |> Enum.all?(&(&1 in @allowed_keys))
  end

  def witness?(_), do: false

  @typedoc """
  `:current` — every source's commit id in the record still matches
  the store's current latest commit for that doc: the artifact this
  record describes is safe to treat as fresh.

  `{:stale, changed_uuids}` — at least one source has moved; the
  artifact is a cache of a cut that no longer matches current heads.
  `changed_uuids` names exactly the sources that moved (never "some
  source, somewhere").

  `{:unknown, reason}` — at least one source could not be read (store
  unreachable, doc has no commits where the record implies it should).
  This is NEVER collapsed into `:current` — a silent false-negative
  here is the exact failure class this convention exists to prevent.
  """
  @type staleness :: :current | {:stale, [String.t()]} | {:unknown, term()}

  @doc """
  Decide whether `record`'s sources have moved relative to `store`'s
  current heads. `store` defaults to `Commonplace.Store.CommitStoreClient`'s
  default target.

  Reads each `sources_pin` entry's CURRENT latest commit and compares
  it against the pinned commit id. A source whose latest read raises
  (dead/unreachable store) or returns `:none` (no commits at all,
  where the record implies there should be one) is reported as
  `{:unknown, _}`, never silently treated as current OR as stale.
  """
  @spec stale?(t(), GenServer.server()) :: staleness()
  def stale?(%{"sources_pin" => pin}, store \\ Commonplace.Store.CommitStoreClient)
      when is_map(pin) do
    pin
    |> Enum.map(fn {uuid, commit_id} -> check_source(store, uuid, commit_id) end)
    |> summarize()
  end

  defp check_source(store, uuid, commit_id) do
    case Commonplace.Store.CommitStoreClient.latest_commit(store, uuid) do
      {:ok, %{id: ^commit_id}} -> {:current, uuid}
      {:ok, %{id: _other}} -> {:stale, uuid}
      :none -> {:unknown, uuid, :no_current_commit}
    end
  catch
    kind, reason -> {:unknown, uuid, {kind, reason}}
  end

  defp summarize(results) do
    unknowns = for {:unknown, _uuid, _reason} = u <- results, do: u

    case unknowns do
      [] ->
        stale_uuids = for {:stale, uuid} <- results, do: uuid

        case stale_uuids do
          [] -> :current
          uuids -> {:stale, uuids}
        end

      unknowns ->
        {:unknown, unknowns}
    end
  end
end
