defmodule Commonplace.Bd.Workspace do
  @moduledoc """
  Lazy setup + lookup for the /bd/ tree shape.

  Spec: /home/jes/commonplace-plan/docs/beads-on-commonplace.md §2.

  All operations are idempotent. The first read or write to /bd/
  ensures the tree exists; subsequent calls are cheap directory
  walks.

      <root>/
        bd/
          __meta.json
          deps.json
          issues/
            <prefix>-<suffix>.iss/
              __issue.json
              description.txt
              comments/
                c-<suffix>.json
          labels/
            <name>.lbl/
              label.json
  """

  alias Commonplace.Bd.Schemas
  alias Commonplace.Bd.Schemas.Meta
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.Schema
  alias Yelixer.Encoding

  @bd_dir "bd"
  @issues_dir "issues"
  @labels_dir "labels"

  def bd_dir, do: @bd_dir
  def issues_dir, do: @issues_dir
  def labels_dir, do: @labels_dir

  @doc """
  Locates the /bd/ directory under `root_uuid`, creating it (and the
  default `__meta.json` + `deps.json` skeleton) if missing.

  Returns the UUID of the /bd/ directory.
  """
  def ensure_bd_dir(root_uuid, store \\ CommitStoreClient) do
    {:ok, root_schema} = Schemas.load_dir_schema(root_uuid, store)

    case Schema.get_entry(root_schema, @bd_dir) do
      {:ok, entry} ->
        ensure_bd_skeleton(entry.node_id, store)
        entry.node_id

      :error ->
        bd_uuid = Schemas.create_dir_with_meta(nil, nil, store)
        ensure_bd_skeleton(bd_uuid, store)
        :ok = add_dir_entry(root_uuid, @bd_dir, bd_uuid, store)
        bd_uuid
    end
  end

  defp ensure_bd_skeleton(bd_uuid, store) do
    {:ok, schema} = Schemas.load_dir_schema(bd_uuid, store)

    schema =
      schema
      |> ensure_file(bd_uuid, store, Schemas.meta_filename(), &default_meta_json/0)
      |> ensure_file(bd_uuid, store, Schemas.deps_filename(), fn -> "{}" end)
      |> ensure_dir_entry(bd_uuid, store, @issues_dir)
      |> ensure_dir_entry(bd_uuid, store, @labels_dir)

    _ = schema
    :ok
  end

  defp default_meta_json do
    Schemas.encode_meta(%Meta{prefix: "CX"})
  end

  defp ensure_file(schema, parent_uuid, store, filename, default_json_fn) do
    case Schema.get_entry(schema, filename) do
      {:ok, _} ->
        schema

      :error ->
        json = default_json_fn.()
        file_uuid = Schemas.create_text_doc(json, store)
        :ok = add_file_entry(parent_uuid, filename, file_uuid, store)
        {:ok, fresh} = Schemas.load_dir_schema(parent_uuid, store)
        fresh
    end
  end

  defp ensure_dir_entry(schema, parent_uuid, store, name) do
    case Schema.get_entry(schema, name) do
      {:ok, _} ->
        schema

      :error ->
        child_uuid = Schemas.create_dir_with_meta(nil, nil, store)
        :ok = add_dir_entry_into(parent_uuid, name, child_uuid, store)
        {:ok, fresh} = Schemas.load_dir_schema(parent_uuid, store)
        fresh
    end
  end

  @doc "Returns the UUID of /bd/issues/, ensuring the tree exists."
  def issues_dir_uuid(root_uuid, store \\ CommitStoreClient) do
    bd_uuid = ensure_bd_dir(root_uuid, store)
    {:ok, schema} = Schemas.load_dir_schema(bd_uuid, store)
    {:ok, entry} = Schema.get_entry(schema, @issues_dir)
    entry.node_id
  end

  @doc "Returns the UUID of /bd/labels/."
  def labels_dir_uuid(root_uuid, store \\ CommitStoreClient) do
    bd_uuid = ensure_bd_dir(root_uuid, store)
    {:ok, schema} = Schemas.load_dir_schema(bd_uuid, store)
    {:ok, entry} = Schema.get_entry(schema, @labels_dir)
    entry.node_id
  end

  @doc """
  Returns `{:ok, deps_uuid}` for /bd/deps.json (the file doc, not the
  directory). The deps doc holds every edge in the dependency graph
  per spec §2.3.
  """
  def deps_uuid(root_uuid, store \\ CommitStoreClient) do
    bd_uuid = ensure_bd_dir(root_uuid, store)
    {:ok, schema} = Schemas.load_dir_schema(bd_uuid, store)
    {:ok, entry} = Schema.get_entry(schema, Schemas.deps_filename())
    {:ok, entry.node_id}
  end

  @doc "Returns `{:ok, meta_uuid}` for /bd/__meta.json."
  def meta_uuid(root_uuid, store \\ CommitStoreClient) do
    bd_uuid = ensure_bd_dir(root_uuid, store)
    {:ok, schema} = Schemas.load_dir_schema(bd_uuid, store)
    {:ok, entry} = Schema.get_entry(schema, Schemas.meta_filename())
    {:ok, entry.node_id}
  end

  @doc "Loads the workspace meta config."
  def load_meta(root_uuid, store \\ CommitStoreClient) do
    {:ok, uuid} = meta_uuid(root_uuid, store)
    Schemas.load_meta_doc(uuid, store)
  end

  @doc "Lists all issue directory entries under /bd/issues/."
  def list_issue_entries(root_uuid, store \\ CommitStoreClient) do
    issues = issues_dir_uuid(root_uuid, store)

    case Schemas.load_dir_schema(issues, store) do
      {:ok, schema} ->
        schema
        |> Schema.list_entries()
        |> Enum.filter(fn e -> e.type == :dir and String.ends_with?(e.name, ".iss") end)

      _ ->
        []
    end
  end

  @doc "Looks up an issue directory by id (without the .iss suffix). Returns `{:ok, uuid}` or `:error`."
  def issue_dir_uuid(root_uuid, id, store \\ CommitStoreClient) do
    issues = issues_dir_uuid(root_uuid, store)
    {:ok, schema} = Schemas.load_dir_schema(issues, store)

    case Schema.get_entry(schema, "#{id}.iss") do
      {:ok, entry} -> {:ok, entry.node_id}
      :error -> :error
    end
  end

  # Bd P2 Slice S4: the custody-token path namespace. Bursar tokens
  # share the document path namespace (see `Commonplace.Green.Bursar`'s
  # moduledoc), so a claim path is prefixed under a `__`-namespaced
  # segment to avoid ever colliding with a real doc path — the same
  # convention `__bursar.json`/`__bursar.log` themselves use, and the
  # one GitBridge/Sync.Agent already skip on `__`-prefix.
  @claim_prefix "__bd_claim__"

  @doc """
  The stable custody-token path for ticket `id` — 1:1 with the ticket,
  derived from its issue-dir uuid (not the id string) so a renamed
  prefix or id-mint scheme can't shift custody out from under a held
  token. Returns `{:ok, path}` or `:error` if the ticket doesn't
  resolve to a directory.
  """
  def claim_path(root_uuid, id, store \\ CommitStoreClient) do
    case issue_dir_uuid(root_uuid, id, store) do
      {:ok, dir_uuid} -> {:ok, @claim_prefix <> "/" <> dir_uuid}
      :error -> :error
    end
  end

  @doc "Bang variant of `claim_path/3` — raises if the ticket doesn't resolve."
  def claim_path!(root_uuid, id, store \\ CommitStoreClient) do
    case claim_path(root_uuid, id, store) do
      {:ok, path} -> path
      :error -> raise "claim_path: no such ticket #{inspect(id)}"
    end
  end

  @doc "Looks up a label dir by name."
  def label_dir_uuid(root_uuid, name, store \\ CommitStoreClient) do
    labels = labels_dir_uuid(root_uuid, store)
    {:ok, schema} = Schemas.load_dir_schema(labels, store)

    case Schema.get_entry(schema, "#{name}.lbl") do
      {:ok, entry} -> {:ok, entry.node_id}
      :error -> :error
    end
  end

  ## Private helpers

  defp add_dir_entry(parent_uuid, name, child_uuid, store) do
    {:ok, schema} = Schemas.load_dir_schema(parent_uuid, store)
    schema = Schema.add_directory(schema, name, child_uuid)
    update = Encoding.encode_update(schema)
    CommitStoreClient.create_chained_commit(store, parent_uuid, update)
    :ok
  end

  defp add_dir_entry_into(parent_uuid, name, child_uuid, store) do
    {:ok, schema} = Schemas.load_dir_schema(parent_uuid, store)
    schema = Schema.add_directory(schema, name, child_uuid)
    update = Encoding.encode_update(schema)
    CommitStoreClient.create_chained_commit(store, parent_uuid, update)
    :ok
  end

  defp add_file_entry(parent_uuid, name, child_uuid, store) do
    {:ok, schema} = Schemas.load_dir_schema(parent_uuid, store)
    schema = Schema.add_file(schema, name, child_uuid)
    update = Encoding.encode_update(schema)
    CommitStoreClient.create_chained_commit(store, parent_uuid, update)
    :ok
  end
end
