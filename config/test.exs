import Config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :commonplace_web, CommonplaceWebWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "26FYrtjPc3AIBms1hcBZdZn2iMKjSDPhFQigjlroque2gzSoGp+XaaNt49h+In1C",
  server: false

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
  reader_lazy_snapshot_enabled: false
