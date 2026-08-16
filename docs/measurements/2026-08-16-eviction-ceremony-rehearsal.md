# Eviction ceremony rehearsal — ratification evidence

This is the evidence record produced before ratification. It records a rehearsal
only: the signing contexts were deterministic fixtures, the store lived under
`/tmp`, and no custody, ratification, live activation, eviction, or live-store
write occurred.

The executable record is the test named `ceremony rehearsal prints twelve
distinct acceptance arms from isolated state` in
`sla_tombstone_test.exs`. Its stable output prefix is
`EVICTION_CEREMONY_ARM_`; the focused run at seed `117514` reported 5 tests,
0 failures, and 4 excluded.

## Twelve observed arms

1. `EVICTION_CEREMONY_ARM_1=:ok`. The active throwaway anchor registered its
   first tombstone through `CommitStoreClient.store_sla_tombstone/2`.
2. `EVICTION_CEREMONY_ARM_2` used fixture `:self_named_untrusted`. Ordinary
   authorization was `{:error, {:untrusted_signer, "self-named-untrusted"}}`;
   tombstone registration was `{:error, {:invalid_sla_tombstone,
   {:untrusted_tombstone_signer, "self-named-untrusted@e37abcd7"}}}`.
3. `EVICTION_CEREMONY_ARM_3` used the distinct fixture
   `:trusted_ordinary_writer_not_anchor`. Its ordinary authorization was `:ok`,
   while tombstone registration was `{:error, {:invalid_sla_tombstone,
   {:untrusted_tombstone_signer,
   "ordinary-writer-not-anchor@9a19fc9f"}}}`.
4. `EVICTION_CEREMONY_ARM_4` compared the identical commit
   `9EA3A49517EEC7097552174CF72356C40CE231CC5A5AB8B99B33A8B3BBDE78B0`.
   Ordinary-write authorization was `:ok` before anchor addition and `:ok`
   after anchor addition. No rejection claim is made.
5. `EVICTION_CEREMONY_ARM_5={:error, {:invalid_sla_tombstone,
   :no_eviction_anchor_configured}}` through the production registration
   entrypoint.
6. `EVICTION_CEREMONY_ARM_6={:store_assigned_position,
   "1BE2121651EE6FA03818A2CEB1169EF79DA9506BA0B3621CD9DDAA5048665908"}`.
   The caller supplied no ledger position.
7. `EVICTION_CEREMONY_ARM_7=:ok` after retirement and after the supervised
   CommitStore PID changed. The test's `refute restarted_store_pid ==
   old_store_pid` and subsequent `:sys.get_state/1` are the restart witness;
   verification again supplied only `store: ctx.store`.
8. `EVICTION_CEREMONY_ARM_8` was refused through
   `CommitStoreClient.store_sla_tombstone/2` as
   `{:eviction_anchor_already_retired, anchor_id, retirement_position}`. The
   observed retirement position was
   `597E290D772758D598A409BE149EE272B59648142F3353BAD78069DA02639AE2`.
9. `EVICTION_CEREMONY_ARM_9` covered documents
   `ceremony-unrelated-history-a` and `ceremony-unrelated-history-b`. Their
   distinct genesis parent IDs were
   `840267981B8CBF8F277FE98DC99BAFD233342FC1B0AE75E0791C10715EDDBB1A`
   and
   `E5D8E8C9F33874DDAAEF80B6AF785527430C4B0A2885E2D7C9A49F59B055D2A4`;
   both genesis parents had `parent_id: nil`, so the covered commits were not
   arranged into one chain. Their tombstone positions were
   `1BE2121651EE6FA03818A2CEB1169EF79DA9506BA0B3621CD9DDAA5048665908`
   and
   `B044502F4B8AC1E2D2BBBF601A12521383A1737585377C8159C19F4CC6BB47DB`.
   The store answered `{:ok, true}` for first-before-second, and both verified
   `:ok` after retirement.
10. `EVICTION_CEREMONY_ARM_10` observed three values for the same fixture:
    pre-activation registration was `{:error, {:invalid_sla_tombstone,
    :no_eviction_anchor_configured}}`; adding the anchor did not retroactively
    create ledger evidence, so verification returned
    `{:error, :eviction_anchor_activation_position_required}`; the subsequent
    production registration returned `:ok` by atomically creating activation
    before registration. Anchor configuration alone was not called activation.
11. `EVICTION_CEREMONY_ARM_11` kept the refusal mechanisms distinct. Retirement
    was the production-registration refusal
    `{:eviction_anchor_already_retired, anchor_id, retirement_position}`;
    revocation was `{:error, {:revoked_eviction_anchor,
    "throwaway-eviction-anchor"}}`.
12. `EVICTION_CEREMONY_ARM_12` printed the isolated paths
    `/tmp/sla_tombstone_4131` and `/tmp/sla_tombstone_4131/commits`, the live
    path `/home/jes/commonplace/workspace/.commonplace/commits`,
    `paths_distinct: true`, and
    `first_tombstone_reread_from_isolated_store: true`. The external before and
    after proof is below.

## Defined comparisons

- `EVICTION_CEREMONY_PAIR_2_3_DIFFER=true`: the fixture identities differed,
  and ordinary-write authorization differed (`untrusted_signer` versus `:ok`),
  even though both eviction registrations were refused.
- `EVICTION_CEREMONY_PAIR_4_AUTHORIZATION_SAME=true`: the same commit kept the
  same ordinary-write result across anchor addition, which is the required
  comparison for permissive `accept_unsigned: true` posture.
- `EVICTION_CEREMONY_PAIR_10_PRE_POST_DIFFER=true`: the pre-activation
  registration refusal differed from the later successful production
  registration.
- `EVICTION_CEREMONY_PAIR_11_RETIREMENT_REVOCATION_DIFFER=true`: the retirement
  and revocation refusal values differed.

## Arm 12 external isolation proof

Immediately around the focused ceremony run, the live paths were re-read:

| Reading | Before | After |
| --- | --- | --- |
| live commit population (`file_count:total_bytes`) | `3:4623633477` | `3:4623633477` |
| aggregate SHA-256 over live commit file hashes | `6c9a2984c678ef5975e4403ae0e635cb4573f62c87f90fa50387f0589423e5ca` | `6c9a2984c678ef5975e4403ae0e635cb4573f62c87f90fa50387f0589423e5ca` |
| live `trust.json` SHA-256 | `5e7cb75f3436bc3552ccca21cef797a1558786b57fdd236f21a60b1e13d32e65` | `5e7cb75f3436bc3552ccca21cef797a1558786b57fdd236f21a60b1e13d32e65` |

The shell proof ended with the grep-able values
`ARM12_LIVE_POPULATION_AND_TRUST_UNCHANGED=true` and
`ARM12_LIVE_COMMITS_CONTENT_UNCHANGED=true`. This demonstrates that neither a
test tombstone nor the throwaway constitutional anchor entered live state.

## Counts and suite block

Per changed test file:

- `test/commonplace/store/sla_tombstone_test.exs`: 5 tests before, 5 tests
  after; focused full-file result 5 tests, 0 failures. One earlier six-arm test
  was replaced by one twelve-arm rehearsal, so this file did not conceal a
  deletion behind the suite total.

The required `bin/cp-suite-baseline apps/commonplace` run reported:

```text
BASELINE — paste this whole block into the brief, not just the numbers:
  5 doctests, 3520 tests, 0 failures, 12 excluded, 1 skipped  (seed 117514, rc=0)
  --- state the run STARTED in (this is what explains the counts) ---
  sha:        d337f7c9 (DIRTY — 1 tracked file(s) under apps/ or config/ modified vs HEAD)
  test state: CLEAN — no tmp/test_data/root ⇒ Workspace.root_uuid() fails ⇒ serve-gated children stay OFF
  deps:       NO repo deps/ (sandbox-style: deps copied elsewhere)
  cwd:        /home/jes/commonplace-s83/apps/commonplace
  ⚠️ A round measuring in a DIFFERENT state above may legitimately differ.
     Treat a mismatch as a scope difference to investigate, NOT as the round being wrong.

(full output retained at /tmp/cp-suite-baseline.YMQwgr)
```

The suite also printed `GLOBAL STATE LEAK DETECTOR: 127 divergence(s) —
ADVISORY, not a failure` and the expected `positive control NOT RUN in this
suite` proof-of-life line.

## Near-miss and provenance

The arm-9 fixture initially assumed the production commit API would return a
parentless first commit. The focused red showed that it auto-wires a genesis.
The corrected proof re-read both genesis commits, required both roots to have
`parent_id: nil`, and required their IDs to differ. Treating the child commits
as parentless—or placing both under one genesis—would have reproduced the
single-chain mistake the round exists to catch.

A second near-miss was operational and observable: an attempted workaround for
the long suite's command-session cap created `/tmp/tmux-jes-s83/default`, a live
Unix socket. `Commonplace.Runner.LauncherTest` correctly found it and reported
`String.trim(channel_status)` as `"1"` rather than `"0"`. Removing only that
throwaway socket made the focused launcher test green (5 tests, 0 failures, 4
excluded), and the clean full-suite rerun was 3,520 / 0. The first red was mine,
not a known red and not a product defect.

Provenance is `docs/plans/2026-08-15-eviction-anchor-ceremony.md` §5 → landed
mechanism `17ce0ebc` → rehearsal brief `d337f7c9` → this file's former tests
`six eviction-anchor acceptance arms differ by authority and chain position`
and `store derives every position and public verification refuses evidence
seams` → the twelve-arm executable record and this evidence record. Repository
search found no downstream copy from this round at the time of writing.
