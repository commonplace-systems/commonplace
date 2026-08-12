# CX-1mn4: yelixer history disposition

Date: 2026-08-12

Status: decision only; no repository or remote was changed

## Disposition

The standalone is not merely stale. Its published `main` has six commits after
the imported split point, while the umbrella has 93 later commits touching
`apps/yelixer`. The six standalone commits are not missing from today's
umbrella: four are **PRESENT** and two are **SUPERSEDED** by later umbrella
work. There are no **ABSENT** findings and therefore no recovery tickets to
file.

The downstream sync (CX-fbah, which needs this CX-1mn4 disposition) should use
an umbrella `git subtree split`, then append one merge commit to standalone
`main` with standalone `main` as first parent and the split tip as second
parent. Its resulting tree must equal the split tip exactly. This preserves
all six standalone commits and the umbrella's path-projected history without
rewriting standalone `main`.

One measured correction matters to the mechanism: the two *published,
reachable histories* share zero commits, but the umbrella's local object
database physically retains the 20 standalone commits through `dd5988a` as
unreferenced objects. With those objects available, `git subtree split`
reconnects the synthetic history to `dd5988a`; the split and standalone then
have a real merge base. The literal claim that the two object databases share
zero commit objects is false in this checkout. The conclusion that neither
published tip can fast-forward the other remains true.

## Independently re-derived ground truth

All commands below were read-only against
`/home/jes/sol-s35/wt` and `/home/jes/yelixer` unless explicitly labelled as
a local scratch experiment.

### Reachability, retained objects, and the squash

- `git rev-list --all | sort -u` produced 1,630 reachable umbrella commits and
  26 reachable standalone commits. `comm -12` produced 0. Positive controls
  found umbrella `HEAD` in the first corpus and standalone `f87d43e` in the
  second. Thus the published histories share no reachable commit.
- A separate physical-object census used `git cat-file --batch-all-objects`
  and filtered for commit objects. It found 2,048 commits in the umbrella
  object database, 26 in the standalone, and an intersection of 20: the full
  standalone line through `dd5988a`. `git branch --contains dd5988a --all`
  found 0 umbrella refs, which is the positive distinction between a retained
  object and published ancestry. The umbrella does not physically contain
  standalone tip `f87d43e`; the standalone does not contain umbrella import
  commit `cbbaddb1`.
- `523291ab94806601fd4e5d324b9cba9908a0f039` has parents
  `c05348ee61d7223046624ef571e3bf65fa686827` and
  `cbbaddb1df2690b824d0c37ae21e7aa80c7f7338`, with subject
  `Merge commit 'cbbaddb1...' as 'apps/yelixer'`.
- `git rev-list --parents cbbaddb1` returned only `cbbaddb1` itself: it is a
  parentless, one-commit history. Its subject is
  `Squashed 'apps/yelixer/' content from commit dd5988a`, and its metadata says
  `git-subtree-dir: apps/yelixer` and
  `git-subtree-split: dd5988aa1884ead4cb26eb1e6ce501ad905b509f`.
- Therefore the published import is a squash and no published-tip
  fast-forward exists in either direction. The retained unreachable objects
  explain why a fresh split made from this local object store can nevertheless
  reconstruct the pre-squash ancestry.

### Counts and split point

- `git cat-file -e dd5988a^{commit}` succeeds in the standalone, and
  `git merge-base main dd5988a` returns the full
  `dd5988aa1884ead4cb26eb1e6ce501ad905b509f`.
- `git rev-list --count dd5988a..main` returns 6.
- `git rev-list --count HEAD -- apps/yelixer` returns 94 in the umbrella;
  `git rev-list --count 523291ab..HEAD -- apps/yelixer` returns 93.
- `wc -l` returns 1,970 for umbrella `encoding.ex` and 1,012 for standalone
  `encoding.ex`.

The six standalone-ahead commits, oldest first, are:

| SHA | Subject |
|---|---|
| `b2a79c6fb6e939cb5cc4f3e7e08e0864472b5a7d` | CRDT hardening: deterministic YMap, binary-search BlockStore, tagged encoding errors, property coverage, dataset, and XML facades |
| `1538962e51d98583331f5b88df013948ffba6f00` | Resolve nested sub-types in `YMap.to_json` by ID-based type-key lookup |
| `b08f767eab5d318aa51cef1752588168fb9bb9d9` | Correct negative zigzag encoding and add the Yjs oracle harness |
| `7e316f40e7afd6e30eb4f3d323f1f5f346ccb327` | Correct boolean tags and use lib0 `writeVarInt` for integer Any encoding |
| `9d5775bc514c026b886fd7b70feb873a64fe32c0` | Remove the unused `BlockStore` alias from `Types` |
| `f87d43e4079642d5a4c48c10601bce68d9681a4c` | Support the then-v14-RC `xml_fragment` nested subtype JSON shape |

## Behavioural audit of the six

### Controls and probes

The searched umbrella corpus was non-empty: `find apps/yelixer -type f`
matched 112 files, including 75 test files; the positive control
`defmodule Yelixer.Encoding` matched. Historical-object searches used a
17,342-row `git rev-list --objects --all` index and positively found the
current `encoding.ex` blob before interpreting any zero.

Compilation needed writable dependency state. The shared dependencies were
copied to a throwaway `/tmp/cx1mn4-probe.*` directory (50 top-level dependency
entries), and both `MIX_DEPS_PATH` and `MIX_BUILD_PATH` were set to writable
paths there. No probe or build output was written to the repository.

Two behavioral runs were used:

- 96 focused existing tests covering encoding bytes and errors, BlockStore
  lookup, YMap determinism, and the XML element/fragment/text facades: 96
  tests, 0 failures.
- The generated oracle cases only (excluding the three reverse-direction
  tests that write fixture files): all 25 Yjs vectors ran, 0 failures. The
  passing set includes negative/positive integers, nested map, and nested
  array vectors. The nested vectors decode typeref 4 and assert the
  `{"attrs": ...}` / `{"children": ...}` shapes.

| Standalone commit | Verdict | Method and effect |
|---|---|---|
| `b2a79c6fb6e939cb5cc4f3e7e08e0864472b5a7d` | **SUPERSEDED** | First asked what the bundle made the code do: deterministic YATA-backed map reads, logarithmic BlockStore lookup, tagged malformed-input errors, convergence coverage, dataset coverage, and XML facades. All 12 production-file blobs at this standalone commit occur byte-identically in umbrella history (12/12, over the non-empty 17,342-object index). The focused run exercised its encoding-error, binary-search, map-order, and XML tests green. Today's implementations have since acquired cache, bounds, replay, snapshot, and XML hardening, so the original bundle is preserved but no longer the governing implementation. |
| `1538962e51d98583331f5b88df013948ffba6f00` | **PRESENT** | The fix derives `__sub:CLIENT:CLOCK` directly from the parent item ID and recursively calls `to_json`. Its post-fix `types.ex` blob is identical to the umbrella blob first landed at `368d7308`; today's function still performs that ID-derived dispatch. Both crafted oracle vectors that require nested map/array resolution passed. |
| `b08f767eab5d318aa51cef1752588168fb9bb9d9` | **PRESENT** | The post-fix `encoding.ex` blob is identical to the umbrella blob first landed at `90d965d3`. Direct assertions for `-1 -> <<1>>`, `-2 -> <<3>>`, signed round-trips, and the expanded negative-integer properties passed. The 25-vector oracle harness also ran green rather than merely being found textually. |
| `7e316f40e7afd6e30eb4f3d323f1f5f346ccb327` | **PRESENT** | The standalone post-fix `encoding.ex` blob is identical to the umbrella state after its split boolean/varint landings. Direct wire assertions passed: true `<<120>>`, false `<<121>>`, integer `1` as `<<125,1>>`, `-1` as `<<125,65>>`, and multi-byte positive/negative cases. The Yjs integer oracle vector also passed. |
| `9d5775bc514c026b886fd7b70feb873a64fe32c0` | **PRESENT** | This is cleanup, not a CRDT semantic change. Its post-change `types.ex` blob is identical to the umbrella blob first landed at `7d0ab4e4`; today's module has no `BlockStore` alias, and the focused compilation/test run emitted no unused-alias failure. |
| `f87d43e4079642d5a4c48c10601bce68d9681a4c` | **SUPERSEDED** | The exact implementation blob first landed in the umbrella at `3ce764f1`, and the two RC-era typeref-4 nested oracle vectors passed today. Later umbrella commit `35cb391e` re-measured the premise: current supported Yjs 13 and 14 prerelease lines use distinct nested type refs, while typeref 4 denotes a genuine `XmlFragment`. The umbrella correctly retained the `attrs`/`children` behavior for real fragments but retired the claim that all v14 nested types use it. Behavior preserved, scope corrected. |

No row is **ABSENT** or **INDETERMINATE**. Consequently no gated
`ticket_create` call is required. In particular, no finding has been left only
in this table awaiting recovery.

### Reviewer verification of the blob evidence (and why the instrument matters)

⚠️ **"The blob exists in the umbrella object database" would have been a
CIRCULAR test here, and must not be reproduced as one.** The umbrella
physically retains the 20 unreferenced pre-split commits with their trees
and blobs, so any file left unchanged between `dd5988a` and a later
standalone commit resolves to a blob the umbrella holds *because of the
import*, not because the change ever landed. Presence would have been
found for work that never arrived.

The audit above avoided this by searching the reachable
`git rev-list --objects --all` index. The reviewer re-ran the strongest
form of the test independently, on the row where a false PRESENT would
matter most (`b2a79c6`, the broad hardening bundle whose SUPERSEDED
label could otherwise hide an unexamined gap):

- Restricted to the files `b2a79c6` actually CHANGED against its parent
  `dd5988a` — 12 files, the only ones whose blobs carry information —
  and required each blob to be REACHABLE from an umbrella ref, not merely
  physically present.
- Result: **12/12 reachable in umbrella history.** The bundle's content
  demonstrably landed; the SUPERSEDED verdict is conservative, and
  "landed, then evolved" would be equally defensible.

Reviewer also independently re-derived: reachable-history intersection 0
with both positive controls passing; physical-object intersection 20;
`cbbaddb1` parentless with `git-subtree-split:
dd5988aa1884ead4cb26eb1e6ce501ad905b509f`; `523291ab`'s two parents;
`dd5988a` present-but-unreachable in the umbrella (0 containing refs);
and the six commits via `dd5988a..main`. These were derived from the
repositories, NOT from the S35 brief — the brief's own numbers came from
the same agent who reviewed this document, so re-deriving from the brief
would have left no independent check anywhere in the chain.

⚠️ The retained pre-split objects are UNREFERENCED and therefore
prunable by routine `git gc` at any time. Execution step 2's fetch is not
housekeeping; it is the mechanism's precondition. The failure mode is
loud (the split aborts on an unparseable recorded split hash, as the
`file://` experiment showed), not silent — but a clean CI clone will hit
it by default.

## Mechanism evaluation

### A. Umbrella subtree split, then merge into standalone

**Preserves the six:** yes. Standalone `main` remains the merge's first-parent
line, so all six commits remain ordinary ancestors.

**Preserves existing standalone history:** yes. The operation appends one
merge commit; it does not replace, rebase, amend, or force-update any existing
commit.

**What `git log` says:** when `dd5988a` is available during `git subtree
split`, the synthetic path history descends from the actual standalone split
point. The final log then honestly shows two post-`dd5988a` lines—the six
standalone commits and the umbrella's path-projected work—joined by one merge.

A local-only scratch experiment confirmed this. Splitting current umbrella
`HEAD` produced synthetic tip `7ab2a6fdd2e679422ffd3683fc0bff2c9b154cc0`,
113 commits with one root. Its merge base with standalone `f87d43e` was the
real `dd5988a`. A trial merge reported 12 content/add-add conflicts. An
unreferenced local probe merge commit with parents `f87d43e` then `7ab2a6f`
and the split tip's exact tree made both parent tips ancestors and produced a
byte-identical tree. These SHAs are experiment-local and are not proposed as
stable identifiers.

The brief's `--allow-unrelated-histories` variant was also evaluated. In the
measured environment the flag is unnecessary because the reconstructed split
and standalone have `dd5988a` as a merge base. If a clean clone lacks the
unreferenced standalone objects, the right response is to make `dd5988a` and
its ancestry locally available and rerun the split—not to accept a falsely
unrelated merge. This was tested in a transport-style `file://` clone: the
positive `HEAD` control succeeded, `dd5988a` was absent with exit 128, and the
first split failed explicitly because it could not parse the recorded split
hash. A local fetch of `dd5988a` from `/home/jes/yelixer` made the second split
succeed at the same 113-commit tip with merge base `dd5988a`. The final merge
should therefore be an ordinary merge.

### B. Graft or replace `cbbaddb1` onto `dd5988a`

**Preserves the six:** only as a local graph view unless a later explicit
merge is still made.

**Preserves existing standalone history:** a local replace ref does, but
ordinary clones do not receive replace refs. Making the view permanent would
require rewritten descendants or special replace-ref distribution, crossing
the no-rewrite boundary.

**What `git log` says:** locally it can make the squash look ancestral, but it
changes graph interpretation without changing the published commits and is
not portable. It is also unnecessary: subtree metadata plus the retained
split-point objects already reconstruct the honest path history.

**Decision:** lose this alternative. It is non-portable when harmless and a
history rewrite when made durable.

### C. Direct two-parent unrelated merge without path projection

**Preserves the six:** yes if standalone `main` is first parent.

**Preserves existing standalone history:** yes if appended normally.

**What `git log` says:** merging umbrella `HEAD` directly makes the standalone
claim the entire monorepo history and introduces the wrong root tree; merging
only a synthetic snapshot preserves content but hides the 93 umbrella
path-changing commits. Either account is less truthful than the subtree split.

**Decision:** lose this alternative. It preserves objects but fails to
describe the yelixer-specific development line accurately.

### Recommendation

Choose A with the measured correction: reconstruct the subtree split from
`dd5988a`, perform an ordinary merge, and set the result tree exactly to the
split tree. The all-present/superseded audit licenses choosing the umbrella
tree wholesale; no standalone-only behavior is discarded. B adds a
non-portable graph overlay, and C either imports unrelated monorepo history or
throws away the useful path history.

## Exact downstream execution plan

This is a plan for the downstream sync ticket, not work performed in this
round.

1. Record the live tips and all remote refs in both repositories. Require
   standalone `origin/main` still to be
   `f87d43e4079642d5a4c48c10601bce68d9681a4c`; stop on any movement and
   re-audit rather than overwriting it.
2. In a local umbrella clone, ensure the standalone commits through
   `dd5988a` are present as objects (a local fetch from the standalone is
   sufficient and need not create a remote ref). From the audited umbrella
   tip, create local branch `sync/yelixer-umbrella-split` with
   `git subtree split --prefix=apps/yelixer`.
3. Verify the split: its root/path history is non-empty, `git merge-base` with
   standalone `main` is exactly `dd5988a`, and its tip tree equals a direct
   archive/hash of `apps/yelixer` at the audited umbrella tip. Stop rather
   than use an unrelated-history escape hatch if the merge base is absent.
4. In a local standalone clone, create `sync/yelixer-main-merge` from the
   just-verified `origin/main`. Fetch the local subtree-split branch and merge
   its tip into this branch, preserving standalone tip as first parent and
   split tip as second parent.
5. Resolve the merge by making the index and worktree exactly equal to the
   split tip, then commit the merge. Do not rewrite `main`. Verify: both tips
   are ancestors; parent order is correct; all six SHAs are ancestors; and
   `git diff --exit-code <split-tip> <merge-tip>` succeeds. The scratch run's
   12-conflict count is diagnostic only, not an acceptance constant.
6. In the standalone result, install the pinned Node fixtures and run its full
   `mix test` suite. Run `diff_yjs_test.exs` separately against both stable and
   preview oracles with the oracle required. Expect **11 tests, 0 failures, 0
   invalid, and 0 skipped per oracle**; a missing oracle is not green. If
   compilation needs writable state in the isolated worktree, copy the shared
   dependencies and set `MIX_DEPS_PATH`/`MIX_BUILD_PATH` as this audit did.
7. Recheck the remote baseline immediately before publishing. Push only the
   validated merge branch to standalone `main` with a normal, non-force push,
   e.g. `git push origin sync/yelixer-main-merge:main`. Natural non-fast-forward
   rejection is a stop signal. Create no remote scratch branch and no tag.
8. After the push, verify standalone `origin/main` is exactly the merge tip,
   its first-parent ancestry contains the prior `f87d43e`, its second-parent
   ancestry contains the split tip and `dd5988a`, the tree still equals the
   split tree, both 11-test oracle runs remain green, and the remote-ref delta
   contains only the intended `origin/main` movement.

## This round's boundary and deviations

- No push, fetch from a network remote, tag, or real-repository branch was
  created. All merge and subtree experiments were local scratch-clone work.
- Standalone `origin/main` remained
  `f87d43e4079642d5a4c48c10601bce68d9681a4c`, and its remote-ref set remained
  exactly one ref: `refs/remotes/origin/main` at that SHA.
- A final live `git ls-remote --refs origin` read was blocked by SSH host-key
  verification (exit 128). Its empty output was not interpreted as a zero-ref
  result. The recorded local remote-tracking corpus remained non-empty and
  byte-identical to the baseline, and this round executed no remote-mutating
  command; this is the remote-enumeration verification deviation.
- The repository change is this one Markdown file only. It is intentionally
  left uncommitted.
- `sol-run.log` was not touched.
- No absent-change ticket was filed because the audit found no absent change.
- The umbrella root has no `mix precommit` task (`mix help precommit` reports
  it missing). The only similarly named alias is app-local and includes a
  broad formatter, so it was not substituted in this one-Markdown-file round.
  The audit's focused behavioral runs are reported above.
- Deviation/correction: “zero shared commit objects” is true for the reachable
  published histories but false for the physical local object stores, which
  share 20 unreferenced commits through `dd5988a`. This was discovered by
  expanding the corpus from `rev-list --all` to `cat-file
  --batch-all-objects`, with positive controls, and it improves the selected
  mechanism without changing the no-fast-forward or no-rewrite conclusions.
