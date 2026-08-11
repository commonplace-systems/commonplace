defmodule Commonplace.Workspace.RootWritePolicy do
  @moduledoc """
  Enforces the registered substrate namespace at the workspace-root write seam.

  Registered root entries and their accepting workspace classes are:

    * `bd` — `:default`
    * `chat` — `:default`
    * `__bursar.json` — `:default`
    * `__bursar.log` — `:default`
    * `__identities__` — `:default`
    * `__processes.json` — `:default`
    * `__pulls` — `:default`
    * `__recipes` — `:default`
    * `__reflog` — `:default`
    * `__system` — `:default`

  New substrate root entries use the `__` prefix.

  The named residual is that an author who both skips registration and uses a
  bare name lands as content; the fadm torn-state refusal remains the existing
  tripwire for import-only cells.
  """

  require Logger

  alias Commonplace.Store.Commit
  alias Commonplace.Tree.{DocBuilder, Schema}
  alias Yelixer.{Doc, Encoding}

  @registered_entries %{
    "bd" => [:default],
    "chat" => [:default],
    "__bursar.json" => [:default],
    "__bursar.log" => [:default],
    "__identities__" => [:default],
    "__processes.json" => [:default],
    "__pulls" => [:default],
    "__recipes" => [:default],
    "__reflog" => [:default],
    "__system" => [:default]
  }

  @doc false
  def check(%Commit{} = commit, store, data_dir) do
    with {:ok, root_uuid} <- read_root_uuid(data_dir),
         true <- commit.doc_uuid == root_uuid,
         {:ok, before_doc} <- reconstruct_root(store, root_uuid),
         {:ok, profile} <- workspace_profile(before_doc),
         {:ok, after_doc} <- Encoding.apply_update(before_doc, commit.update) do
      refused_entry(before_doc, after_doc, profile)
    else
      false ->
        :ok

      {:error, :enoent} ->
        :ok

      {:error, :workspace_profile_missing} = error ->
        Logger.error(
          "CommitStore: versioned workspace root #{commit.doc_uuid} has no workspace profile; " <>
            "this is a post-field corruption, not a legacy-default workspace"
        )

        error

      {:error, _reason} = error ->
        error

      :none ->
        :ok
    end
  end

  defp workspace_profile(doc) do
    case Schema.workspace_profile(doc) do
      {:ok, profile} -> {:ok, profile}
      :absent -> {:ok, :default}
      {:error, _reason} = error -> error
    end
  end

  defp refused_entry(before_doc, after_doc, profile) do
    before_entries = before_doc |> Schema.entries() |> Map.keys() |> MapSet.new()

    refused =
      after_doc
      |> Schema.entries()
      |> Map.keys()
      |> MapSet.new()
      |> MapSet.difference(before_entries)
      |> Enum.sort()
      |> Enum.find(&refused?(&1, profile))

    case refused do
      nil ->
        :ok

      entry ->
        {:error,
         "workspace class '#{profile}' does not accept root entry '#{entry}' — declared in profile"}
    end
  end

  defp refused?(entry, profile) do
    case Map.fetch(@registered_entries, entry) do
      {:ok, accepting_classes} -> profile not in accepting_classes
      :error -> String.starts_with?(entry, "__")
    end
  end

  defp read_root_uuid(data_dir) do
    case File.read(Path.join(data_dir, "root")) do
      {:ok, value} -> {:ok, String.trim(value)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp reconstruct_root(store, root_uuid) do
    case DocBuilder.reconstruct_snapshot(store, root_uuid) do
      {:ok, doc} -> {:ok, doc}
      :none -> {:ok, Doc.new()}
      {:error, _reason} = error -> error
    end
  end
end
