defmodule Commonplace.Bd.Label do
  @moduledoc """
  Labels — per-name docs under /bd/labels/<name>.lbl/, referenced by
  issues' `labels` array (an array of label name strings for P1; the
  spec calls for DocRefs at §3.5 — that's a P3 lift).

  Spec: §3.3, §5.5.
  """

  alias Commonplace.Bd.{Issue, Schemas, Workspace}
  alias Commonplace.Bd.Schemas.Label
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.Schema
  alias Yelixer.Encoding

  @doc """
  Creates a label. Idempotent — re-creating with new attrs updates
  the existing label doc (LWW behaviour at the YMap level).
  """
  def create(root_uuid, name, attrs \\ %{}, store \\ CommitStoreClient) do
    label = %Label{
      name: name,
      color: Map.get(attrs, :color),
      description: Map.get(attrs, :description, "")
    }

    json = Schemas.encode_label(label)
    labels_dir = Workspace.labels_dir_uuid(root_uuid, store)

    case Workspace.label_dir_uuid(root_uuid, name, store) do
      {:ok, dir_uuid} ->
        :ok = write_label_meta(dir_uuid, json, store)
        {:ok, label, dir_uuid}

      :error ->
        with {:ok, dir_uuid} <- build_label_dir(json, store) do
          :ok = add_label_entry(labels_dir, name, dir_uuid, store)
          {:ok, label, dir_uuid}
        end
    end
  end

  @doc "Lists every label."
  def list(root_uuid, store \\ CommitStoreClient) do
    labels_dir = Workspace.labels_dir_uuid(root_uuid, store)

    case Schemas.load_dir_schema(labels_dir, store) do
      {:ok, schema} ->
        Schema.list_entries(schema)
        |> Enum.filter(fn e -> e.type == :dir and String.ends_with?(e.name, ".lbl") end)
        |> Enum.map(fn entry ->
          case Schemas.load_label(entry.node_id, store) do
            {:ok, label} -> label
            _ -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.sort_by(& &1.name)

      _ ->
        []
    end
  end

  @doc "Assigns a label to an issue (no-op if already assigned)."
  def assign(root_uuid, issue_id, label_name, store \\ CommitStoreClient) do
    with {:ok, issue} <- Issue.show(root_uuid, issue_id, store) do
      labels = if label_name in issue.labels, do: issue.labels, else: issue.labels ++ [label_name]
      Issue.update(root_uuid, issue_id, %{labels: labels}, store)
    end
  end

  @doc "Removes a label from an issue."
  def unassign(root_uuid, issue_id, label_name, store \\ CommitStoreClient) do
    with {:ok, issue} <- Issue.show(root_uuid, issue_id, store) do
      labels = Enum.reject(issue.labels, &(&1 == label_name))
      Issue.update(root_uuid, issue_id, %{labels: labels}, store)
    end
  end

  ## Private

  defp build_label_dir(json, store) do
    dir_uuid = UUID.uuid4()
    dir_doc = Schema.new_schema()

    with {:ok, label_uuid} <- Schemas.create_text_doc_checked(json, store) do
      dir_doc = Schema.add_file(dir_doc, "label.json", label_uuid)
      update = Encoding.encode_update(dir_doc)
      CommitStoreClient.create_commit(store, dir_uuid, update, nil)
      {:ok, dir_uuid}
    end
  end

  defp write_label_meta(dir_uuid, json, store) do
    {:ok, schema} = Schemas.load_dir_schema(dir_uuid, store)
    {:ok, entry} = Schema.get_entry(schema, "label.json")
    Schemas.write_text_doc(entry.node_id, json, store)
    :ok
  end

  defp add_label_entry(labels_dir, name, child_uuid, store) do
    {:ok, schema} = Schemas.load_dir_schema(labels_dir, store)
    schema = Schema.add_directory(schema, "#{name}.lbl", child_uuid)
    update = Encoding.encode_update(schema)
    CommitStoreClient.create_chained_commit(store, labels_dir, update)
    :ok
  end
end
