import Config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :commonplace_web, CommonplaceWebWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "26FYrtjPc3AIBms1hcBZdZn2iMKjSDPhFQigjlroque2gzSoGp+XaaNt49h+In1C",
  # CX-xwh4: server:true unconditional in test so Wallaby feature tests
  # have a real Bandit listener on :4002. LiveViewTest works either
  # way (it doesn't go through HTTP); Wallaby requires the listener.
  # Tradeoff: every test run binds 4002. Acceptable; gate via env var
  # if it becomes a CI concern.
  server: true

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

config :commonplace,
  data_dir: "tmp/test_data",
  # CX-fab5 / CX-fkvc: keep background snapshot services off by default
  # in tests so async writes don't race with test isolation. Tests that
  # need the sweeper or the lazy trigger flip these flags in their setup.
  snapshot_sweeper_enabled: false,
  git_bridge_on_boot: false,
  reader_lazy_snapshot_enabled: false,
  # CX-xs2d: the boot-time doc-hosting manifest ensure is off in tests —
  # tmp/test_data persists across suite runs, so a boot ensure would make
  # every test resolve doc-hosted verbs against whatever stale docs that
  # store carries at the fixed engine UUIDs. Tests exercise the compiled
  # floors unless they seed docs deliberately (engine_module_test does).
  mud_manifest_on_boot: false,
  # CX-9hql: the CommitStoreQueuePoller ticks on its own timer and would
  # otherwise emit `[:commonplace, :commit_store, :queue_depth]` in the
  # background during every test, racing test-local telemetry attaches.
  # Tests that specifically exercise the poller enable it in their setup.
  commit_store_queue_poll_ms: false,
  # CI: CubDB 2.0.2's auto-compact races with the parallel test
  # suite's SecretStore writes and crashes the SecretStore process
  # (`MatchError {:error, :enoent}` at `cubdb.ex:1499 trigger_compaction`).
  # Disable auto_compact in tests — the SecretStore is small and
  # compaction is unnecessary for test workloads.
  secret_store_auto_compact: false

# CX-xwh4: Wallaby end-to-end tests via portable Chrome-for-Testing.
# Binaries fetched by `bin/setup-browser` into apps/commonplace_web/
# priv/browser/. Headless mode keeps tests CI-friendly (no X11).
#
# Wallaby's chromedriver config takes:
#   * `path:`   path to the chromedriver binary itself
#   * `binary:` path to the Chrome browser binary chromedriver drives
config :wallaby,
  driver: Wallaby.Chrome,
  otp_app: :commonplace_web,
  base_url: "http://localhost:4002",
  chromedriver: [
    path:
      Path.expand(
        "../apps/commonplace_web/priv/browser/chromedriver-linux64/chromedriver",
        __DIR__
      ),
    binary:
      Path.expand(
        "../apps/commonplace_web/priv/browser/chrome-linux64/chrome",
        __DIR__
      ),
    headless: true
  ]
