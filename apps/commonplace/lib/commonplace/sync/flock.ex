defmodule Commonplace.Sync.Flock do
  @moduledoc """
  OS-level advisory file locks via flock(2) NIF.

  Provides shared and exclusive locks for coordinating file access
  between BEAM processes and external unix processes (sandboxes).
  """

  require Logger

  @on_load :load_nif
  @default_timeout 30_000
  @retry_interval 100

  def load_nif do
    path = :filename.join(:code.priv_dir(:commonplace), ~c"flock_nif")
    :erlang.load_nif(path, 0)
  end

  # NIF stubs — replaced at load time. Must be `def` (not `defp`) for NIF replacement.
  def nif_open(_path, _mode), do: :erlang.nif_error(:not_loaded)
  def nif_flock(_ref, _op), do: :erlang.nif_error(:not_loaded)
  def nif_close(_ref), do: :erlang.nif_error(:not_loaded)

  @doc """
  Acquire an exclusive lock on `path`, run `fun`, release the lock.
  Returns the result of `fun`. On timeout or error, runs `fun` without lock.
  """
  def with_exclusive_lock(path, timeout \\ @default_timeout, fun) do
    with_lock(path, :exclusive, timeout, fun)
  end

  @doc """
  Acquire a shared lock on `path`, run `fun`, release the lock.
  Returns the result of `fun`. On timeout or error, runs `fun` without lock.
  """
  def with_shared_lock(path, timeout \\ @default_timeout, fun) do
    with_lock(path, :shared, timeout, fun)
  end

  @doc """
  Try to acquire a lock. Returns {:ok, ref} or {:error, reason}.
  Caller must call unlock/1 when done.
  """
  def try_lock(path, type) when type in [:exclusive, :shared] do
    mode = if type == :exclusive, do: :write, else: :read

    case nif_open(String.to_charlist(path), mode) do
      {:ok, ref} ->
        case nif_flock(ref, type) do
          :ok -> {:ok, ref}

          {:error, _} = err ->
            nif_close(ref)
            err
        end

      {:error, _} = err ->
        err
    end
  end

  @doc "Release a lock acquired via try_lock/2."
  def unlock(ref) do
    nif_close(ref)
  end

  # -- Private --

  defp with_lock(path, type, timeout, fun) do
    case acquire_with_retry(path, type, timeout) do
      {:ok, ref} ->
        try do
          fun.()
        after
          nif_close(ref)
        end

      {:error, :timeout} ->
        Logger.warning("flock timeout on #{path}, proceeding without lock")
        fun.()

      {:error, reason} ->
        Logger.warning("flock failed on #{path}: #{inspect(reason)}, proceeding without lock")
        fun.()
    end
  end

  defp acquire_with_retry(path, type, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    mode = if type == :exclusive, do: :write, else: :read
    do_retry(path, mode, type, deadline)
  end

  defp do_retry(path, mode, type, deadline) do
    now = System.monotonic_time(:millisecond)

    if now >= deadline do
      {:error, :timeout}
    else
      case nif_open(String.to_charlist(path), mode) do
        {:ok, ref} ->
          case nif_flock(ref, type) do
            :ok ->
              {:ok, ref}

            {:error, :eintr} ->
              nif_close(ref)
              do_retry(path, mode, type, deadline)

            {:error, :would_block} ->
              nif_close(ref)
              Process.sleep(@retry_interval)
              do_retry(path, mode, type, deadline)

            {:error, _} = err ->
              nif_close(ref)
              err
          end

        {:error, :enoent} ->
          {:error, :enoent}

        {:error, _} = err ->
          err
      end
    end
  end
end
