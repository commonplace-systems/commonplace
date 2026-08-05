defmodule Commonplace.VersionHandshake do
  @moduledoc """
  Detects code skew between the MCP escript and the serve node it attaches
  to.

  The MCP escript (`apps/commonplace_mcp/commonplace_mcp`) is a
  PRECOMPILED BINARY. It bundles its own copies of `commonplace` app
  modules, frozen at whatever commit it was last built from
  (`bin/rebuild-mcp`). When the serve is redeployed but the escript is
  not rebuilt, the escript runs stale code against a fresh serve — with
  no automatic hook, no warning, and no visible symptom other than
  behaviour that doesn't match what's actually deployed. This has burned
  real debugging hours: multiple observed "bugs" turned out to just be
  the escript running old code.

  This module detects that skew at connect time by comparing BEAM
  module md5s (`Mod.module_info(:md5)`) between the escript's local copy
  of a handful of probe modules and the serve node's copy of the same
  modules.

  Why md5 comparison instead of a git-sha or build-stamp mechanism?

    * No build step — `module_info(:md5)` is always available on any
      compiled BEAM module, nothing needs to be baked in at compile
      time.
    * No git shelling — this runs from within a running node, possibly
      far from any `.git` directory (and escripts don't carry one).
    * Works at runtime, on both sides, symmetrically — the same
      function call, local and via `:rpc.call/4`.
    * It compares what is ACTUALLY LOADED, not what someone *intended*
      to build. A build-stamp can lie (dirty tree, half-finished
      rebuild); the md5 of the module actually executing cannot.

  This module lives in the `commonplace` app (not `commonplace_mcp`)
  because both the serve and the escript bundle `commonplace` — that
  shared-ness is exactly what makes the comparison possible.
  """

  @probe_modules [
    Commonplace.Store.CommitStoreClient,
    Commonplace.Document.ContentType,
    Commonplace.Tree.DocBuilder,
    Commonplace.MUD.Verbs,
    Commonplace.MUD.World,
    Commonplace.Code.SourceDoc
  ]

  @rpc_timeout 5_000

  @doc "The fixed set of modules probed for skew."
  @spec probe_modules() :: [module]
  def probe_modules(), do: @probe_modules

  @doc """
  Digest of the probe modules as loaded in THIS (local) node.

  Calling `module_info/1` force-loads the module if it isn't already
  loaded. That's intentional and load-bearing: a probe module that
  simply hasn't been touched yet by this process must not be reported
  as "missing" just because it's lazily unloaded — we want the digest
  of the code that WOULD run, not of whatever happens to already be
  resident.
  """
  @spec local_digest() :: %{module => binary | :unavailable}
  def local_digest() do
    for mod <- @probe_modules, into: %{} do
      digest =
        try do
          mod.module_info(:md5)
        rescue
          _ -> :unavailable
        end

      {mod, digest}
    end
  end

  @doc """
  Digest of the probe modules as loaded on `node`, fetched via RPC.

  Each probe is an independent `:rpc.call/5` with a short timeout, so a
  hung or unreachable node degrades individual entries to `:unavailable`
  rather than failing the whole digest. If every single module comes
  back `:unavailable`, that's not a version skew — it's a total failure
  to reach the node — so this returns `{:error, :no_remote_modules}`
  instead of a digest, to keep callers from reporting six spurious
  skews when the real story is "couldn't talk to the node at all".
  """
  @spec remote_digest(node) :: {:ok, %{module => binary | :unavailable}} | {:error, term}
  def remote_digest(node) do
    digest =
      for mod <- @probe_modules, into: %{} do
        value =
          case :rpc.call(node, mod, :module_info, [:md5], @rpc_timeout) do
            {:badrpc, _reason} -> :unavailable
            other -> other
          end

        {mod, value}
      end

    if Enum.all?(digest, fn {_mod, v} -> v == :unavailable end) do
      {:error, :no_remote_modules}
    else
      {:ok, digest}
    end
  end

  @doc """
  Compares this node's probe-module digest against `node`'s.

  See `compare_digests/2` for the comparison semantics.
  """
  @spec compare(node) ::
          :ok | {:skew, [%{module: module, local: term, remote: term}]} | {:error, term}
  def compare(node) do
    case remote_digest(node) do
      {:ok, remote} -> compare_digests(local_digest(), remote)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Pure comparison of two digests (as produced by `local_digest/0` /
  `remote_digest/1`'s `:ok` payload).

  A module `:unavailable` on BOTH sides is not a skew — there's nothing
  to compare, and reporting it would just be noise. A module available
  on one side but not the other IS a skew (that's exactly the kind of
  drift this exists to catch — e.g. a module that was renamed/removed
  on one side).
  """
  @spec compare_digests(%{module => binary | :unavailable}, %{module => binary | :unavailable}) ::
          :ok | {:skew, [%{module: module, local: term, remote: term}]}
  def compare_digests(local, remote) do
    skew =
      for mod <- @probe_modules,
          local_v = Map.get(local, mod, :unavailable),
          remote_v = Map.get(remote, mod, :unavailable),
          not (local_v == :unavailable and remote_v == :unavailable),
          local_v != remote_v do
        %{module: mod, local: local_v, remote: remote_v}
      end

    case skew do
      [] -> :ok
      list -> {:skew, list}
    end
  end

  @doc """
  Formats a skew list (as returned in `{:skew, list}`) into a
  multi-line, operator-facing warning naming the actual remedy
  (`bin/rebuild-mcp`) — the point is that whoever reads this shouldn't
  have to work out what to do next.
  """
  @spec format_skew([%{module: module, local: term, remote: term}]) :: String.t()
  def format_skew(skew_list) do
    total = length(@probe_modules)
    n = length(skew_list)

    lines =
      Enum.map(skew_list, fn %{module: mod, local: local, remote: remote} ->
        "      #{inspect(mod)}#{String.duplicate(" ", max(1, 30 - String.length(inspect(mod))))}escript=#{short(local)} serve=#{short(remote)}"
      end)

    """
    ⚠️  VERSION SKEW between this MCP escript and the serve node.
        #{n} of #{total} probed modules differ. The escript is a PRECOMPILED BINARY and
        does not pick up code changes until it is rebuilt.

    #{Enum.join(lines, "\n")}

        Fix: run  bin/rebuild-mcp  and start a new session.
        Continuing anyway — behaviour may not match the deployed code.
    """
  end

  defp short(:unavailable), do: "unavailable"

  defp short(md5) when is_binary(md5) do
    md5 |> Base.encode16(case: :lower) |> String.slice(0, 12) |> Kernel.<>("…")
  end

  defp short(other), do: inspect(other)
end
