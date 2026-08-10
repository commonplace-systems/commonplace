ExUnit.start()
Code.require_file("../../../test/support/file_rm_rf_guard.exs", __DIR__)

# CX-xwh4: only start Wallaby when feature tests will actually run.
# Plain `mix test` skips Wallaby entirely (no chromedriver child
# process, no port collision, no startup cost). To run feature
# tests: `mix test --only feature`.
if Enum.any?([:feature], &(&1 in (ExUnit.configuration()[:include] || []))) do
  # Point Wallaby's chrome at our portable Chrome binary (no system
  # Chrome dependency).
  System.put_env(
    "WALLABY_CHROME_BINARY",
    Path.expand(
      "../priv/browser/chrome-linux64/chrome",
      __DIR__
    )
  )

  {:ok, _} = Application.ensure_all_started(:wallaby)
end

# Exclude feature tests by default — they need the chromedriver setup
# and run against a real Bandit listener (set up per-suite in
# CommonplaceWebWeb.FeatureCase). Run with `mix test --only feature`.
ExUnit.configure(exclude: [feature: true])
