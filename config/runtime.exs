import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/commonplace_web start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :commonplace_web, CommonplaceWebWeb.Endpoint, server: true
end

# CX-qida: Phoenix-as-serve Mode B — booting the web app directly
# against a real workspace `data_dir` (instead of via `commonplace_cli
# serve`) makes this process the workspace owner just the same, so it
# must take the same single-owner flock. Gate on the same combination
# that identifies Mode B: PHX_SERVER (this boot runs the server) AND
# COMMONPLACE_DATA_DIR (pointed at a real workspace, not the "data"
# default used by `mix test`/`mix phx.server` without a workspace).
#
# CX-gjpi: Mode B is a serve, so it must ALSO start the Green.Bursar —
# the cluster's move-lock authority. `commonplace_cli serve` sets
# `:bursar_on_boot` for exactly this; a Mode-B serve that omitted it
# locked the workspace but left EVERY MUD/tree move failing with
# `{:error, :bursar_unavailable}` (World.move → do_go → "You can't go
# <dir>"). A Mode-B serve is single-owner just like the CLI serve, so it
# is the correct node to own the Bursar.
#
# CX-p6g0: this gate USED to read `System.get_env("PHX_SERVER")` alone,
# and that one env var caused a silent take/move outage on the live
# :5199 serve. `mix phx.server` starts the endpoint but does NOT set
# PHX_SERVER, so a hand-rolled relaunch with COMMONPLACE_DATA_DIR set
# and PHX_SERVER omitted booted with NO Bursar, NO orchestrator and NO
# workspace lock — while still answering HTTP 200. The serve looked
# healthy from outside and every take/move crashed on
# `:bursar_unavailable`. HTTP 200 was the DESCRIPTION; Mode-B-inactive
# was the STATE.
#
# So don't ask the operator to remember a flag that names something the
# system already knows. `Mix.Tasks.Phx.Server.run/1` sets
# `:phoenix, :serve_endpoints` (phx.server.ex:35) BEFORE it calls
# `Mix.Tasks.Run.run/1` (:36) — and that call is what triggers
# app.config, which evaluates THIS file. So the flag is already visible
# here, and `mix phx.server` can no longer drift from `PHX_SERVER=true`.
# Releases keep working: they set PHX_SERVER and never run the Mix task.
serving? =
  System.get_env("PHX_SERVER") || Application.get_env(:phoenix, :serve_endpoints, false)

data_dir = System.get_env("COMMONPLACE_DATA_DIR")

# Belt for the case where the detection above is wrong: a workspace was
# named but Mode B did not activate, which is precisely the silent state
# that caused the outage. Say so loudly rather than serving a hollow
# node. (If detection works, this can never fire.)
if data_dir && !serving? do
  IO.warn("""
  COMMONPLACE_DATA_DIR is set (#{data_dir}) but this boot is not serving,
  so Mode B did NOT activate: no Bursar, no orchestrator, no workspace
  lock. HTTP may still answer while every take/move fails with
  :bursar_unavailable (CX-p6g0). Start with PHX_SERVER=true or via
  `mix phx.server` if you meant this to be a serve.
  """)
end

if serving? && data_dir do
  config :commonplace, workspace_lock_on_boot: true
  config :commonplace, bursar_on_boot: true
  # CX-3xwu (A): the continuous ghost-reaper runs on the Mode-B serve (it needs
  # the node identity + workspace root + the live SessionLimit/PresenceRegistry
  # trackers). Explicit-flag gated in application.ex; can be disabled by omitting
  # this (the reaper is node-elevated + the highest-hazard presence component).
  config :commonplace, ghost_reaper_on_boot: true

  # CX-0t2r (recording-half revival, CX-nyvm parity): a Mode-B serve is a
  # serve like any other — it must also drive reflog checkpoints, or the
  # reflog goes dormant exactly like it did on the live :5199 workspace
  # (CheckpointTimer existed, never started, since 2026-04-25). Set here
  # AND in commonplace_cli's Serve.run/3 (Mode A) so both boot paths agree,
  # per the CX-nyvm lesson (bursar_on_boot was Mode-B-only once and broke
  # every move on a Phoenix-as-serve boot).
  # CX-0t2r deploy lesson (2026-08-03): reflog checkpointing is NOT a
  # serve-role detail like the bursar/lock/reaper flags around it — it
  # starts WRITING checkpoints into the live store, so it must be a
  # deliberate act, separately stageable from "deploy the code". Setting
  # it unconditionally here made "ship the reflog code" and "turn
  # checkpointing on" the same event on a Mode-B boot, which silently
  # collapsed a deliberately staged A-then-B deploy into one step.
  # It therefore rides its OWN env var (default OFF), unlike its
  # neighbours — the Mode-A serve path mirrors this exactly (CX-nyvm
  # parity still holds: both paths read the same var).
  config :commonplace,
    reflog_on_boot: System.get_env("COMMONPLACE_REFLOG_ON_BOOT") in ["1", "true"]

  # CX-x073: the userland one-shot scheduler (Commonplace.Scheduler.Agent).
  # Same shape and the same reasoning as reflog_on_boot directly above:
  # it FIRES TIMERS and WRITES to `__system/scheduler`, so it is
  # world-MUTATING rather than a serve-role descriptor, and must be
  # separately stageable from "deploy the code". Default OFF — every
  # existing launch omits this var and boots exactly as before.
  config :commonplace,
    scheduler_on_boot: System.get_env("COMMONPLACE_SCHEDULER_ON_BOOT") in ["1", "true"]

  # CX-i9ca-adjacent (2026-07-11): a Mode-B serve must also make the
  # GitBridge find its mount mapping, or the workspace→git mirror silently
  # stays down (the supervisor boots with zero bridge children). The mapping
  # lives at `<COMMONPLACE_DATA_DIR>/git_bridges/git_bridges.json`, so DERIVE
  # git_bridge_data_dir from the already-set COMMONPLACE_DATA_DIR — no new
  # launch var needed, and every Mode-B serve auto-loads the bridge on boot.
  # Overridable via COMMONPLACE_GIT_BRIDGE_DATA_DIR for a non-default layout.
  # (Regression fix: a 2026-07-11 restart dropped a hand-set put_env and the
  # jes5199/commonplace-data mirror sat inactive for ~5 days.)
  config :commonplace,
         :git_bridge_data_dir,
         System.get_env("COMMONPLACE_GIT_BRIDGE_DATA_DIR") ||
           Path.join(System.get_env("COMMONPLACE_DATA_DIR"), "git_bridges")
end

# CX-qat5.7: the local-write gate knob is otherwise Application-env only
# (default :dry_run — which OBSERVES but still LANDS the write). For an
# exposed workspace flipped to strict (accept_unsigned: false in
# trust.json), :dry_run would silently re-open the write hole on the next
# serve restart, because a strict trust config only DENIES when the gate
# is :enforce. Map an OS env → the app knob so a serve can boot
# strict-enforcing durably and PER NODE (a permissive dogfood node simply
# omits this var). Values: off | dry_run | enforce.
if gate = System.get_env("COMMONPLACE_LOCAL_WRITE_GATE") do
  # Keep the raw string inert. Commonplace.Trust.local_write_gate/0 is the
  # single parser/resolver and refuses values outside the declared set.
  config :commonplace, local_write_gate: gate
end

# CX-a7i2: the local-read gate (`Trust.Read.gate/3`, CX-73a3) has the SAME
# activation gap the write gate had before CX-qat5.7 closed it — it is
# otherwise Application-env only (default :permissive — the P3 read cohort
# serves exactly as before). For an exposed workspace flipped to strict, a
# read gate stuck at :permissive would leave private reads open regardless
# of trust.json, because the P3 surfaces only consult `authorized?/3` when
# this knob says to. Map an OS env → the app knob so a serve can boot
# read-strict durably and PER NODE (a permissive dogfood node simply omits
# this var), mirroring the write-gate bridge above exactly. Values:
# permissive | dry_run | enforce.
if gate = System.get_env("COMMONPLACE_LOCAL_READ_GATE") do
  config :commonplace, local_read_gate: String.to_atom(gate)
end

# CX-pm68: `CommitStore.init/1` REFUSES to boot when the commits store is
# unreadable AND `<data_dir>/root` shows a prior world existed — it will
# not silently substitute an empty world for a destroyed one (which is
# exactly what put an enforce-mode serve on a fresh world writing genesis
# docs). The deliberate fresh-start is an operator decision, so it needs a
# door: this env var, bridged to the app knob exactly like the two gates
# above. Absent → refuse (fail closed). Set → archive-and-fresh proceeds
# AND the fresh store records a {:fresh_reinit_fact, <iso8601>} row naming
# the archived predecessor, so the empty world carries its own provenance.
if System.get_env("COMMONPLACE_ACCEPT_FRESH_REINIT") in ~w(1 true yes on enforce) do
  config :commonplace, accept_fresh_reinit: true
end

# CX-gjpi — the :5199 multiplayer serve opts bots into FULL citizenship (own
# home + spawn-in-home, co-present with human players in the grafted "mud"
# world) via this env. Absent (dogfood, standalone) → bots keep the simpler
# starter-cert + shared-start-spawn behavior. Per-node, like the gate above.
if System.get_env("COMMONPLACE_MUD_FULL_CITIZENSHIP") in ~w(1 true yes enforce on) do
  config :commonplace, mud_full_citizenship: true
end

# CX-xwh4: only override the http binding outside test. In test the
# binding comes from config/test.exs (127.0.0.1:4002 — the address
# Wallaby's base_url targets). A blanket runtime override here would
# clobber that and Wallaby would hit a stale port.
unless config_env() == :test do
  config :commonplace_web, CommonplaceWebWeb.Endpoint,
    http: [ip: {0, 0, 0, 0}, port: String.to_integer(System.get_env("PORT", "4000"))]
end

if config_env() == :prod do
  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :commonplace_web, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :commonplace_web, CommonplaceWebWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :commonplace_web, CommonplaceWebWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :commonplace_web, CommonplaceWebWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
