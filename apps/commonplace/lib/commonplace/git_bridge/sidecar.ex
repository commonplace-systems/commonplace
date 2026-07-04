defmodule Commonplace.GitBridge.Sidecar do
  @moduledoc """
  Owns `<repo_dir>/.commonplace/` — the per-doc provenance metadata that
  rides alongside GitBridge's exported working tree.

  For every exported doc at `rel_path`, writes a mirror JSON file at
  `.commonplace/<rel_path>.json` holding `uuid`, `type`, and `anchor`
  (the exporting commit id, hex-encoded). A `.commonplace/mount.json`
  records the mount UUID for the whole export. `.gitattributes` is
  nudged to mark `.commonplace/**` as `-diff` so large/binary-ish
  provenance blobs don't spam `git diff` output.
  """

  alias Commonplace.GitBridge.CanonicalJson
  alias Commonplace.Sync.Export

  @sidecar_dir ".commonplace"
  @mount_file "mount.json"
  @gitattributes_line ".commonplace/** -diff"

  @doc """
  Write sidecar JSON for every entry in `manifest`, plus `mount.json`.

  Prunes sidecar entries whose rel_path was in `previous_manifest` but
  is absent from `manifest` (mirrors the main-tree prune boundary).
  """
  @spec write(String.t(), String.t(), map(), map()) :: :ok
  def write(repo_dir, mount_uuid, manifest, previous_manifest \\ %{}) do
    Enum.each(manifest, fn {rel_path, %{uuid: uuid, type: type, anchor: anchor}} ->
      json =
        CanonicalJson.encode(%{
          "uuid" => uuid,
          "type" => to_string(type),
          "anchor" => encode_anchor(anchor)
        })

      Export.atomic_write(sidecar_path(repo_dir, rel_path), json)
    end)

    mount_json = CanonicalJson.encode(%{"mount_uuid" => mount_uuid, "format" => 1})
    Export.atomic_write(Path.join([repo_dir, @sidecar_dir, @mount_file]), mount_json)

    prune(repo_dir, previous_manifest, manifest)

    :ok
  end

  @doc """
  Ensure `<repo_dir>/.gitattributes` contains the `.commonplace/** -diff`
  line. Appends only if missing; creates the file fresh if absent.
  Never duplicates the line, never clobbers other content.
  """
  @spec ensure_gitattributes(String.t()) :: :ok
  def ensure_gitattributes(repo_dir) do
    path = Path.join(repo_dir, ".gitattributes")

    case File.read(path) do
      {:ok, contents} ->
        lines = String.split(contents, "\n")

        if Enum.any?(lines, &(String.trim(&1) == @gitattributes_line)) do
          :ok
        else
          trailing_nl? = String.ends_with?(contents, "\n") or contents == ""
          sep = if trailing_nl? or contents == "", do: "", else: "\n"
          File.write!(path, contents <> sep <> @gitattributes_line <> "\n")
        end

      {:error, :enoent} ->
        File.write!(path, @gitattributes_line <> "\n")
    end

    :ok
  end

  @doc """
  Reconstruct a previous_manifest-shaped map (`rel_path => info`) by
  walking `.commonplace/` for `.json` files (excluding `mount.json`).
  Used by `Server` to recover the prune boundary across process
  restarts, when there's no in-memory `last_manifest` to fall back on.
  """
  @spec read_previous_manifest(String.t()) :: map()
  def read_previous_manifest(repo_dir) do
    sidecar_dir = Path.join(repo_dir, @sidecar_dir)

    if File.dir?(sidecar_dir) do
      sidecar_dir
      |> find_json_files()
      |> Enum.reduce(%{}, fn full_path, acc ->
        rel_to_sidecar = Path.relative_to(full_path, sidecar_dir)

        if rel_to_sidecar == @mount_file do
          acc
        else
          rel_path = String.replace_suffix(rel_to_sidecar, ".json", "")

          case File.read(full_path) do
            {:ok, contents} ->
              case Jason.decode(contents) do
                {:ok, info} -> Map.put(acc, rel_path, info)
                _ -> acc
              end

            _ ->
              acc
          end
        end
      end)
    else
      %{}
    end
  end

  # --- Private ---

  defp sidecar_path(repo_dir, rel_path) do
    Path.join([repo_dir, @sidecar_dir, rel_path <> ".json"])
  end

  defp encode_anchor(nil), do: nil
  defp encode_anchor(anchor) when is_binary(anchor), do: Base.encode16(anchor, case: :lower)

  defp find_json_files(dir) do
    dir
    |> File.ls!()
    |> Enum.flat_map(fn entry ->
      full = Path.join(dir, entry)

      cond do
        File.dir?(full) -> find_json_files(full)
        String.ends_with?(entry, ".json") -> [full]
        true -> []
      end
    end)
  end

  defp prune(repo_dir, previous_manifest, manifest) do
    previous_manifest
    |> Map.keys()
    |> Enum.reject(&Map.has_key?(manifest, &1))
    |> Enum.each(fn rel_path ->
      File.rm(sidecar_path(repo_dir, rel_path))
    end)
  end
end
