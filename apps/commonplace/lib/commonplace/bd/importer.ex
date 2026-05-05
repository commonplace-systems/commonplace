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

  Comments and dependencies are not part of the issue record;
  separate streams handle them via `import_comments_jsonl/3` and
  `import_deps_jsonl/3`.
  """

  alias Commonplace.Bd.{Comment, Dep, Issue, Schemas, Workspace}
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.Schema

  @doc """
  Imports a stream of issues from JSONL text. Returns `{:ok, %{
  imported: N, updated: M, errors: [...]}}`.

  Idempotent — re-import updates existing issues by id (LWW per
  field via the read-modify-write update path).
  """
  def import_issues_jsonl(root_uuid, jsonl_text, store \\ CommitStoreClient) when is_binary(jsonl_text) do
    # Ensure the workspace exists before any reads.
    _ = Workspace.ensure_bd_dir(root_uuid, store)

    {imported, updated, errors} =
      jsonl_text
      |> String.split("\n", trim: true)
      |> Enum.with_index()
      |> Enum.reduce({0, 0, []}, fn {line, idx}, {imp, upd, errs} ->
        case import_issue_line(root_uuid, line, store) do
          {:ok, :imported} -> {imp + 1, upd, errs}
          {:ok, :updated} -> {imp, upd + 1, errs}
          {:error, reason} -> {imp, upd, [{idx, reason} | errs]}
        end
      end)

    {:ok, %{imported: imported, updated: updated, errors: Enum.reverse(errors)}}
  end

  @doc """
  Imports dependency edges from JSONL text. Each line:

      {"from": "CX-a", "to": "CX-b", "kind": "blocks"}

  Idempotent. `kind` defaults to `"blocks"`.
  """
  def import_deps_jsonl(root_uuid, jsonl_text, store \\ CommitStoreClient) when is_binary(jsonl_text) do
    _ = Workspace.ensure_bd_dir(root_uuid, store)

    count =
      jsonl_text
      |> String.split("\n", trim: true)
      |> Enum.reduce(0, fn line, acc ->
        case Jason.decode(line) do
          {:ok, m} ->
            from = Map.get(m, "from")
            to = Map.get(m, "to")
            kind = Map.get(m, "kind", "blocks")

            if is_binary(from) and is_binary(to) do
              {:ok, _} = Dep.add(root_uuid, from, to, kind, %{}, store)
              acc + 1
            else
              acc
            end

          _ ->
            acc
        end
      end)

    {:ok, %{imported: count}}
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

  ## Private — issue-line dispatch

  defp import_issue_line(root_uuid, line, store) do
    with {:ok, raw} <- Jason.decode(line),
         {:ok, attrs, id} <- normalize_issue_attrs(raw) do
      case Issue.show(root_uuid, id, store) do
        {:ok, _existing} ->
          case Issue.update(root_uuid, id, attrs, store) do
            {:ok, _} -> {:ok, :updated}
            err -> err
          end

        {:error, :not_found} ->
          create_with_fixed_id(root_uuid, id, attrs, store)
      end
    else
      {:error, %Jason.DecodeError{} = e} -> {:error, {:bad_json, Exception.message(e)}}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :malformed_line}
    end
  end

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
            description: Map.get(raw, "description") || Map.get(raw, "body") || "",
            created_at: Map.get(raw, "created_at"),
            updated_at: Map.get(raw, "updated_at"),
            closed_at: Map.get(raw, "closed_at"),
            closed_reason: Map.get(raw, "close_reason") || Map.get(raw, "closed_reason"),
            extra: extract_extra(raw)
          }

        {:ok, attrs, id}

      _ ->
        {:error, :missing_id}
    end
  end

  defp extract_extra(raw) do
    known =
      ~w(id title status priority issue_type type owner description body
         created_at updated_at closed_at close_reason closed_reason
         created_by metadata)

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

  # Mirror Issue.create but with a caller-supplied id (used for import).
  defp create_with_fixed_id(root_uuid, id, attrs, store) do
    now = now_iso8601()

    issue = %Schemas.Issue{
      id: id,
      title: Map.get(attrs, :title, ""),
      status: Map.get(attrs, :status, "open"),
      priority: Map.get(attrs, :priority, "p2"),
      type: Map.get(attrs, :type, "task"),
      owner: Map.get(attrs, :owner),
      created_at: Map.get(attrs, :created_at) || now,
      updated_at: Map.get(attrs, :updated_at) || now,
      closed_at: Map.get(attrs, :closed_at),
      closed_reason: Map.get(attrs, :closed_reason),
      labels: Map.get(attrs, :labels, []),
      extra: Map.get(attrs, :extra, %{})
    }

    description = Map.get(attrs, :description, "")
    dir_uuid = build_issue_dir(issue, description, store)
    :ok = add_issue_entry(root_uuid, id, dir_uuid, store)
    {:ok, :imported}
  end

  defp build_issue_dir(%Schemas.Issue{} = issue, description, store) do
    dir_uuid = UUID.uuid4()
    dir_doc = Schema.new_schema()
    issue_meta_uuid = Schemas.create_text_doc(Schemas.encode_issue(issue), store)
    desc_uuid = Schemas.create_text_doc(description, store)
    comments_uuid = Schemas.create_dir_with_meta(nil, nil, store)

    dir_doc =
      dir_doc
      |> Schema.add_file(Schemas.issue_filename(), issue_meta_uuid)
      |> Schema.add_file(Schemas.description_filename(), desc_uuid)
      |> Schema.add_directory("comments", comments_uuid)

    update = Yelixer.Encoding.encode_update(dir_doc)
    CommitStoreClient.create_commit(store, dir_uuid, update, nil)
    dir_uuid
  end

  defp add_issue_entry(root_uuid, id, child_uuid, store) do
    issues_uuid = Workspace.issues_dir_uuid(root_uuid, store)
    {:ok, schema} = Schemas.load_dir_schema(issues_uuid, store)
    schema = Schema.add_directory(schema, "#{id}.iss", child_uuid)
    update = Yelixer.Encoding.encode_update(schema)
    CommitStoreClient.create_chained_commit(store, issues_uuid, update)
    :ok
  end

  defp now_iso8601, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
