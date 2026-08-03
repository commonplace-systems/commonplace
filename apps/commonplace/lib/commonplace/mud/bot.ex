defmodule Commonplace.MUD.Bot do
  @moduledoc """
  Bot session management for the MUD MCP bridge (CX-yu2w).

  Bots play the MUD without going through the CLI's `mud connect` path.
  Each bot is identified by a name (the same `.usr` honorific shape as
  human players); a long-lived buffered PlayerSession is spawned on
  first input and reused thereafter, so subscriptions persist between
  MCP tool calls.

  Public API is two functions: `send_input/2` (sends a line, drains and
  returns events) and `read_events/1` (drains pending events without
  sending input — useful for ambient observation between commands).

  ## Registration (CX-vj8v)

  Sessions used to register globally on `{:global, {__MODULE__, name}}`
  — but `:global` name-conflict resolution on node join can kill or
  orphan the singleton (a bare `mix run` temp node joining the cluster
  could kill a live bot), and a netsplit lets two exist at once. That's
  the exact hazard MoveServer and TickBot already retired (see
  `Commonplace.MUD.Move` and `Commonplace.MUD.TickBot`'s moduledocs).
  `Bot` now follows the same house pattern:

    * the `PlayerSession` is registered LOCALLY, via `{:via, Registry,
      {Commonplace.MUD.BotRegistry, name}}` — at most one live session
      per bot name per node, and the registry entry is cleaned up
      automatically when the session dies.
    * cluster-wide exclusivity (what `:global` was buying) is a
      green-token lease, `"__singletons/mud_bot/\#{name}"`, acquired
      from `Commonplace.Green.Bursar` before the session spawns and
      released (by a small monitor process) when the session dies. The
      lease is TTL'd and periodically renewed while the session lives —
      same "renew at TTL/3, failover bounded by TTL" shape as
      `TickBot`'s tick lease — so a dead session's lease is reclaimable
      within one TTL even if the release-on-death path is itself lost
      (e.g. the whole BEAM dies).
    * no Bursar reachable (no local, no remote serve — e.g. a bare
      `mix run` temp node) ⇒ `spawn_session/2` refuses to start the bot
      (`{:error, :bursar_unavailable}`) rather than starting unleased —
      TickBot's fail-closed precedent.
    * the lease already held by another node's holder ⇒
      `{:error, {:bot_active_elsewhere, holder_info}}` — the bot is
      genuinely live elsewhere in the cluster.

  ## Signing identity (CX-5plk)

  MCP MUD sessions have no browser/CLI login, so without this a bot's
  writes carried no `SigningContext` at all — unsigned, and DENIED by
  the trust gate on a strict+enforce node (`PlayerSession`'s
  `opts[:player_identity_uuid]` seam, built by CX-lg06, was simply
  never fed anything here). `spawn_session/2` now resolves a per-bot
  identity keyed by the bot's NAME — the same `.usr` presence handle —
  via `Commonplace.Presence.Identity.register_agent/4` (a `:bot` cold
  identity, extension `.bot`, so it can never collide with the bot's
  own `.usr` presence file that `PlayerSession.find_presence/3` walks
  for) and threads the resulting `player_identity_uuid` into the
  `PlayerSession` start opts, which the CX-lg06 seam already consumes.

  `register_agent/4` and `Commonplace.Crypto.AgentKeys.ensure/2` are
  both idempotent (look up the existing cold identity / keypair before
  minting), so the same bot name always resolves to the same
  identity_uuid and the same keypair — across repeated `send_input`
  calls AND across a session restart (`Bot.stop/1` then a fresh
  `send_input`) — no new key is ever minted for a name that already has
  one, and custody lives in the node-local `SecretStore` (or
  `opts[:secret_store]`, for test isolation).

  Someone has to sign the bot's own registration commits (the identity
  doc + the `__identities__` schema entry) — there is no human operator
  in the loop for an MCP session, so this uses
  `Commonplace.Crypto.NodeIdentity.signing_context/0`, the sanctioned
  headless fallback (D9's "node signs" branch — `Trust` auto-trusts the
  node's own identity, so this works out of the box on a fresh strict
  workspace). Callers that want a specific registrar (tests pinning a
  deterministic root identity) can override with
  `opts[:registrar_signing_context]`. If identity resolution fails for
  any reason, `spawn_session/2` degrades gracefully to the pre-existing
  unsigned behavior — a bot session is still better than none, and this
  keeps permissive-node dogfooding unaffected either way.

  **FLAG — signing alone is not enough to PLAY under strict+enforce.**
  A freshly-signed bot with no capability cert is still denied by the
  trust gate's capability check on docs it doesn't own (see
  `Commonplace.MUD.SignedWrite` / `PlayerSessionIdentityTest`'s "y"
  player for the shape of that denial). Provisioning a bot a starter
  cert (e.g. auto-issuing a section cert over its start room, or
  spawning it into a room it already owns) is a separate follow-on,
  deliberately NOT built here.
  """

  alias Commonplace.Crypto.NodeIdentity
  alias Commonplace.Green.{Bursar, BursarClient}
  alias Commonplace.MUD.{BotRegistry, Bootstrap, Citizenship, PlayerSession, RateLimit, SessionLimit}
  alias Commonplace.Presence.Identity
  alias Commonplace.Store.CommitStoreClient

  @type event :: %{optional(atom) => any}

  @default_settle_ms 50

  # CX-vj8v: cluster-exclusivity lease path prefix, one lease per bot
  # name (mirrors TickBot's "__singletons/tick_bot" naming, namespaced
  # per-name since a bot's identity IS the name, unlike TickBot's
  # single system-wide singleton).
  @lease_prefix "__singletons/mud_bot/"
  @default_lease_ttl_ms 60_000

  @doc """
  Send `line` to bot `name`'s session. Returns
  `{:ok, [event]}` where each event is the structured map output by
  PlayerSession (kind/who/text/etc — see PlayerSession.render_event for
  what's typically rendered).

  Spawns the session lazily on first call.
  """
  @spec send_input(String.t(), String.t(), keyword()) :: {:ok, [event]} | {:error, term()}
  def send_input(name, line, opts \\ []) do
    settle = Keyword.get(opts, :settle_ms, @default_settle_ms)

    with {:ok, session} <- ensure_session(name, opts) do
      # CX-nf8p: consult the throughput gate BEFORE `input_sync` — a
      # rejected command must never enter the PlayerSession mailbox
      # (reject-before-enqueue). `session` (the pid) is the per-session
      # key; the server-known bot `name` is the principal (never taken
      # from `line`). The drop/disconnect results are reported as clean
      # events, exactly like the clean-disconnect drain — not errors.
      case RateLimit.check(session, name) do
        :ok ->
          :ok = PlayerSession.input_sync(session, line)
          Process.sleep(settle)
          drain(session)

        {:drop, :rate} ->
          {:ok, ["(rate limited — you're sending commands too fast, slow down)"]}

        {:disconnect, :rate} ->
          _ = PlayerSession.stop(session)
          {:ok, ["(disconnected — command rate limit exceeded)"]}
      end
    end
  end

  # CX-gq7a: `input_sync` can legitimately terminate the session before
  # this drain call lands — e.g. `quit`, which replies `:ok` from
  # `handle_call` and then `{:stop, :normal, ...}`s. `GenServer.call`
  # against the now-dead pid raises `:noproc`, which used to propagate
  # straight up as an uncaught exit (surfacing at the MCP layer as a
  # crash mis-blamed on CommitStore overload — CX-0nkq). That's plain
  # session teardown, not a failure — reported as a clean-disconnect
  # event rather than an error.
  defp drain(session) do
    {:ok, PlayerSession.drain_buffer(session)}
  catch
    :exit, {:noproc, _} -> {:ok, ["(session ended — clean disconnect)"]}
    :exit, :noproc -> {:ok, ["(session ended — clean disconnect)"]}
  end

  @doc """
  Drain pending events for bot `name` without sending input. Spawns the
  session on first call (so the bot starts subscribing).
  """
  @spec read_events(String.t(), keyword()) :: {:ok, [event]} | {:error, term()}
  def read_events(name, opts \\ []) do
    with {:ok, session} <- ensure_session(name, opts) do
      {:ok, PlayerSession.drain_buffer(session)}
    end
  end

  @doc """
  Stop a bot's session. Useful for tests; in production the session
  lives until the OTP supervisor shuts it down.
  """
  def stop(name) do
    case lookup(name) do
      {:ok, pid} -> PlayerSession.stop(pid)
      :error -> :ok
    end
  end

  ## Internals

  defp ensure_session(name, opts) do
    case lookup(name) do
      {:ok, pid} ->
        {:ok, pid}

      :error ->
        spawn_session(name, opts)
    end
  end

  defp lookup(name) do
    case Registry.lookup(BotRegistry, name) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  end

  defp spawn_session(name, opts) do
    store = Keyword.get(opts, :store, CommitStoreClient)
    root_uuid = Keyword.get_lazy(opts, :root_uuid, fn -> resolve_root(store) end)

    case root_uuid do
      nil ->
        {:error, :no_workspace_root}

      root ->
        # CX-vj8v: cluster exclusivity FIRST, before any store writes —
        # a bot already live elsewhere in the cluster, or no Bursar
        # reachable at all, should fail fast without touching the store
        # (Bootstrap.seed / identity resolution below are each a commit).
        with {:ok, lease} <- acquire_lease(name, opts) do
          # Idempotently ensure the demo world exists before any session
          # spawns — otherwise PlayerSession's stub fallback wins and
          # the bot lands in a featureless start room.
          Bootstrap.seed(root, store)

          identity_opts = resolve_signing_opts(name, root, store, opts)

          # CX-z0v7 (condition 2): the identity resolved just above (when
          # available) is the stable per-bot principal for the UNIFIED
          # web+bot session cap; a bot whose identity resolution degraded
          # to `[]` (see `resolve_signing_opts/4`'s moduledoc note) falls
          # back to keying the cap on the bot's own `name` — still stable
          # per bot, acceptable for v1 (a name and its identity_uuid never
          # both admit sessions for the "same" bot, since name-keying only
          # happens when no identity_uuid was ever resolved).
          principal = Keyword.get(identity_opts, :player_identity_uuid, name)

          case SessionLimit.admit(principal) do
            {:ok, limit_ref} ->
              # CX-vj8v: local registration replaces the retired
              # `{:global, {__MODULE__, name}}` — see moduledoc.
              via_name = {:via, Registry, {BotRegistry, name}}

              result =
                GenServer.start(
                  PlayerSession,
                  [
                    player_name: name,
                    root_uuid: root,
                    store: store,
                    buffered: true
                  ] ++ identity_opts,
                  name: via_name
                )

              case result do
                {:ok, pid} ->
                  SessionLimit.attach(limit_ref, pid)
                  # CX-nf8p: reap this session's rate-limit bucket + drop-counter
                  # when the PlayerSession dies — same monitor-per-session locus
                  # as the SessionLimit slot. Only on a fresh spawn; the
                  # already-started branch reuses a session already watched.
                  RateLimit.watch(pid)
                  # CX-vj8v: release the lease when this session dies —
                  # the local Registry entry is auto-cleaned by Registry
                  # itself, but the cluster-wide Bursar lease needs an
                  # explicit release (or it rides out its TTL).
                  watch_lease(pid, lease)
                  {:ok, pid}

                {:error, {:already_started, pid}} ->
                  # Someone else won the local registration race — same
                  # holder (deterministic per name+node — see
                  # `lease_holder/1`), so the lease is legitimately held
                  # for the WINNING session, not this attempt. Don't
                  # release it out from under the winner; just watch the
                  # winner's pid instead (harmless if more than one
                  # racer ends up watching the same live pid).
                  SessionLimit.release(limit_ref)
                  watch_lease(pid, lease)
                  {:ok, pid}

                err ->
                  SessionLimit.release(limit_ref)
                  release_lease(lease)
                  err
              end

            {:error, _} = err ->
              release_lease(lease)
              err
          end
        end
    end
  end

  # --- CX-vj8v: cluster-exclusivity lease ---

  defp acquire_lease(name, opts) do
    bursar = Keyword.get(opts, :bursar, Bursar)
    path = lease_path(name)
    holder = lease_holder(name)
    ttl_ms = lease_ttl_ms(opts)

    case BursarClient.acquire(bursar, path, nil, ttl: ttl_ms, authenticated_as: holder) do
      {:ok, _token} ->
        {:ok, %{bursar: bursar, path: path, holder: holder, ttl_ms: ttl_ms}}

      {:denied, holder_info} ->
        {:error, {:bot_active_elsewhere, holder_info}}

      # :bursar_unavailable — no lock authority reachable (the
      # bare-mix-run temp-node case). Fail-closed: never spawn a bot
      # session that can't be leased (TickBot precedent).
      {:error, _} = err ->
        err
    end
  end

  defp release_lease(lease) do
    _ = BursarClient.release(lease.bursar, lease.path, nil, authenticated_as: lease.holder)
    :ok
  end

  # Spawns an unlinked watcher that renews the lease (at TTL/3, same
  # cadence as TickBot's tick lease) while `pid` lives, and releases it
  # as soon as `pid` dies. If this watcher itself is lost (e.g. the
  # whole BEAM crashes), the lease is still bounded by its TTL — same
  # failover-bounded-by-TTL property TickBot's moduledoc documents.
  defp watch_lease(pid, lease) do
    spawn(fn ->
      ref = Process.monitor(pid)
      renew_interval_ms = max(div(lease.ttl_ms, 3), 1_000)
      lease_renew_loop(ref, lease, renew_interval_ms)
    end)

    :ok
  end

  defp lease_renew_loop(ref, lease, renew_interval_ms) do
    receive do
      {:DOWN, ^ref, :process, _pid, _reason} ->
        release_lease(lease)
    after
      renew_interval_ms ->
        _ = BursarClient.renew(lease.bursar, lease.path, nil, authenticated_as: lease.holder)
        lease_renew_loop(ref, lease, renew_interval_ms)
    end
  end

  defp lease_path(name), do: @lease_prefix <> name

  # Mirrors TickBot's `default_holder/0` (CX-tdkq.32: a NAMED principal
  # prefixed with the node identity, never a free string) — namespaced
  # per bot name here since Bot's lease is one-per-bot, not one system-
  # wide singleton.
  defp lease_holder(name) do
    case NodeIdentity.identity() do
      {:ok, node_identity} -> "#{node_identity}/mud_bot:#{name}@#{node()}"
      {:error, _} -> "mud_bot:#{name}@#{node()}"
    end
  end

  defp lease_ttl_ms(opts) do
    Keyword.get(opts, :lease_ttl_ms) ||
      Application.get_env(:commonplace, :mud_bot_lease_ttl_ms, @default_lease_ttl_ms)
  end

  # CX-5plk: resolve (idempotently register, if needed) a per-bot
  # signing identity and return the `PlayerSession` start opts that
  # thread it through the CX-lg06 seam. `[]` (unsigned, legacy
  # behavior) on any resolution failure — a bot that can't be signed
  # is still better than no bot at all.
  #
  # CX-0a9a (presence-carve, W7): once the identity is resolved, also
  # auto-issue it a presence-starter capability cert — `{:presence,
  # identity_uuid}`, `[:write]` — the "starter cert" that lets a signed
  # bot move/act under strict+enforce before it owns any section of its
  # own (see `Commonplace.MUD.SignedWrite`'s W5 opportunistic-attach and
  # `Commonplace.Trust`'s W3 content-gate). Threaded into the session
  # start opts as `cert_cids: [cid]`. Degrades gracefully (no cert →
  # `[]`, matching the existing register_agent failure path) — never
  # blocks a bot from spawning.
  defp resolve_signing_opts(name, root, store, opts) do
    secret_store = Keyword.get(opts, :secret_store, Commonplace.Store.SecretStore)
    registrar_opts = [secret_store: secret_store] ++ registrar_signing_opts(opts)

    case Identity.register_agent(name, root, store, registrar_opts) do
      {:ok, identity_uuid, pub} ->
        # CX-gjpi — in a GRAFTED mud world (the :5199 curated world under
        # "mud", where `root` is a subtree ≠ the workspace root), a bot
        # becomes a FULL CITIZEN via the SAME `Citizenship.ensure/5` seam the
        # web login uses: presence-starter cert + a node-signed home ROOM it
        # OWNS + spawn-in-home. "One citizenship mechanism, two callers" — so
        # a bot is a full citizen (own identity, own home, own permissions)
        # co-present with human players. A NON-grafted world (dogfood, tests:
        # root == workspace root) keeps the simpler starter-cert + shared-
        # start-spawn behavior — unchanged.
        if full_citizenship?() do
          full_citizen_opts(identity_uuid, pub, name, root, store, secret_store)
        else
          starter_cert_opts(identity_uuid, pub, name, store, secret_store)
        end

      {:error, _reason} ->
        []
    end
  end

  defp full_citizen_opts(identity_uuid, pub, name, root, store, secret_store) do
    case Commonplace.MUD.Citizenship.ensure(identity_uuid, pub, name, root, store) do
      {:ok, %{cert_cids: cids, home_room_uuid: home_room_uuid}} ->
        [
          player_identity_uuid: identity_uuid,
          secret_store: secret_store,
          cert_cids: Enum.uniq(cids ++ provisioned_certs(name)),
          spawn_room_uuid: home_room_uuid
        ]

      # Home-provision failed — fall back to starter-cert-only (bot still
      # spawns, at the shared start room). Never blocks a bot from spawning.
      _ ->
        starter_cert_opts(identity_uuid, pub, name, store, secret_store)
    end
  end

  defp starter_cert_opts(identity_uuid, pub, name, store, secret_store) do
    starter = issue_presence_starter_cert(identity_uuid, pub, store)
    cert_cids = Enum.uniq(starter ++ provisioned_certs(name))
    [player_identity_uuid: identity_uuid, secret_store: secret_store, cert_cids: cert_cids]
  end

  # CX-gjpi — the full-citizen bot model (own home + spawn-in-home, co-present
  # with human players) is OPT-IN per node via app env, exactly like
  # `:mud_provisioned_certs` / `:local_write_gate`. The :5199 multiplayer
  # serve sets it true; dogfood + tests leave it false (default) → bots keep
  # the simpler starter-cert + shared-start-spawn behavior, fully unchanged.
  defp full_citizenship? do
    Application.get_env(:commonplace, :mud_full_citizenship, false)
  end

  # CX-0a9a (zone-ownership M1): certs granted to a bot OUT OF BAND — e.g.
  # a zone-owner's section cert issued by admin at provisioning time —
  # can't be log-discovered before they've authored a commit (the same
  # blind spot `issue_presence_starter_cert/3` sidesteps by issuing the
  # starter cert here at spawn). For M1's known bots those provisioned
  # cert CIDs are threaded explicitly via app env, keyed by bot name — a
  # deliberate stand-in for a by-audience capability index / the M2
  # dynamic-join self-provisioning path. Empty (default) for every bot
  # that was never provisioned anything, so this is inert unless set.
  defp provisioned_certs(name) do
    Application.get_env(:commonplace, :mud_provisioned_certs, %{})
    |> Map.get(name, [])
  end

  # CX-gjpi: this logic now lives in `Commonplace.MUD.Citizenship` (the
  # shared home for "issue a presence-starter cert", reused by both a
  # bot spawn here and a browser player's `MudLive` mount) — delegates
  # straight through, same signature, same graceful-degradation-to-`[]`
  # semantics.
  defp issue_presence_starter_cert(identity_uuid, pub, store) do
    Citizenship.issue_presence_starter_cert(identity_uuid, pub, store)
  end

  # The principal that signs the bot's own registration commits (D9).
  # Tests may pin a deterministic root/operator identity via
  # `opts[:registrar_signing_context]`; production headless spawns fall
  # back to the node's own signing identity (the sanctioned D9
  # headless branch — `Trust` auto-trusts it). Neither available —
  # unsigned registration commits (matches the pre-CX-5plk behavior).
  defp registrar_signing_opts(opts) do
    case Keyword.get(opts, :registrar_signing_context) do
      nil ->
        case NodeIdentity.signing_context() do
          {:ok, ctx} -> [signing_context: ctx]
          {:error, _} -> []
        end

      ctx ->
        [signing_context: ctx]
    end
  end

  defp resolve_root(store) do
    case Commonplace.Workspace.root_uuid() do
      {:ok, root} -> if full_citizenship?(), do: mud_world_root(root, store), else: root
      _ -> nil
    end
  end

  # CX-gjpi — if the workspace has a "mud" subtree (the migrated curated
  # world grafted under the :5199 root), bots spawn INTO it, co-present with
  # web players whose `MudLive` is rooted there too. A workspace with no
  # "mud" entry (e.g. a standalone dogfood world that IS the MUD) roots at
  # its own root, unchanged. Callers can still override with `:root_uuid`.
  defp mud_world_root(workspace_root, store) do
    loader = fn uuid ->
      case Commonplace.Tree.DocBuilder.reconstruct_doc(store, uuid) do
        {:ok, doc} -> doc
        _ -> Yelixer.Doc.new()
      end
    end

    case Commonplace.Tree.Walk.resolve_path(workspace_root, "mud", loader) do
      {:ok, mud_root} -> mud_root
      _ -> workspace_root
    end
  end
end
