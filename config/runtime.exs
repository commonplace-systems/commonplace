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
if System.get_env("PHX_SERVER") && System.get_env("COMMONPLACE_DATA_DIR") do
  config :commonplace, workspace_lock_on_boot: true
  config :commonplace, bursar_on_boot: true
  # CX-3xwu (A): the continuous ghost-reaper runs on the Mode-B serve (it needs
  # the node identity + workspace root + the live SessionLimit/PresenceRegistry
  # trackers). Explicit-flag gated in application.ex; can be disabled by omitting
  # this (the reaper is node-elevated + the highest-hazard presence component).
  config :commonplace, ghost_reaper_on_boot: true

  # CX-i9ca-adjacent (2026-07-11): a Mode-B serve must also make the
  # GitBridge find its mount mapping, or the workspace→git mirror silently
  # stays down (the supervisor boots with zero bridge children). The mapping
  # lives at `<COMMONPLACE_DATA_DIR>/git_bridges/git_bridges.json`, so DERIVE
  # git_bridge_data_dir from the already-set COMMONPLACE_DATA_DIR — no new
  # launch var needed, and every Mode-B serve auto-loads the bridge on boot.
  # Overridable via COMMONPLACE_GIT_BRIDGE_DATA_DIR for a non-default layout.
  # (Regression fix: a 2026-07-11 restart dropped a hand-set put_env and the
  # jes5199/commonplace-data mirror sat inactive for ~5 days.)
  config :commonplace, :git_bridge_data_dir,
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
  config :commonplace, local_write_gate: String.to_atom(gate)
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
