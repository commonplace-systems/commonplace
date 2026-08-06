defmodule Commonplace.Bd.Importer do
  @moduledoc """
  Idempotent JSONL importer for beads-on-Commonplace.

  Spec: §9.1.

  Accepts the beads JSONL format (one JSON-encoded record per line).
  Real beads stores priority as an integer (0-3); the importer maps
  it to our string form (`p0`-`p3`). The `issue_type` field maps to
  our `type`. Other fields pass through; unknown fields are
  preserved in the issue's `extra` map for round-trip safety.

  Re-running the importer against an updated JSONL is a no-op for
  unchanged rows and a field update for changed ones. The
  importer-only view-suspend flag from spec §9.1 is a no-op in P1
  because views aren't shipped yet (they're P2).

  ## Format expected

  Each line is a JSON object with at minimum:

      {
        "id": "CX-7vm",
        "title": "...",
        "status": "open" | "in_progress" | "blocked" | "review" | "closed" | "wontfix",
        "priority": 0 | 1 | 2 | 3 | "p0".."p3",
        "issue_type": "feature" | "bug" | "task" | "epic" | "spike",
        "description": "..." (optional),
        "owner": "...",
        "created_at": "...",
        "updated_at": "...",
        "closed_at": "...",
        "close_reason": "..."
      }

  Comments are not part of the issue record; `import_comments_jsonl/4`
  handles that stream. Dependencies used to be a separate stream too —
  see the CX-hrbn note below for where they went.

  ## CX-6cz3: this module no longer writes issues

  Per the tix-authority migration design §7 (rulings @6418506), ALL
  ticket writes flow through the `Commonplace.Bd.WriteGuard`
  chokepoint. The private `create_with_fixed_id/4` that used to live
  here — a raw `CommitStoreClient` write, no guard, no cycle gate —
  is gone; `import_issues_jsonl/4` now PARSES (the good part: the
  priority/status normalizers and the extra-field round-trip, kept as
  pure transformation below) and hands the records to the gated
  `ticket_import` verb on `Commonplace.ViewActionDispatch`.

  ## CX-hrbn: the deps leg is retired

  `import_deps_jsonl/3` wrote `blocks` edges into `/bd/deps.json` — a
  different graph from the `needs` refs the P2 frontier and cycle gate
  walk, and one nothing has written since the tix-authority cutover on
  2026-08-05. It now refuses loudly. Its job is done inline by
  `import_issues_jsonl/4`: `needs` edges arriving with an imported
  record are folded through the gated `ticket_import` verb, cycle gate
  and all, so a separate edge stream has nothing left to add.

  `import_comments_jsonl/4` is unaffected — comments are not a graph.
  """

  alias Commonplace.Bd.{Comment, Retired, Schemas, Workspace}
  alias Commonplace.Store.CommitStoreClient

  @doc """
  Imports a stream of issues from JSONL text through the GATED
  `ticket_import` verb. Returns `{:ok, %{imported: N, updated: M,
  unchanged: K, errors: [...], batch: <the verb's full report>}}`.

  `imported`/`updated`/`errors` keep their historical meaning for
  existing callers (`Commonplace.CLI.Bd`); `batch` carries the ruled
  reporting shape — the declared denominator, and landed/refused/noop
  against it (see the verb's docs).

  Idempotent — a byte-identical record is a NO-OP (no write, no
  commit); a changed record is a guarded update.
  """
  def import_issues_jsonl(root_uuid, jsonl_text, store \\ CommitStoreClient, opts \\ [])
      when is_binary(jsonl_text) do
    # Ensure the workspace exists before any reads.
    _ = Workspace.ensure_bd_dir(root_uuid, store)

    {records, parse_errors} = parse_records(jsonl_text)

    context =
      %{
        args: %{"records" => records},
        root_uuid: root_uuid,
        store: store,
        source: "bd_importer"
      }
      |> maybe_put_signing_context(Keyword.get(opts, :signing_context))

    case Commonplace.ViewActionDispatch.dispatch("ticket_import", context) do
      {:ok, :tree_mutation, batch} ->
        {:ok,
         %{
           imported: Enum.count(batch.landed, &(&1.op == :created)),
           updated: Enum.count(batch.landed, &(&1.op == :updated)),
           unchanged: length(batch.noop),
           errors: parse_errors ++ Enum.map(batch.refused, fn r -> {r.id, r.reason} end),
           batch: batch
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Splits JSONL text into `{decoded_records, errors}` — pure, writes
  nothing. `errors` are `{line_index, reason}` for lines that are not
  decodable JSON objects; they never reach the verb (there is no
  record to gate), so the caller reports them alongside the verb's
  own per-record refusals.
  """
  @spec parse_records(String.t()) :: {[map()], [{non_neg_integer(), term()}]}
  def parse_records(jsonl_text) when is_binary(jsonl_text) do
    jsonl_text
    |> String.split("\n", trim: true)
    |> Enum.with_index()
    |> Enum.reduce({[], []}, fn {line, idx}, {records, errors} ->
      case Jason.decode(line) do
        {:ok, m} when is_map(m) -> {[m | records], errors}
        {:ok, _other} -> {records, [{idx, :malformed_line} | errors]}
        {:error, %Jason.DecodeError{} = e} -> {records, [{idx, {:bad_json, Exception.message(e)}} | errors]}
      end
    end)
    |> then(fn {records, errors} -> {Enum.reverse(records), Enum.reverse(errors)} end)
  end

  defp maybe_put_signing_context(context, nil), do: context
  defp maybe_put_signing_context(context, sc), do: Map.put(context, :signing_context, sc)

  @doc """
  RETIRED. Raises `Commonplace.Bd.RetiredGraphError`.

  Imported `{"from": ..., "to": ..., "kind": "blocks"}` lines into
  `/bd/deps.json`. Superseded by `import_issues_jsonl/4`, which folds a
  record's `needs` through the gated `ticket_import` verb.
  """
  def import_deps_jsonl(root_uuid, jsonl_text, store \\ CommitStoreClient)

  def import_deps_jsonl(_root_uuid, jsonl_text, _store) when is_binary(jsonl_text) do
    Retired.write!(
      "Commonplace.Bd.Importer.import_deps_jsonl/3",
      "This separate edge stream is superseded by `import_issues_jsonl/4`: prerequisites now ride along on the issue record as `needs` and are folded in by the gated `ticket_import` verb, through the cycle gate. Rewrite the edge stream as `needs` entries on the dependent records rather than importing it on its own."
    )
  end

  @doc """
  Imports comments scoped to a specific issue. Each line is a
  JSON-encoded comment record.
  """
  def import_comments_jsonl(root_uuid, issue_id, jsonl_text, store \\ CommitStoreClient) when is_binary(jsonl_text) do
    count =
      jsonl_text
      |> String.split("\n", trim: true)
      |> Enum.reduce(0, fn line, acc ->
        case Jason.decode(line) do
          {:ok, m} ->
            attrs = %{
              id: Map.get(m, "id"),
              author: Map.get(m, "author"),
              body: Map.get(m, "body", ""),
              reply_to: Map.get(m, "reply_to"),
              created_at: Map.get(m, "created_at")
            }

            case Comment.add(root_uuid, issue_id, attrs, store) do
              {:ok, _} -> acc + 1
              _ -> acc
            end

          _ ->
            acc
        end
      end)

    {:ok, %{imported: count}}
  end

  ## Record normalization — PURE transformation, no writes (CX-6cz3).
  ## The gated `ticket_import` verb calls `normalize_record/1` for
  ## every record it admits; this is the one place the beads wire
  ## format (integer priorities, `issue_type`, `close_reason`,
  ## unknown-field round-trip) is translated into our attrs bag.

  @doc """
  Normalizes one decoded bd record into `{:ok, attrs, id}` or
  `{:error, reason}`. Pure.
  """
  @spec normalize_record(map()) :: {:ok, map(), String.t()} | {:error, term()}
  def normalize_record(raw) when is_map(raw), do: normalize_issue_attrs(raw)
  def normalize_record(_), do: {:error, :malformed_line}

  defp normalize_issue_attrs(raw) when is_map(raw) do
    case Map.get(raw, "id") do
      id when is_binary(id) ->
        attrs =
          %{
            title: Map.get(raw, "title", ""),
            status: normalize_status(Map.get(raw, "status", "open")),
            priority: normalize_priority(Map.get(raw, "priority")),
            type: Map.get(raw, "issue_type") || Map.get(raw, "type") || "task",
            owner: Map.get(raw, "owner"),
            created_at: Map.get(raw, "created_at"),
            updated_at: Map.get(raw, "updated_at"),
            closed_at: Map.get(raw, "closed_at"),
            closed_reason: Map.get(raw, "close_reason") || Map.get(raw, "closed_reason"),
            extra: extract_extra(raw)
          }
          |> carry_description(raw)
          |> carry(raw, "needs", :needs)
          |> carry(raw, "done_when", :done_when)
          |> carry(raw, "done_witness", :done_witness)
          |> carry(raw, "claimed_by", :claimed_by)
          |> carry(raw, "labels", :labels)
          |> carry(raw, "legacy_id", :legacy_id)

        {:ok, attrs, id}

      _ ->
        {:error, :missing_id}
    end
  end

  # CX-6cz3: the GRAPH fields (`needs` above all) are carried only when
  # the source record actually has the key — PRESENT-KEY semantics, not
  # defaulted. A bd record carries no `needs`, and defaulting it to `[]`
  # would make every re-import silently WIPE edges added locally through
  # `ticket_add_needs`. Absent key => the field is not in the change
  # set at all; on a create, `Issue.build_with_id/2` supplies the spec
  # default.
  # Same present-key rule for the description (which lives in a sibling
  # text doc, not the field bag): a record that says nothing about the
  # body must not blank an existing one.
  defp carry_description(attrs, raw) do
    cond do
      Map.has_key?(raw, "description") -> Map.put(attrs, :description, Map.get(raw, "description") || "")
      Map.has_key?(raw, "body") -> Map.put(attrs, :description, Map.get(raw, "body") || "")
      true -> attrs
    end
  end

  defp carry(attrs, raw, raw_key, attr_key) do
    if Map.has_key?(raw, raw_key),
      do: Map.put(attrs, attr_key, Map.get(raw, raw_key)),
      else: attrs
  end

  defp extract_extra(raw) do
    known =
      ~w(id title status priority issue_type type owner description body
         created_at updated_at closed_at close_reason closed_reason
         created_by metadata
         needs done_when done_witness claimed_by labels legacy_id)

    raw
    |> Map.drop(known)
    |> Map.reject(fn {_, v} -> is_nil(v) end)
  end

  defp normalize_priority(p) when p in [0, 1, 2, 3], do: "p#{p}"
  defp normalize_priority(p) when is_binary(p) do
    cond do
      p in Schemas.valid_priorities() -> p
      String.match?(p, ~r/^[0-3]$/) -> "p#{p}"
      true -> "p2"
    end
  end
  defp normalize_priority(_), do: "p2"

  defp normalize_status(s) when is_binary(s) do
    if s in Schemas.valid_statuses(), do: s, else: "open"
  end

  defp normalize_status(_), do: "open"
end
