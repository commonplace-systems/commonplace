defmodule Commonplace.Store.LockRefusal do
  @moduledoc """
  The one place the "this commits store is held by a live process"
  refusal prose lives.

  Two layers refuse on the same condition and must say the same thing:

    * `Commonplace.Store.CommitStore.init/1` (CX-2479) — the store layer,
      after a `flock(2)` on `<data_dir>/commits.lock` comes back
      `:would_block`. That refusal is the LAST line of defence and it
      arrives as a GenServer stop, which reads to a user as a crash.
    * `Commonplace.CLI.Access` (CX-x8jk) — the tool layer, which probes
      the same lock BEFORE opening anything and refuses in the user's
      own terms.

  CX-2479's rider is the reason this module exists as prose rather than
  as a bare "no": the incident's trigger was a legitimate read need
  going through an illegitimate door. A refusal that only says "no"
  breeds the workaround, so every refusal names the sanctioned door.
  Duplicating the sentence in two apps is how the two copies drift.

  Nothing here is an authorization decision. `holder_hint/1` reads the
  CONTENT of the lock file, which is diagnostic only — the kernel, not
  the file's bytes, decides who holds the lock.
  """

  @doc """
  Names the sanctioned ways to read a store some other live process
  holds. Used verbatim in both refusals.
  """
  def sanctioned_access_message do
    "This store is held by a live process. Read it through the running serve " <>
      "(:erpc into the serve node, or Commonplace.Store.CommitStoreClient against it), " <>
      "or from a CubDB.back_up/2 copy. Do NOT retry the direct open and do NOT delete " <>
      "the lock file — a second opener on one CubDB directory is how the store gets corrupted."
  end

  @doc """
  Read the diagnostic hint out of a lock file. NOT proof of anything:
  a live holder may have written nothing, and a stale string grants
  nobody anything.
  """
  def holder_hint(lock_path) do
    case File.read(lock_path) do
      {:ok, content} -> normalize_hint(String.trim(content))
      {:error, _} -> normalize_hint("")
    end
  end

  defp normalize_hint(""), do: "(lock file empty or unreadable)"
  defp normalize_hint(content), do: content

  @doc """
  The tool-layer refusal (CX-x8jk): printed by the CLI when it finds the
  target data dir's commits store locked and cannot reach a serve to
  route through. Ends with the operator's actual next move, because the
  common case is a running serve the CLI could not connect to.
  """
  def cli_refusal(data_dir, lock_path, reach_failure \\ nil) do
    """
    commonplace: refusing to open the commits store at #{Path.join(data_dir, "commits")}.

      It is LOCKED by another live process (flock on #{lock_path}), and no
      running `commonplace serve` for this workspace could be reached, so
      there is nothing to route this command through.

      Holder hint (NOT proof — diagnostic content of the lock file): #{holder_hint(lock_path)}

      #{sanctioned_access_message()}

      Reach diagnostic: #{reach_failure_message(reach_failure, data_dir)}

      If a serve IS running for this workspace, use that diagnostic to check
      the named step; distribution failures commonly involve epmd and ERL_INETRC/
      ERL_EPMD_ADDRESS (see bin/commonplace-mcp for the loopback setup).

    Nothing was opened and nothing on disk was touched. (CX-a3fe)
    """
  end

  defp reach_failure_message({:read_node_name, nil}, data_dir) do
    "read_node_name(#{inspect(data_dir)}) returned nil"
  end

  defp reach_failure_message({:node_start, result}, _data_dir) do
    "Node.start(cli_name, :shortnames) returned #{inspect(result)}"
  end

  defp reach_failure_message({:node_connect, result}, _data_dir) do
    "Node.connect(serve_node) returned #{inspect(result)}"
  end

  defp reach_failure_message({:verify_serves_this_dir, result}, _data_dir) do
    "verify_serves_this_dir(serve_node, data_dir) returned #{inspect(result)}"
  end

  defp reach_failure_message(nil, _data_dir), do: "reach step unavailable"
end
