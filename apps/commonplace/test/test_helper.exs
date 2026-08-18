ExUnit.start()
Code.require_file("../../../test/support/file_rm_rf_guard.exs", __DIR__)
Code.require_file("../../../test/support/store_identity_assertion.exs", __DIR__)

leak_detector = Commonplace.Test.GlobalStateLeakDetector
formatters = ExUnit.configuration() |> Keyword.fetch!(:formatters) |> Enum.uniq()

# CX-0ktk: formatter events only attribute global mutations correctly when tests
# cannot overlap. The reproducer is already known to survive max_cases 1, so the
# permanent detector observes the whole population serially at its requested
# seed instead of blaming whichever concurrent test happens to finish first.
ExUnit.configure(max_cases: 1, formatters: Enum.uniq(formatters ++ [leak_detector]))
ExUnit.after_suite(&leak_detector.assert_clean!/1)
# CX-tdkq.9 (R9): scale benchmarks are excluded by default — they're a
# measurement harness, not correctness tests, and scale up to slow/
# memory-heavy magnitudes. Run them explicitly with:
#   mix test apps/commonplace/test/commonplace/scale_benchmark_test.exs --include scale
#
# CX-6scm: `:corpus` tests measure against a copy of LIVE store history
# (the conflicted-pins census's 537 MB backup), which is deliberately not
# in the repo and must be regenerated read-only. They flunk loudly rather
# than skip when their input is absent, so they are excluded by default
# and run explicitly:
#   CX_CORPUS=/path/to/backup mix test \
#     apps/commonplace/test/commonplace/projection/corpus_regression_test.exs \
#     --include corpus
#
# CX-q9sa: :rm_rf_guard_positive_control is deliberately NOT excluded. It is the
# rm_rf guard's only proof-of-life, and it now asserts that the guard raised AND
# that the live CommitStore directory survived — so GREEN means the guard works.
ExUnit.configure(exclude: [:scale, :corpus])
