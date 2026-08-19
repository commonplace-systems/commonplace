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

  ## Coverage: wide vs narrow (CX-vknn)

  The original mechanism above (`compare/1` via `remote_digest/1`)
  only ever looked at `@probe_modules` — a fixed set of 6 modules.
  Anything that changed outside that set was invisible, while the
  warning text ("N of 6 probed modules differ") read as if 6 were the
  whole universe rather than a hand-picked sample. That narrowness was
  not an oversight: widening it the obvious way — enumerate every
  module and call `Mod.module_info(:md5)` on each — was rejected,
  because `module_info/1` is a function *of* the module it describes,
  and calling it FORCE-LOADS the module if the module isn't already
  resident. Doing that for hundreds of modules against a LIVE serve
  (which loads code lazily, on first call, straight out of `_build`)
  would be a real side effect on production, not just a slow check.

  `bin/cp-verify-deploy` solved this for the deploy-time version of
  the same problem with two primitives that read state without
  changing it:

    * `:code.is_loaded/1` — a code-server *query*. Returns
      `{:file, path}` or `false` without loading anything.
    * `:erlang.get_module_info(mod, :md5)` — a BIF that reads the
      code server's ALREADY-RESIDENT module record directly. Unlike
      `Mod.module_info/1`, it does not dispatch through the module
      itself, so it structurally cannot trigger an auto-load.

  `resident_digest/1` and `compare_wide/1` below apply those same two
  primitives to get whole-umbrella-app coverage on the REMOTE
  (serve) side, at module granularity, without loading anything the
  serve hadn't already loaded on its own. The LOCAL (escript) side is
  the opposite: it deliberately keeps force-loading (via
  `mod.module_info(:md5)`), because forcing the escript's own bundled
  code to load is free (it's a local, static binary, not a live
  server) and is exactly the code we want the digest OF — the code
  that would run if that module were called.

  Coverage on the wide path is at APP granularity, not module
  granularity: for each of `@apps`, every module the app's `.app`
  file lists gets swept, but if the SET of apps itself misses one
  (e.g. a new umbrella app added and never added here), that's a gap.
  App-granularity is acceptable where module-granularity was not
  because the app list changes rarely (compare: which of ~500 modules
  changed this week), and because the report NAMES the apps compared
  — a missing app is visible in the printed list, not silently
  absorbed the way "N of 6" invited.

  If the serve is running an older `commonplace` build that predates
  `resident_digest/1` entirely, `compare_wide/1` gets back
  `{:badrpc, {'EXIT', {:undef, _}}}` (or similar) from the RPC and
  reports `{:error, :no_wide_digest}`; `compare/1` falls back to the
  original narrow 6-module path in that case, unchanged, so the
  handshake still says SOMETHING against a server that can't speak
  the wide protocol.
  """

  @probe_modules [
    Commonplace.Store.CommitStoreClient,
    Commonplace.Document.ContentType,
    Commonplace.Tree.DocBuilder,
    Commonplace.MUD.Verbs,
    Commonplace.MUD.World,
    Commonplace.Code.SourceDoc
  ]

  # The umbrella's apps, verified against `apps/` at the time this was
  # written (2026-08-05): commonplace, commonplace_bots, commonplace_cli,
  # commonplace_mcp, commonplace_web, yelixer — six apps, matching this
  # list exactly (order differs, set does not). See the moduledoc for
  # why app-granularity (rather than a fixed module list) is the right
  # tradeoff here.
  @apps [
    :commonplace,
    :commonplace_bots,
    :commonplace_web,
    :commonplace_mcp,
    :commonplace_cli,
    :yelixer
  ]

  @rpc_timeout 5_000

  @doc "The fixed set of modules probed for skew (the narrow/fallback path)."
  @spec probe_modules() :: [module]
  def probe_modules(), do: @probe_modules

  @doc "The umbrella apps swept by the wide path (`compare_wide/1`)."
  @spec apps() :: [atom]
  def apps(), do: @apps

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
  Digest of every module of every app in `apps`, as loaded on THIS
  node — meant to be invoked ON the node being probed, via
  `:rpc.call(node, __MODULE__, :resident_digest, [apps], timeout)`.

  Deliberately an MFA target (not called via an anonymous function):
  funs do not transport reliably across an `:rpc.call/5` boundary
  between nodes running different code versions, which is exactly the
  skewed-code situation this module exists to detect.

  For each app: `:application.get_key(app, :modules)`. `:undefined`
  means the app isn't loaded on this node at all — that app's name is
  added to `missing_apps` and the sweep continues (this is expected,
  not an error — e.g. `commonplace_cli` legitimately never loads in a
  Phoenix serve).

  For each module found: `:code.is_loaded/1` — a code-server *query*,
  not a call into the module, so it reports load state without
  changing it. Loaded modules get their md5 via
  `:erlang.get_module_info(mod, :md5)`, a BIF that reads the code
  server's already-resident module record directly rather than
  dispatching through the module — it structurally cannot force a
  load. Not-loaded modules are only counted (`not_loaded_count`); they
  are never touched further, so this function never loads a module
  that wasn't already loaded when it was called.

  🔴 This function must NEVER call `module_info/1`,
  `Code.ensure_loaded?/1`, or `apply/3` on a probed module — any of
  those would force-load it. The md5 fetch is wrapped in
  try/rescue/catch: if some pathological module blows up on
  `:erlang.get_module_info/2`, that one entry is dropped from `loaded`
  (not counted at all) rather than crashing the whole digest.
  """
  @spec resident_digest([atom]) :: %{
          apps: [atom],
          loaded: %{module => binary},
          not_loaded_count: non_neg_integer,
          missing_apps: [atom]
        }
  def resident_digest(apps) when is_list(apps) do
    init = %{loaded: %{}, not_loaded_count: 0, missing_apps: []}

    result =
      Enum.reduce(apps, init, fn app, acc ->
        case :application.get_key(app, :modules) do
          {:ok, mods} ->
            Enum.reduce(mods, acc, fn mod, acc2 ->
              case :code.is_loaded(mod) do
                {:file, _path} ->
                  case resident_md5(mod) do
                    {:ok, md5} -> put_in(acc2, [:loaded, mod], md5)
                    :error -> acc2
                  end

                false ->
                  Map.update!(acc2, :not_loaded_count, &(&1 + 1))
              end
            end)

          :undefined ->
            Map.update!(acc, :missing_apps, &[app | &1])
        end
      end)

    %{
      apps: apps,
      loaded: result.loaded,
      not_loaded_count: result.not_loaded_count,
      missing_apps: Enum.reverse(result.missing_apps)
    }
  end

  defp resident_md5(mod) do
    try do
      case :erlang.get_module_info(mod, :md5) do
        md5 when is_binary(md5) -> {:ok, md5}
        _other -> :error
      end
    rescue
      _ -> :error
    catch
      _kind, _reason -> :error
    end
  end

  @doc """
  Compares this node's probe-module digest against `node`'s.

  See `compare_digests/2` for the comparison semantics.
  """
  @spec compare(node) ::
          :ok
          | {:skew, [%{module: module, local: term, remote: term}]}
          | {:wide_ok, map}
          | {:wide_skew, map}
          | {:error, term}
  def compare(node) do
    case compare_wide(node) do
      {:ok, %{skew: []} = report} ->
        {:wide_ok, report}

      {:ok, report} ->
        {:wide_skew, report}

      {:error, :no_wide_digest} ->
        case remote_digest(node) do
          {:ok, remote} -> compare_digests(local_digest(), remote)
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Wide comparison: fetches `resident_digest/1` from `node` for
  `apps/0` in ONE rpc round-trip, then compares each remote-loaded
  module's md5 against the LOCAL (escript-side) md5 of the same
  module.

  On the local side, force-loading via `mod.module_info(:md5)` is
  fine and intended — see the moduledoc's "Coverage: wide vs narrow"
  section for why the two sides are allowed to behave differently
  here.

  A module the serve has loaded but that the local escript can't load
  at all (`:unavailable`) is counted in `not_in_escript` but is NOT
  emitted as a per-module skew line — it's usually just an app the
  escript doesn't bundle (e.g. `commonplace_web`), not drift.

  Returns `{:error, :no_wide_digest}` — never raises — when the
  remote node doesn't have `resident_digest/1` at all (older serve
  build predating this feature), so callers can fall back to the
  narrow path.
  """
  @spec compare_wide(node) ::
          {:ok,
           %{
             compared: non_neg_integer,
             skew: [%{module: module, local: term, remote: term}],
             serve_not_loaded: non_neg_integer,
             missing_apps: [atom],
             apps: [atom],
             not_in_escript: non_neg_integer
           }}
          | {:error, term}
  def compare_wide(node) do
    case :rpc.call(node, __MODULE__, :resident_digest, [@apps], @rpc_timeout) do
      {:badrpc, _reason} ->
        {:error, :no_wide_digest}

      %{
        loaded: remote_loaded,
        not_loaded_count: serve_not_loaded,
        missing_apps: missing_apps,
        apps: apps
      } ->
        {skew, not_in_escript} =
          Enum.reduce(remote_loaded, {[], 0}, fn {mod, remote_md5}, {skew_acc, missing_acc} ->
            case local_md5_for(mod) do
              :unavailable ->
                {skew_acc, missing_acc + 1}

              local_md5 when local_md5 == remote_md5 ->
                {skew_acc, missing_acc}

              local_md5 ->
                {[%{module: mod, local: local_md5, remote: remote_md5} | skew_acc], missing_acc}
            end
          end)

        {:ok,
         %{
           compared: map_size(remote_loaded) - not_in_escript,
           skew: Enum.reverse(skew),
           serve_not_loaded: serve_not_loaded,
           missing_apps: missing_apps,
           apps: apps,
           not_in_escript: not_in_escript
         }}

      other ->
        {:error, {:unexpected_resident_digest_result, other}}
    end
  end

  defp local_md5_for(mod) do
    try do
      mod.module_info(:md5)
    rescue
      _ -> :unavailable
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

  This is the NARROW-path formatter: it fires only when `compare/1`
  fell back to the fixed 6-module sample (the serve doesn't yet have
  `resident_digest/1`). The wording says so plainly — 6 sentinel
  modules is a SAMPLE, not full coverage, and a change outside them
  would not be seen by this check at all.
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
        #{n} of #{total} SAMPLED modules differ (narrow fallback: the serve does not
        support the wide check, so only a fixed sample of #{total} sentinel modules was
        probed — a change outside that sample would NOT be seen by this check). The
        escript is a PRECOMPILED BINARY and does not pick up code changes until it is
        rebuilt.

    #{Enum.join(lines, "\n")}

        Fix: run  bin/rebuild-mcp  and start a new session.
        Continuing anyway — behaviour may not match the deployed code.
    """
  end

  @doc """
  One concise line stating what a CLEAN wide check actually covered.

  Exists because silence is the failure mode this bead is about. If a
  passing check prints nothing, the reader infers "everything matches",
  when what actually happened is "the modules the serve had already
  loaded match, and several hundred more were never looked at". Saying
  the scope out loud on success costs one line and removes the
  inference. Skew has its own, louder report — `format_wide_skew/1`.
  """
  @spec format_coverage_line(%{
          :compared => non_neg_integer,
          :serve_not_loaded => non_neg_integer,
          :apps => [atom],
          optional(any) => any
        }) :: String.t()
  def format_coverage_line(%{
        compared: compared,
        serve_not_loaded: serve_not_loaded,
        apps: apps
      }) do
    "version check: no skew across #{compared} module(s) resident on the serve " <>
      "(#{length(apps)} apps); #{serve_not_loaded} not loaded there and NOT checked."
  end

  @doc """
  Formats a `compare_wide/1` `:ok` payload into a multi-line,
  operator-facing report — the wide-path counterpart to `format_skew/1`.

  Unlike the narrow formatter, this ALWAYS states actual coverage
  (modules checked, modules resident-but-not-loaded-and-so-not-
  checked, apps compared) regardless of whether skew was found — a
  clean bill of health here means "N modules checked, 0 differed",
  never a bare "no skew" that could be misread as "nothing could have
  changed".
  """
  @spec format_wide_skew(%{
          compared: non_neg_integer,
          skew: [%{module: module, local: term, remote: term}],
          serve_not_loaded: non_neg_integer,
          missing_apps: [atom],
          apps: [atom],
          not_in_escript: non_neg_integer
        }) :: String.t()
  def format_wide_skew(report) do
    %{
      compared: compared,
      skew: skew_list,
      serve_not_loaded: serve_not_loaded,
      missing_apps: missing_apps,
      apps: apps,
      not_in_escript: not_in_escript
    } = report

    n = length(skew_list)
    app_names = Enum.map_join(apps, ", ", &to_string/1)

    coverage_lines =
      [
        "    Checked #{compared} modules resident on the serve across #{length(apps)} app(s): #{app_names}.",
        "    #{serve_not_loaded} further modules are NOT LOADED on the serve and were NOT checked — they will load",
        "    from _build when first called, so this is not a clean bill of health for them."
      ] ++
        if not_in_escript > 0 do
          [
            "    #{not_in_escript} resident module(s) have no local (escript-bundled) counterpart and were" <>
              " skipped, not reported as skew."
          ]
        else
          []
        end ++
        if missing_apps != [] do
          [
            "    #{length(missing_apps)} app(s) not loaded on the serve at all: #{Enum.map_join(missing_apps, ", ", &to_string/1)}."
          ]
        else
          []
        end

    coverage = Enum.join(coverage_lines, "\n")

    if n == 0 do
      """
      ✅ No version skew found (WIDE check).
      #{coverage}
      """
    else
      lines =
        Enum.map(skew_list, fn %{module: mod, local: local, remote: remote} ->
          "      #{inspect(mod)}#{String.duplicate(" ", max(1, 30 - String.length(inspect(mod))))}escript=#{short(local)} serve=#{short(remote)}"
        end)

      """
      ⚠️  VERSION SKEW between this MCP escript and the serve node (WIDE check).
      #{coverage}
          #{n} module(s) differ. The escript is a PRECOMPILED BINARY and does not pick
          up code changes until it is rebuilt.

      #{Enum.join(lines, "\n")}

          Fix: run  bin/rebuild-mcp  and start a new session.
          Continuing anyway — behaviour may not match the deployed code.
      """
    end
  end

  defp short(:unavailable), do: "unavailable"

  defp short(md5) when is_binary(md5) do
    md5 |> Base.encode16(case: :lower) |> String.slice(0, 12) |> Kernel.<>("…")
  end

  defp short(other), do: inspect(other)
end
