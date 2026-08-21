defmodule Commonplace.GitBridge.Exporter do
  @moduledoc """
  Renders the CRDT document tree rooted at a mount UUID onto a plain
  directory (a git working tree, though this module knows nothing about
  git — that's `Commonplace.GitBridge.Git`'s job).

  This bridge is strictly ONE-WAY: CRDT store -> filesystem. It never
  writes back to the store (other than the presence doc GitBridge.Server
  maintains, which lives outside this module).

  ## Verified export at a pin (chit epic step [6]-wiring)

  Each doc's content and each directory schema is read through the
  **verified-projection oracle** (`Commonplace.Projection.project_doc_at/3`,
  the built [5] layer) rather than raw reconstruction, so every exported
  byte carries a VERDICT — and a corrupted/tampered store can no longer be
  silently reproduced as a clean-looking tree (the re-measure's Finding 4:
  62% of byte-flips are absorbed at the reconstruction layer; `project_at`
  catches them loud via content-address + signature).

    * **`pin`** — an optional `%{uuid => commit_id}` map (the shape
      `Black.select`'s `at_pin` uses). A uuid present in `pin` is read at
      that commit; a uuid absent falls back to its current head. The
      default `pin = %{}` reproduces the head-only export exactly — the
      existing behavior is the "pin at current heads" case (acceptance #5).

    * **Byte-identical tree (F5).** The verdict is ADDED metadata; the tree
      bytes are unchanged. `project_doc_at` yields the DOC (and the verdict);
      the doc is rendered through the SAME renderers as before, so an
      untampered export is byte-for-byte identical to the pre-wiring path.
      Content docs declare `head_path: :chain` (matching the old
      `reconstruct_doc`); schemas declare `head_path: :direct` (matching the
      old `reconstruct_snapshot`). We never write `project_at`'s
      `canonical_bytes` (a yjs-update form) as tree content — that would
      trade Finding 4 for a Finding 5 (SHA-stability) regression.

    * **Tamper is UNMISSABLE, not merely trailer-flagged.** The verdict
      classification splits absence-of-verification from positive-detection:
      - CLEAN (`:witnessed` / `{:corroborated,_}` / `{:declared,_}`) and
        honest-unverified — rendered normally, verdict carried in the
        manifest (→ trailer). `:declared`/unsigned is honest "unverified,"
        NOT loud (64% of the corpus is unsigned legacy; hard-failing it
        would make the exporter useless — unverified ≠ wrong).
      - TAMPER-DETECTED (`{:error, :signature_invalid}`,
        `{:error, {:content_address_mismatch,_}}`,
        `{:unknown, {:conflicted,_}}`, `{:unknown, {:mixed_plane,_}}`, or any
        unexpected verdict — fail-closed) — a POSITIVE detection of
        wrong/disagreeing bytes. The doc's clean-looking bytes are NOT
        written; a loud in-tree TAMPER marker takes their place, the doc is
        recorded as an offender, and `export/5` returns
        `{:error, {:unverifiable_pin, offenders}}`. A git-repo-as-source
        consumer never receives a clean tree containing tampered content,
        because no clean tree is produced.

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
  path: `%{rel_path => %{uuid:, type:, anchor:, verdict:}}` where `anchor`
  is the raw commit id binary the doc was read at (the pinned commit, or the
  head when unpinned) and `verdict` is the projection verdict term (hex
  encoding + trailer formatting is `Sidecar`'s job, not this module's).

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

  alias Commonplace.Tree.Schema
  alias Commonplace.Document.ContentType
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Projection
  alias Commonplace.Presence
  alias Commonplace.GitBridge.{CanonicalJson, CanonicalXml}
  alias Commonplace.MUD.Schemas
  alias Commonplace.Sync.Export
  alias Commonplace.Trust.ReadMeta

  @protected_prefixes [".git", ".commonplace"]

  @doc """
  Export the tree rooted at `mount_uuid` into `repo_dir`.

  `pin` is an optional `%{uuid => commit_id}` map; a uuid absent from it is
  read at its current head. The default (`%{}`) is the head-only export.

  Returns `{:ok, %{manifest:, authors:, warnings:, schema_uuids:}}`, or
  `{:error, {:unverifiable_pin, offenders}}` when one or more docs/schemas
  fail verification (tamper detected — see the moduledoc), or
  `{:error, reason}` on an unexpected error.
  """
  @spec export(String.t(), String.t(), module() | atom(), map(), map()) ::
          {:ok,
           %{
             manifest: map(),
             authors: MapSet.t(),
             warnings: [String.t()],
             schema_uuids: MapSet.t()
           }}
          | {:error, term()}
  def export(mount_uuid, repo_dir, store, previous_manifest \\ %{}, pin \\ %{}) do
    File.mkdir_p!(repo_dir)

    {schema_doc, mount_offenders} = read_schema_at(mount_uuid, pin, store, [])

    {manifest, authors, warnings, schema_uuids, offenders} =
      walk(
        schema_doc,
        repo_dir,
        "",
        store,
        pin,
        %{},
        MapSet.new(),
        [],
        MapSet.new([mount_uuid]),
        mount_offenders
      )

    case offenders do
      [] ->
        prune(repo_dir, previous_manifest, manifest)

        {:ok,
         %{manifest: manifest, authors: authors, warnings: warnings, schema_uuids: schema_uuids}}

      _ ->
        # Tamper detected on at least one doc/schema. Do NOT present a clean
        # tree as a valid export: the loud markers are on disk, and the
        # caller gets an unmissable error listing every offender.
        {:error, {:unverifiable_pin, Enum.reverse(offenders)}}
    end
  rescue
    error -> {:error, error}
  end

  # --- Tree walk ---

  defp walk(
         schema_doc,
         dir_path,
         rel_prefix,
         store,
         pin,
         manifest,
         authors,
         warnings,
         schema_uuids,
         offenders
       ) do
    Schema.list_entries(schema_doc)
    |> Enum.filter(&eligible?/1)
    |> Enum.reduce(
      {manifest, authors, warnings, schema_uuids, offenders},
      fn entry, {manifest, authors, warnings, schema_uuids, offenders} ->
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
            {sub_schema, offenders} = read_schema_at(entry.node_id, pin, store, offenders)

            if capability_gated_zone?(sub_schema, store) do
              Logger.info("GitBridge: skipping capability_gated zone #{rel_path}")
              {manifest, authors, warnings, schema_uuids, offenders}
            else
              sub_dir = Path.join(dir_path, entry.name)
              File.mkdir_p!(sub_dir)
              schema_uuids = MapSet.put(schema_uuids, entry.node_id)

              walk(
                sub_schema,
                sub_dir,
                rel_path,
                store,
                pin,
                manifest,
                authors,
                warnings,
                schema_uuids,
                offenders
              )
            end

          :doc ->
            {manifest, authors, warnings, offenders} =
              export_doc(
                entry,
                dir_path,
                rel_path,
                store,
                pin,
                manifest,
                authors,
                warnings,
                offenders
              )

            {manifest, authors, warnings, schema_uuids, offenders}

          _ ->
            {manifest, authors, [warning("unknown entry type for #{entry.name}") | warnings],
             schema_uuids, offenders}
        end
      end
    )
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

  defp export_doc(entry, dir_path, rel_path, store, pin, manifest, authors, warnings, offenders) do
    case pin_commit(pin, entry.node_id, store) do
      :none ->
        {manifest, authors, [warning("no commits for #{rel_path} (#{entry.node_id})") | warnings],
         offenders}

      commit_id ->
        # Content docs matched the old `reconstruct_doc` (chain replay), so
        # declare head_path: :chain to keep head-export bytes identical.
        case Projection.project_doc_at(entry.node_id, commit_id, store: store, head_path: :chain) do
          {:ok, doc, verdict} ->
            type = ContentType.get_type(doc)

            case render(type, doc) do
              {:ok, content, extra_warning} ->
                path = Path.join(dir_path, entry.name)
                Export.atomic_write(path, content)

                signer_id = commit_signer(store, commit_id)

                manifest =
                  Map.put(manifest, rel_path, %{
                    uuid: entry.node_id,
                    type: type,
                    anchor: commit_id,
                    verdict: verdict
                  })

                authors = if is_nil(signer_id), do: authors, else: MapSet.put(authors, signer_id)

                warnings = if extra_warning, do: [extra_warning | warnings], else: warnings

                {manifest, authors, warnings, offenders}

              :skip ->
                {manifest, authors,
                 [
                   warning("unrenderable content type #{inspect(type)} for #{rel_path}")
                   | warnings
                 ], offenders}
            end

          {:error, reason} = verdict ->
            classify_leaf_failure(
              reason,
              verdict,
              entry,
              dir_path,
              rel_path,
              commit_id,
              manifest,
              authors,
              warnings,
              offenders
            )

          {:unknown, _reason} = verdict ->
            # A positive detection of wrong/disagreeing bytes (conflicted,
            # mixed_plane). Loud, never silent.
            tamper_leaf(
              entry,
              dir_path,
              rel_path,
              commit_id,
              verdict,
              manifest,
              authors,
              warnings,
              offenders
            )
        end
    end
  end

  # `:commit_not_found` / `:commit_not_on_chain` are absence, not tamper —
  # a warning like the old `:none`. Every other `{:error, _}` (signature or
  # content-address failure, or an unexpected shape) is a positive tamper
  # detection and is loud.
  defp classify_leaf_failure(
         reason,
         _verdict,
         entry,
         _dir,
         rel_path,
         _cid,
         manifest,
         authors,
         warnings,
         offenders
       )
       when reason in [:commit_not_found, :commit_not_on_chain] or
              (is_tuple(reason) and elem(reason, 0) in [:commit_not_found, :commit_not_on_chain]) do
    {manifest, authors,
     [
       warning("no projectable commit for #{rel_path} (#{entry.node_id}): #{inspect(reason)}")
       | warnings
     ], offenders}
  end

  defp classify_leaf_failure(
         _reason,
         verdict,
         entry,
         dir_path,
         rel_path,
         commit_id,
         manifest,
         authors,
         warnings,
         offenders
       ) do
    tamper_leaf(
      entry,
      dir_path,
      rel_path,
      commit_id,
      verdict,
      manifest,
      authors,
      warnings,
      offenders
    )
  end

  # Write an unmissable in-tree marker in place of the tampered doc's bytes,
  # record the offender, and let export/5 turn a non-empty offender list into
  # {:error, {:unverifiable_pin, _}}. The marker means even a consumer that
  # ignores the error never reads tampered bytes as clean.
  defp tamper_leaf(
         entry,
         dir_path,
         rel_path,
         commit_id,
         verdict,
         manifest,
         authors,
         warnings,
         offenders
       ) do
    path = Path.join(dir_path, entry.name)
    Export.atomic_write(path, tamper_marker(entry.node_id, commit_id, verdict))

    {manifest, authors,
     [
       warning("TAMPER: #{rel_path} (#{entry.node_id}) failed verification: #{inspect(verdict)}")
       | warnings
     ], [{rel_path, entry.node_id, verdict} | offenders]}
  end

  defp tamper_marker(uuid, commit_id, verdict) do
    """
    COMMONPLACE EXPORT: VERIFICATION FAILED — DO NOT TREAT AS SOURCE
    doc:      #{uuid}
    commit:   #{Base.encode16(commit_id, case: :lower)}
    verdict:  #{inspect(verdict)}
    This file's real content failed the verified-projection check (tamper or
    irreconcilable disagreement). Its bytes are withheld deliberately so a
    corrupted store cannot be reproduced as a clean-looking tree.
    """
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

  # The commit a uuid is read at: its pinned commit if `pin` names one, else
  # its current head. `:none` when the doc has no commits at all.
  defp pin_commit(pin, uuid, store) do
    case Map.get(pin, uuid) do
      nil ->
        case CommitStoreClient.latest_commit(store, uuid) do
          {:ok, commit} -> commit.id
          :none -> :none
        end

      commit_id ->
        commit_id
    end
  end

  defp commit_signer(store, commit_id) do
    case CommitStoreClient.get_commit(store, commit_id) do
      {:ok, commit} -> Map.get(commit, :signer_id)
      _ -> nil
    end
  end

  # Read a directory schema at its pin (or head), through the verified
  # oracle. Schemas matched the old `reconstruct_snapshot` (latest-only), so
  # declare head_path: :direct to keep the head structure identical. A
  # tampered schema is an offender (loud) but returns an empty schema so the
  # walk terminates cleanly under the eventual {:error, _} rather than
  # crashing mid-tree.
  defp read_schema_at(uuid, pin, store, offenders) do
    case pin_commit(pin, uuid, store) do
      :none ->
        {Schema.new_schema(), offenders}

      commit_id ->
        case Projection.project_doc_at(uuid, commit_id, store: store, head_path: :direct) do
          {:ok, doc, _verdict} ->
            {doc, offenders}

          {:error, reason}
          when reason in [:commit_not_found, :commit_not_on_chain] or
                 (is_tuple(reason) and
                    elem(reason, 0) in [:commit_not_found, :commit_not_on_chain]) ->
            {Schema.new_schema(), offenders}

          other ->
            {Schema.new_schema(), [{:schema, uuid, other} | offenders]}
        end
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
