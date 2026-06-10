ExUnit.start()
# CX-tdkq.9 (R9): scale benchmarks are excluded by default — they're a
# measurement harness, not correctness tests, and scale up to slow/
# memory-heavy magnitudes. Run them explicitly with:
#   mix test apps/commonplace/test/commonplace/scale_benchmark_test.exs --include scale
ExUnit.configure(exclude: [:scale])
