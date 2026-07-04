defmodule Commonplace.GitBridge.Exporter do
  @moduledoc """
  Renders the CRDT document tree rooted at a mount UUID onto a plain
  directory (a git working tree, though this module knows nothing about
  git — that's `Commonplace.GitBridge.Git`'s job).

  This bridge is strictly ONE-WAY: CRDT store -> filesystem. It never
  writes back to the store (other than the presence doc GitBridge.Server
  maintains, which lives outside this module).

  ## Filters

  A schema entry is skipped — never exported, never present in the
  returned manifest — when any of:

    * its name starts with `"__"` (reserved/system entries);
    * its `sync` flag is `false` (deactivated branches, CX-edy-adjacent
      local-only parking);
    * `Commonplace.Presence.parse_honorific/1` recognizes its name as a
      presence file (`.bot` / `.exe` / `.usr` / `.who`) — presence is
      workspace liveness plumbing, not tree content bound for git.

  ## Renderers

    * `:text` — the content string as-is.
    * `:map` / `:array` — `Commonplace.GitBridge.CanonicalJson.encode/1`
      of the Elixir term (`ContentType.get_content/1` already turns
      both into JSON-shaped data: a map or a list).
    * `:xml` — `Commonplace.Document.ContentType` has no serialized-
      string accessor for xml (only `materialize_xml_fragment`, which
      returns a tree of `{:element, tag, attrs, children}` /
      `{:text, str}` / `{:fragment, children}` tuples). There is no
      "existing serialized XML string" to reuse, so this renders the
      materialized tree through `CanonicalJson` after converting the
      tuple tree to plain maps — deterministic, diffable, and lossless
      over the same data `get_content/1` already exposes. Documented
      here as the deviation from the original one-line renderer
      sketch (no string accessor exists to reuse as-is).
    * anything else (nil type, doc reconstruction failure) — skipped;
      a human-readable warning string is appended to the result's
      `warnings` list instead of writing `inspect()`-style garbage to
      disk.

  ## Manifest and pruning

  Returns a manifest of every exported doc keyed by its repo-relative
  path: `%{rel_path => %{uuid:, type:, anchor:}}` where `anchor` is the
  raw commit id binary from `CommitStoreClient.latest_commit/2` (hex
  encoding is `Sidecar`'s job, not this module's).

  Given `previous_manifest` (only its keys matter), any rel_path that
  was exported last cycle but is absent from this cycle's manifest is
  pruned from `repo_dir` — file removed (or directory removed
  recursively, though only file entries land in the manifest). `.git`
  and `.commonplace` are hard-excluded from pruning, defensively, even
  though the manifest's own keys should never point there.
  """

  alias Commonplace.Tree.{Schema, DocBuilder}
  alias Commonplace.Document.ContentType
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Presence
  alias Commonplace.GitBridge.CanonicalJson
  alias Commonplace.Sync.Export

  @protected_prefixes [".git", ".commonplace"]

  @doc """
  Export the tree rooted at `mount_uuid` into `repo_dir`.

  Returns `{:ok, %{manifest:, authors:, warnings:}}` or `{:error, reason}`.
  """
  @spec export(String.t(), String.t(), module() | atom(), map()) ::
          {:ok, %{manifest: map(), authors: MapSet.t(), warnings: [String.t()]}}
          | {:error, term()}
  def export(mount_uuid, repo_dir, store, previous_manifest \\ %{}) do
    File.mkdir_p!(repo_dir)

    schema_doc = load_schema(mount_uuid, store)

    {manifest, authors, warnings} =
      walk(schema_doc, repo_dir, "", store, %{}, MapSet.new(), [])

    prune(repo_dir, previous_manifest, manifest)

    {:ok, %{manifest: manifest, authors: authors, warnings: warnings}}
  rescue
    error -> {:error, error}
  end

  # --- Tree walk ---

  defp walk(schema_doc, dir_path, rel_prefix, store, manifest, authors, warnings) do
    Schema.list_entries(schema_doc)
    |> Enum.filter(&eligible?/1)
    |> Enum.reduce({manifest, authors, warnings}, fn entry, {manifest, authors, warnings} ->
      rel_path = join_rel(rel_prefix, entry.name)

      case entry.type do
        :dir ->
          sub_dir = Path.join(dir_path, entry.name)
          File.mkdir_p!(sub_dir)
          sub_schema = load_schema(entry.node_id, store)
          walk(sub_schema, sub_dir, rel_path, store, manifest, authors, warnings)

        :doc ->
          export_doc(entry, dir_path, rel_path, store, manifest, authors, warnings)

        _ ->
          {manifest, authors, [warning("unknown entry type for #{entry.name}") | warnings]}
      end
    end)
  end

  defp eligible?(entry) do
    not String.starts_with?(entry.name, "__") and
      entry.sync != false and
      match?(:error, Presence.parse_honorific(entry.name))
  end

  defp export_doc(entry, dir_path, rel_path, store, manifest, authors, warnings) do
    case DocBuilder.reconstruct_doc(store, entry.node_id) do
      :none ->
        {manifest, authors, [warning("no commits for #{rel_path} (#{entry.node_id})") | warnings]}

      {:ok, doc} ->
        type = ContentType.get_type(doc)

        case render(type, doc) do
          {:ok, content} ->
            path = Path.join(dir_path, entry.name)
            Export.atomic_write(path, content)

            {anchor, signer_id} = head_info(store, entry.node_id)

            manifest =
              Map.put(manifest, rel_path, %{uuid: entry.node_id, type: type, anchor: anchor})

            authors = if is_nil(signer_id), do: authors, else: MapSet.put(authors, signer_id)

            {manifest, authors, warnings}

          :skip ->
            {manifest, authors,
             [warning("unrenderable content type #{inspect(type)} for #{rel_path}") | warnings]}
        end
    end
  end

  defp render(:text, doc), do: {:ok, ContentType.get_content(doc) || ""}

  defp render(:map, doc), do: {:ok, CanonicalJson.encode(ContentType.get_content(doc) || %{})}

  defp render(:array, doc), do: {:ok, CanonicalJson.encode(ContentType.get_content(doc) || [])}

  defp render(:xml, doc) do
    tree = ContentType.get_content(doc) || []
    {:ok, CanonicalJson.encode(xml_to_json(tree))}
  end

  defp render(_other, _doc), do: :skip

  defp xml_to_json(list) when is_list(list), do: Enum.map(list, &xml_to_json/1)

  defp xml_to_json({:element, tag, attrs, children}) do
    %{"tag" => tag, "attrs" => Map.new(attrs), "children" => xml_to_json(children)}
  end

  defp xml_to_json({:text, str}), do: %{"text" => str}
  defp xml_to_json({:fragment, children}), do: %{"fragment" => xml_to_json(children)}

  defp head_info(store, uuid) do
    case CommitStoreClient.latest_commit(store, uuid) do
      {:ok, commit} -> {commit.id, Map.get(commit, :signer_id)}
      :none -> {nil, nil}
    end
  end

  defp load_schema(uuid, store) do
    case DocBuilder.reconstruct_snapshot(store, uuid) do
      {:ok, doc} -> doc
      :none -> Schema.new_schema()
    end
  end

  defp join_rel("", name), do: name
  defp join_rel(prefix, name), do: prefix <> "/" <> name

  defp warning(msg), do: msg

  # --- Pruning ---

  defp prune(repo_dir, previous_manifest, new_manifest) do
    previous_manifest
    |> Map.keys()
    |> Enum.reject(&(Map.has_key?(new_manifest, &1)))
    |> Enum.each(fn rel_path -> prune_one(repo_dir, rel_path) end)
  end

  defp prune_one(repo_dir, rel_path) do
    if protected?(rel_path) do
      :ok
    else
      full_path = Path.join(repo_dir, rel_path)
      File.rm_rf(full_path)
      cleanup_empty_dirs(repo_dir, Path.dirname(rel_path))
    end
  end

  defp cleanup_empty_dirs(_repo_dir, "."), do: :ok
  defp cleanup_empty_dirs(_repo_dir, ""), do: :ok

  defp cleanup_empty_dirs(repo_dir, rel_dir) do
    if protected?(rel_dir) do
      :ok
    else
      full_dir = Path.join(repo_dir, rel_dir)

      case File.ls(full_dir) do
        {:ok, []} ->
          File.rmdir(full_dir)
          cleanup_empty_dirs(repo_dir, Path.dirname(rel_dir))

        _ ->
          :ok
      end
    end
  end

  defp protected?(rel_path) do
    Enum.any?(@protected_prefixes, fn prefix ->
      rel_path == prefix or String.starts_with?(rel_path, prefix <> "/")
    end)
  end
end
