import Config

# The :coreseam env exists ONLY for bin/cp-core-seam's ratchet build (S1,
# CX-27vt): it compiles apps/commonplace's extractable core with the
# filesystem seam's above-side excluded. Nothing runs in this env — no
# server, no tests — so no configuration beyond the base config.exs is
# needed. The file exists because config.exs's per-env import requires one
# per compile env.
