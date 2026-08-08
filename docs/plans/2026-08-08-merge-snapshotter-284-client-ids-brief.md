# BUILD BRIEF — `merge_snapshotter.ex:284` reintroduces the CX-w1fw bug

**For:** Sol (codex) — parallel to the struct-opacity pass, **different branch**
**Ticket:** **CX-6zvr** — *"merge_snapshotter:284 reimplements
BlockStore.client_ids unsafely — MEASURE FIRST (P1 if confirmed, P3 doc-only if
refuted)"*, filed p1, type bug.
**Priority:** filed **p1**; drops to **p3 doc-only** if §2 refutes.
⚠️ The conditional is in the ticket TITLE on purpose — tix bodies are write-once
and cannot be amended (CX-7smx). If your measurement refutes the consequence, the
title still tells the truth and the priority field gets dropped; a title
asserting the bug would have become a permanently wrong claim. **So: report your
§2 result even if — especially if — it refutes.** The ticket was filed expecting
that outcome to be possible.
**Provenance:** carved out of `2026-08-08-yelixer-struct-opacity-build-brief.md`
§5 on purpose. That pass leaves line 284 byte-identical. **This is the ticket it
was carved out into.** Do not touch the other branch's files.

Environment contract: **§0 of the struct-opacity brief applies verbatim** —
named worktree, git metadata read-only, leave changes unstaged, no serve route,
`mix test apps/<app>` selects nothing, capture rc from the command not a pipe,
establish a run happened before counting it, read the source for signatures.

---

## 1. The defect

```elixir
# apps/commonplace/lib/commonplace/store/merge_snapshotter.ex:284
defp client_ids(%Doc{store: %{clients: clients}}), do: MapSet.new(Map.keys(clients))
```

Two levels into another module's struct, and **it is the exact mistake CX-w1fw
fixed, reintroduced**. The safe function is right there:

```elixir
# apps/yelixer/lib/yelixer/block_store.ex:274 (docstring, verbatim)
Returns every client id with at least one block — materialized or
still pending. `Map.keys(store.clients)` alone would miss clients
whose only blocks haven't been folded in yet.
```

⭐ **The same file already knows this.** `merge_snapshotter.ex:319-323` —
thirty-five lines below — calls `BlockStore.client_ids(store)` with the CX-w1fw
comment attached explaining why the safe version is required. `snapshotter.ex:226`
does likewise. One file contains both the safe call *with its rationale* and an
unsafe private reimplementation of it.

⚠️ Note the two are **not** interchangeable in shape either: `:284` returns a
`MapSet`, `BlockStore.client_ids/1` returns a **list** (`MapSet.to_list/1` at
`:281`). Check every consumer before substituting — `l_ns_clients` flows into
`split_dm/4` at `:143`/`:353`.

## 2. ⭐ STEP ONE IS A MEASUREMENT, NOT A FIX

The consequence is graded **PLAUSIBLE, NOT CONFIRMED**, and the unverified half
is exactly one question:

> **Can `reconstruct/2` leave blocks sitting in `d_l`'s `client_pending`?**

If yes, this is a live P1. If no, it is a latent hazard and a doc fix. **Do not
write a line of fix before you have answered it with a measurement.** Report the
answer as your first output, with the code you ran and its raw output.

What is known, and is circumstantial rather than conclusive:

- `merge_snapshotter.ex:242-250` — `reconstruct/2` is `Doc.new()` folded through
  `Encoding.apply_update/2`, nothing else.
- `block_store.ex:167` — `push/2` puts the item into `client_pending[client]`,
  **not** into `clients`.
- `encoding.ex:510` carries the CX-w1fw comment verbatim: *"materialized view —
  recent pushes may still be sitting in `client_pending`, not yet folded into
  `store.clients`."*

That reads like a yes. **It is still an inference, and the whole point of this
ticket is that an inference is what put line 284 there.** Measure it:

```
# sketch — build a doc the way reconstruct/2 does, then compare the two answers
{:ok, d} = Encoding.apply_update(Doc.new(), <update bytes with >=1 client>)
map_size(d.store.client_pending)              # > 0 ?
MapSet.new(Map.keys(d.store.clients))         # what :284 sees
MapSet.new(BlockStore.client_ids(d.store))    # what it should see
```

⚠️ **A single synthetic doc that happens to have folded proves nothing.** Drive
it through the real path — `build_merge_snapshot/4` with a genuine two-sided
chain — and report **both** sets, not just whether they differed. If they agree,
say so plainly; a refutation here is a good outcome and must not be talked
around.

## 3. If confirmed: the failing-first test

Order is not negotiable: **red first, with output pasted, then the fix.**

Construct a merge where a client's blocks land entirely in `d_l`'s
`client_pending` — one client contributing only to L, whose items arrive in the
final applied update. Assert on the **observable consequence**, not on the
internals:

- Preferred: the derivation map. `l_ns_clients` (:142) feeds `split_dm/4` (:143),
  which decides L-vs-R namespace per pair. A client misclassified R-side ⇒
  **derivation-map misattribution** ⇒ late-edit translation against the wrong
  namespace map. Assert the resulting `derivation_map` attributes that client's
  pairs to `l_ns`. That test fails today and passes after.
- Fallback only if the above can't be built: assert `client_ids/1`'s result
  directly. Weaker — it tests the helper, not the bug — so say so if you fall
  back.

**The red must be self-explaining**: it must name what it observed (*expected
client 7 in L namespace, found it in R*), not merely that a map differed. A red
that can't distinguish "the bug caused it" from "my fixture was wrong" is not
evidence.

Then run it **10× green after the fix and 10× red before**, and report the
counts. One red plus one green is exactly the evidence that has failed here
before.

## 4. If confirmed: the fix

Replace `:284` with a call to `BlockStore.client_ids/1` — via `Doc.client_ids/1`
if the struct-opacity branch has landed by then, otherwise directly — and
**reconcile the MapSet-vs-list shape** at every consumer. Carry the CX-w1fw
comment onto it, matching `:319-323`.

⇒ **Then delete the duplication**: `:284` and `:319` become the same call. If
one private helper can serve both, make it one. The defect existed because the
knowledge lived in a comment on one copy and not the other.

## 5. If refuted

Do **not** silently leave line 284 as it is. Land a doc-only change: a comment
at `:284` stating that it deliberately reads only materialized clients, **why
that is safe here** (citing your measurement), and what would break the
assumption. An unexplained divergence from the safe function 35 lines from a
call to the safe function will be re-litigated by the next reader — which is
how it got here.

## 6. Acceptance

1. §2's measurement reported first, with raw output, before any fix.
2. If confirmed: failing-first test demonstrated red **with pasted output**, then
   green; 10/10 both directions, counts reported.
3. `mix compile --warnings-as-errors` clean; test suites green per-app with
   **counts** (`mix test apps/<app>` selects nothing — run from the app dir).
4. The struct-opacity branch's files are untouched by this branch.
5. If refuted: §5's comment landed, and the P1 grading retracted explicitly.

## 7. Out of scope

- The 7 mechanical sites in the struct-opacity pass — different branch.
- Any *other* suspected bug you find. **Report it, don't fix it** — same
  reasoning that created this ticket: a semantic change smuggled into a
  differently-scoped change is the worst available outcome.
