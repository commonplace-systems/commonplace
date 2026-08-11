defmodule Commonplace.Sync.BinaryWriteBack do
  @moduledoc """
  Safely materializes a binary envelope from the artifact CAS.

  Fetch, streamed write, and mode application all happen against a unique
  sibling temporary file. Only a fully written and chmod'd temp is renamed
  over the destination. Every failure is a loud named skip and leaves any
  prior destination intact; envelope data is never written as file bytes.
  """

  require Logger

  alias Commonplace.Store.ArtifactStore

  @spec write(ArtifactStore.t(), map(), String.t()) :: :ok | {:skipped, term()}
  def write(%ArtifactStore{} = store, envelope, path) do
    tmp_path =
      Path.join(Path.dirname(path), ".#{Path.basename(path)}.artifact.tmp.#{unique_suffix()}")

    result =
      with {:ok, stream} <- fetch(store, envelope.cid),
           :ok <- File.mkdir_p(Path.dirname(path)),
           :ok <- stream_to_file(stream, tmp_path),
           :ok <- apply_mode(tmp_path, envelope.mode),
           :ok <- rename(tmp_path, path) do
        :ok
      end

    case result do
      :ok ->
        :ok

      {:error, reason} ->
        _ = File.rm(tmp_path)
        Logger.warning("BinaryWriteBack: skipping #{path} (#{inspect(reason)})")
        {:skipped, reason}
    end
  end

  defp fetch(store, cid) do
    case ArtifactStore.get(store, cid) do
      {:ok, stream} -> {:ok, stream}
      {:error, reason} -> {:error, {:artifact_fetch_failed, reason}}
    end
  end

  defp stream_to_file(stream, tmp_path) do
    case File.open(tmp_path, [:write, :binary, :exclusive]) do
      {:ok, io} ->
        try do
          case Enum.reduce_while(stream, :ok, fn chunk, :ok ->
                 case IO.binwrite(io, chunk) do
                   :ok -> {:cont, :ok}
                   {:error, reason} -> {:halt, {:error, {:artifact_write_failed, reason}}}
                 end
               end) do
            :ok ->
              case :file.datasync(io) do
                :ok -> :ok
                {:error, reason} -> {:error, {:artifact_write_failed, reason}}
              end

            {:error, _} = error ->
              error
          end
        rescue
          error -> {:error, {:artifact_read_failed, Exception.message(error)}}
        after
          File.close(io)
        end

      {:error, reason} ->
        {:error, {:artifact_write_failed, reason}}
    end
  end

  defp apply_mode(path, mode) do
    case File.chmod(path, mode) do
      :ok -> :ok
      {:error, reason} -> {:error, {:artifact_mode_failed, reason}}
    end
  end

  defp rename(tmp_path, path) do
    case File.rename(tmp_path, path) do
      :ok -> :ok
      {:error, reason} -> {:error, {:artifact_rename_failed, reason}}
    end
  end

  defp unique_suffix do
    "#{System.unique_integer([:positive, :monotonic])}.#{:erlang.phash2(self())}"
  end
end
