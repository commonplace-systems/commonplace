# S2v4 amendment brief: fix the chokepoint's population per plan's ruling — same worktree, build on your S2v3 work

> You are continuing YOUR OWN S2v3 build (uncommitted in this worktree).
> The structure was right; the review found the POPULATION wrong and plan
> has ruled the fix (msg 11209). Everything below amends
> `Commonplace.Workspace.RootWritePolicy` and its tests; the recorded
> profile, CLI flag, boot-skip, and temporal boundary you built stand.

## The defect being amended (from the operator's review)

`refused_entry/1` refuses ANY entry in the post-apply root for `:minimal` —
so a cell could never sync-import its own world (the first `mix.exs` attach
would refuse). Also: the check keys on any-entry-exists rather than the
COMMIT'S DELTA, and hardcodes 'cell' in the message.

## The ruled policy (transcribe exactly)

1. A REGISTERED SUBSTRATE-NAME SET lives in the policy module, seeded from
   the measured inventory — bd, chat, __bursar.json, __bursar.log,
   __reflog, __system, __identities__, __pulls, __processes.json (plus any
   your attach-path table found that this list misses) — each entry
   carrying WHICH CLASSES ACCEPT IT (:default accepts all; :minimal
   accepts none of them).
2. `:minimal` = NEGATION-ALLOW over that set: arbitrary repo content —
   mix.exs, everything a sync-import carries — lands freely.
3. ⭐ GRAMMAR BACKSTOP, every class: any UNREGISTERED `__`-prefixed root
   entry is REFUSED FOR EVERY CLASS (including :default). An unregistered
   dunder name is a programming error surfacing as a loud refusal at first
   mint — registration enforced by refusal, not memory. chat and bd are
   registered explicitly as grandfathered non-dunder names; state the
   going-forward convention in ONE sentence at the policy module: new
   substrate root entries use the __ prefix.
4. The check computes the COMMIT'S DELTA (entries added by THIS update:
   after-entries minus before-entries), never any-entry-exists.
5. The refusal message carries the WORKSPACE CLASS from the profile (no
   hardcoded 'cell') and the entry name.
6. The named residual goes in the module doc, not code: an author who both
   skips registration AND uses a bare name lands as content — the fadm
   torn-state refusal is the existing tripwire for import-only cells.
7. Keep: the security comment (__processes.json / auto-execution) at the
   chokepoint; the temporal-boundary behavior; everything else you built.

## Mandated test arms (plan's, plus your existing ones)

- ⭐ SYNC-IMPORT of a real cell-world shape (a handful of files + dirs at
  root: mix.exs, apps/, README.md ...) into a `:minimal` workspace → ALL
  LAND, read back from the schema. (The arm whose absence let the defect
  through.)
- An unregistered `__futurething` root attach → refused FOR EVERY CLASS
  (test :default AND :minimal), message naming the entry.
- A registered name attached in a non-accepting class (:minimal + bd) →
  refused, message naming the CLASS and entry.
- Your existing arms stand: re-mint, chokepoint-covers-scheduler, boot
  skip-with-info, profile recording, temporal boundary, red-firsts.
- Delta arm: a root commit that does NOT add entries (e.g. re-assert /
  metadata-only) passes for :minimal (the any-entry-exists regression pin).

## Gates

Your focused set again (workspace/bd/chat/scheduler/sync) + CLI app suite +
FULL core suite; counts reported. `mix compile --warnings-as-errors` clean.

## Deliverable

Work left UNCOMMITTED for the operator to land. Report: the registered set
as shipped (with class-acceptance table), red-first for the three new arms
(on your current S2v3 code, which fails the sync-import arm — record it),
test counts, deviations.
