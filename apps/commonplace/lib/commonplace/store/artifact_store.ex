defmodule Commonplace.Store.ArtifactStore do
  @moduledoc """
  Append-only v1 filesystem CAS for raw artifact bytes.

  Blobs live at `<data_dir>/artifacts/<first-two-sha256>/<sha256>`. Writes
  hash while streaming into a uniquely suffixed sibling temporary file and
  rename only after the complete digest is known. Concurrent publication of
  an already-present target is a successful no-op. Reads are returned as file
  streams, so neither direction requires a whole blob in the BEAM heap.

  Garbage collection is deliberately out of scope for v1. Blob liveness and
  the pin-off-root reachability question are deferred together.
  """

  defstruct [:data_dir]

  @type t :: %__MODULE__{data_dir: String.t()}
  @type cid :: <<_::512>>
  @chunk_size 64 * 1024

  @spec new(String.t()) :: t()
  def new(data_dir) when is_binary(data_dir), do: %__MODULE__{data_dir: data_dir}

  @spec put(t(), Enumerable.t()) :: {:ok, cid()} | {:error, term()}
  def put(%__MODULE__{} = store, enumerable) do
    tmp_dir = Path.join(store.data_dir, "artifacts/.incoming")
    :ok = File.mkdir_p(tmp_dir)
    tmp_path = Path.join(tmp_dir, "put.tmp.#{unique_suffix()}")

    case File.open(tmp_path, [:write, :binary, :exclusive]) do
      {:ok, io} -> write_stream(store, enumerable, io, tmp_path)
      {:error, reason} -> {:error, {:temp_open_failed, reason}}
    end
  end

  @spec get(t(), String.t()) :: {:ok, Enumerable.t()} | {:error, term()}
  def get(%__MODULE__{} = store, cid) do
    with :ok <- validate_cid(cid),
         true <- File.regular?(path(store, cid)) do
      {:ok, File.stream!(path(store, cid), [], @chunk_size)}
    else
      false -> {:error, :enoent}
      {:error, _} = error -> error
    end
  end

  @spec exists?(t(), String.t()) :: boolean()
  def exists?(%__MODULE__{} = store, cid) do
    validate_cid(cid) == :ok and File.regular?(path(store, cid))
  end

  @spec digest(Enumerable.t()) :: {:ok, cid(), non_neg_integer()} | {:error, term()}
  def digest(enumerable) do
    try do
      {hash, size} =
        Enum.reduce(enumerable, {:crypto.hash_init(:sha256), 0}, fn chunk, {hash, size} ->
          bytes = IO.iodata_to_binary(chunk)
          {:crypto.hash_update(hash, bytes), size + byte_size(bytes)}
        end)

      {:ok, encode_hash(:crypto.hash_final(hash)), size}
    rescue
      error -> {:error, {:stream_failed, Exception.message(error)}}
    end
  end

  @doc false
  def temp_paths(%__MODULE__{} = store) do
    Path.wildcard(Path.join(store.data_dir, "artifacts/**/*.tmp.*"))
  end

  @spec path(t(), String.t()) :: String.t()
  def path(%__MODULE__{} = store, cid) do
    Path.join([store.data_dir, "artifacts", String.slice(cid, 0, 2), cid])
  end

  defp write_stream(store, enumerable, io, tmp_path) do
    result =
      try do
        {hash, size} =
          Enum.reduce(enumerable, {:crypto.hash_init(:sha256), 0}, fn chunk, {hash, size} ->
            bytes = IO.iodata_to_binary(chunk)

            case IO.binwrite(io, bytes) do
              :ok -> {:crypto.hash_update(hash, bytes), size + byte_size(bytes)}
              {:error, reason} -> throw({:write_failed, reason})
            end
          end)

        :ok = :file.datasync(io)
        {:ok, encode_hash(:crypto.hash_final(hash)), size}
      rescue
        error -> {:error, {:stream_failed, Exception.message(error)}}
      catch
        {:write_failed, reason} -> {:error, {:temp_write_failed, reason}}
      after
        File.close(io)
      end

    case result do
      {:ok, cid, _size} -> publish(store, tmp_path, cid)
      {:error, _} = error -> cleanup(tmp_path, error)
    end
  end

  defp publish(store, tmp_path, cid) do
    target = path(store, cid)
    :ok = File.mkdir_p(Path.dirname(target))

    cond do
      File.regular?(target) ->
        cleanup(tmp_path, {:ok, cid})

      true ->
        case File.rename(tmp_path, target) do
          :ok -> {:ok, cid}
          {:error, :eexist} -> cleanup(tmp_path, {:ok, cid})
          {:error, reason} -> cleanup(tmp_path, {:error, {:publish_failed, reason}})
        end
    end
  end

  defp cleanup(path, result) do
    _ = File.rm(path)
    result
  end

  defp validate_cid(cid) when is_binary(cid) and byte_size(cid) == 64 do
    if String.match?(cid, ~r/\A[0-9a-f]{64}\z/), do: :ok, else: {:error, :invalid_cid}
  end

  defp validate_cid(_cid), do: {:error, :invalid_cid}

  defp encode_hash(hash), do: Base.encode16(hash, case: :lower)

  defp unique_suffix do
    "#{System.unique_integer([:positive, :monotonic])}.#{:erlang.phash2(self())}"
  end
end
