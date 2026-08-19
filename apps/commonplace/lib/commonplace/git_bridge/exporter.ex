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
      workspace liveness plumbing, not tree content bound for git;
    * its name is not filesystem-safe (`"."`, `".."`, empty, or contains
      `/`, `\\`, or a NUL byte) — entry names come from the CRDT store
      and are joined into paths under `repo_dir`, so a traversal-shaped
      name must never reach `Path.join`.

  ## Renderers

    * `:text` — the content string as-is.
    * `:map` / `:array` — `Commonplace.GitBridge.CanonicalJson.encode/1`
      of the Elixir term (`ContentType.get_content/1` already turns
      both into JSON-shaped data: a map or a list).
    * `:xml` — `Commonplace.GitBridge.CanonicalXml.encode/1` of the
      materialized tuple tree (`ContentType.get_content/1` returns a
      tree of `{:element, tag, attrs, children}` / `{:text, str}` /
      `{:fragment, children}` tuples for `:xml` docs) — pretty-printed,
      deterministic, human-readable XML text (CX-b0ow.5). This is what
      makes outliner `_outline` trees and chat `_view.xml` files
      actually readable in git, the whole point of the export. If
      `CanonicalXml.encode/1` returns `{:error, _}` (a shape it can't
      serialize), this falls back to the previous renderer — canonical
      JSON of the tuple tree converted to plain maps — so a doc never
      fails to export outright just because its content is
      XML-shaped in some unexpected way; a warning is recorded either
      way so the fallback is visible, not silent.
    * anything else (nil type, doc reconstruction failure) — skipped;
      a human-readable warning string is appended to the result's
      `warnings` list instead of writing `inspect()`-style garbage to
      disk.

  ## Manifest and pruning

  Returns a manifest of every exported doc keyed by its repo-relative
  path: `%{rel_path => %{uuid:, type:, anchor:}}` where `anchor` is the
  raw commit id binary from `CommitStoreClient.latest_commit/2` (hex
  encoding is `Sidecar`'s job, not this module's).

  Also returns `schema_uuids`: every directory-schema doc uuid visited
  during the walk (including `mount_uuid` itself). `Commonplace.GitBridge.Archive`
  (GitBridge G1.5) reuses this set — schema docs are part of tree
  history and belong in the commit archive, but they never appear in
  `manifest` (that only tracks leaf `:doc` entries), so it would
  otherwise have no way to enumerate them without re-walking the tree
  and re-implementing this module's eligibility filter.

  Given `previous_manifest` (only its keys matter), any rel_path that
  was exported last cycle but is absent from this cycle's manifest is
  pruned from `repo_dir` — file removed (or directory removed
  recursively, though only file entries land in the manifest). `.git`
  and `.commonplace` are hard-excluded from pruning, defensively, even
  though the manifest's own keys should never point there.
  """

  require Logger

  alias Commonplace.Tree.{Schema, DocBuilder}
  alias Commonplace.Document.ContentType
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Presence
  alias Commonplace.GitBridge.{CanonicalJson, CanonicalXml}
  alias Commonplace.MUD.Schemas
  alias Commonplace.Sync.Export
  alias Commonplace.Trust.ReadMeta

  @protected_prefixes [".git", ".commonplace"]

  @doc """
  Export the tree rooted at `mount_uuid` into `repo_dir`.

  Returns `{:ok, %{manifest:, authors:, warnings:, schema_uuids:}}` or
  `{:error, reason}`.
  """
  @spec export(String.t(), String.t(), module() | atom(), map()) ::
          {:ok,
           %{
             manifest: map(),
             authors: MapSet.t(),
             warnings: [String.t()],
             schema_uuids: MapSet.t()
           }}
          | {:error, term()}
  def export(mount_uuid, repo_dir, store, previous_manifest \\ %{}) do
    File.mkdir_p!(repo_dir)

    schema_doc = load_schema(mount_uuid, store)

    {manifest, authors, warnings, schema_uuids} =
      walk(schema_doc, repo_dir, "", store, %{}, MapSet.new(), [], MapSet.new([mount_uuid]))

    prune(repo_dir, previous_manifest, manifest)

    {:ok, %{manifest: manifest, authors: authors, warnings: warnings, schema_uuids: schema_uuids}}
  rescue
    error -> {:error, error}
  end

  # --- Tree walk ---

  defp walk(schema_doc, dir_path, rel_prefix, store, manifest, authors, warnings, schema_uuids) do
    Schema.list_entries(schema_doc)
    |> Enum.filter(&eligible?/1)
    |> Enum.reduce({manifest, authors, warnings, schema_uuids}, fn
      entry, {manifest, authors, warnings, schema_uuids} ->
        rel_path = join_rel(rel_prefix, entry.name)

        case entry.type do
          :dir ->
            # CX-ivqz (read-scoping P2, Seam 5): GitBridge mirrors the
            # workspace to a PUBLIC repo. A `capability_gated` zone's WHOLE
            # SUBTREE must be excluded — otherwise a private home lands on
            # the public internet. Load the sub-schema FIRST and check its
            # own `__room.json` meta: only skip a dir whose OWN room doc is
            # gated. Every default-public entry exports EXACTLY as before
            # (same manifest, same bytes) — the load-bearing no-regression
            # invariant. A dir with no room meta, or a public one, is
            # untouched. (prune/3 retroactively removes a newly-private
            # zone's previously-exported files via manifest-diff.)
            sub_schema = load_schema(entry.node_id, store)

            if capability_gated_zone?(sub_schema, store) do
              Logger.info("GitBridge: skipping capability_gated zone #{rel_path}")
              {manifest, authors, warnings, schema_uuids}
            else
              sub_dir = Path.join(dir_path, entry.name)
              File.mkdir_p!(sub_dir)
              schema_uuids = MapSet.put(schema_uuids, entry.node_id)

              walk(
                sub_schema,
                sub_dir,
                rel_path,
                store,
                manifest,
                authors,
                warnings,
                schema_uuids
              )
            end

          :doc ->
            {manifest, authors, warnings} =
              export_doc(entry, dir_path, rel_path, store, manifest, authors, warnings)

            {manifest, authors, warnings, schema_uuids}

          _ ->
            {manifest, authors, [warning("unknown entry type for #{entry.name}") | warnings],
             schema_uuids}
        end
    end)
  end

  # CX-ivqz: a dir is a gated zone iff its OWN schema carries a
  # `__room.json` room-meta entry whose carried visibility resolves to
  # `:capability_gated`. No room meta, or a public one, → not gated (export
  # normally). Read straight from the room doc's node-signed state via
  # ReadMeta (default-public on any unparseable/absent meta).
  defp capability_gated_zone?(sub_schema, store) do
    case Schema.get_entry(sub_schema, Schemas.room_filename()) do
      {:ok, %{node_id: node_id}} when is_binary(node_id) ->
        ReadMeta.resolve(node_id, store).visibility == :capability_gated

      _no_room_meta ->
        false
    end
  end

  defp eligible?(entry) do
    not String.starts_with?(entry.name, "__") and
      entry.sync != false and
      match?(:error, Presence.parse_honorific(entry.name)) and
      safe_name?(entry.name)
  end

  # Entry names are CRDT-store-controlled data used to build paths under
  # repo_dir. Reject anything that could traverse out of the export tree
  # (or smuggle a path separator into a single schema level).
  defp safe_name?(name) when name in ["", ".", ".."], do: false

  defp safe_name?(name) do
    not (String.contains?(name, "/") or String.contains?(name, "\\") or
           String.contains?(name, <<0>>))
  end

  defp export_doc(entry, dir_path, rel_path, store, manifest, authors, warnings) do
    case DocBuilder.reconstruct_doc(store, entry.node_id) do
      :none ->
        {manifest, authors, [warning("no commits for #{rel_path} (#{entry.node_id})") | warnings]}

      {:ok, doc} ->
        type = ContentType.get_type(doc)

        case render(type, doc) do
          {:ok, content, extra_warning} ->
            path = Path.join(dir_path, entry.name)
            Export.atomic_write(path, content)

            {anchor, signer_id} = head_info(store, entry.node_id)

            manifest =
              Map.put(manifest, rel_path, %{uuid: entry.node_id, type: type, anchor: anchor})

            authors = if is_nil(signer_id), do: authors, else: MapSet.put(authors, signer_id)

            warnings = if extra_warning, do: [extra_warning | warnings], else: warnings

            {manifest, authors, warnings}

          :skip ->
            {manifest, authors,
             [warning("unrenderable content type #{inspect(type)} for #{rel_path}") | warnings]}
        end
    end
  end

  defp render(:text, doc), do: {:ok, ContentType.get_content(doc) || "", nil}

  defp render(:map, doc),
    do: {:ok, CanonicalJson.encode(ContentType.get_content(doc) || %{}), nil}

  defp render(:array, doc),
    do: {:ok, CanonicalJson.encode(ContentType.get_content(doc) || []), nil}

  defp render(:xml, doc) do
    tree = ContentType.get_content(doc) || []

    case CanonicalXml.encode(tree) do
      {:ok, content} ->
        {:ok, content, nil}

      {:error, reason} ->
        # Fallback (documented in the moduledoc above): CanonicalXml
        # couldn't serialize this tree, so render the tuple tree
        # through CanonicalJson instead of failing the export outright.
        {:ok, CanonicalJson.encode(xml_to_json(tree)),
         warning("xml render fell back to JSON (#{inspect(reason)})")}
    end
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
    |> Enum.reject(&Map.has_key?(new_manifest, &1))
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
    traversal?(rel_path) or
      Enum.any?(@protected_prefixes, fn prefix ->
        rel_path == prefix or String.starts_with?(rel_path, prefix <> "/")
      end)
  end

  # A rel_path that could escape repo_dir must never be deleted (or have
  # its parent dirs cleaned): previous manifests can be reconstructed
  # from on-disk sidecar files, so treat them as untrusted too.
  defp traversal?(rel_path) do
    Path.type(rel_path) != :relative or
      ".." in Path.split(rel_path) or
      String.contains?(rel_path, <<0>>)
  end
end
