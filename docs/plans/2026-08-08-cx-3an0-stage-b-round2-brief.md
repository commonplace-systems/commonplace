# BUILD BRIEF — CX-3an0 Stage B, round 2: finish the choke

**For:** Sol (codex)
**Ticket:** **CX-3an0** (p1/bug)
**Round 1:** `docs/plans/2026-08-08-cx-3an0-stage-b-brief.md` — **read it first**;
§0 (environment), §2 (the defect), §3/§3a (the two traps) all still apply
unchanged. Round 1's work is on `sol/cx-3an0-stage-b` and was **reviewed, not
merged**.

⭐ **Round 1 was good work.** Both red-first proofs are genuine (I re-ran them
against the naive implementations myself), the rows-read measurement is honest,
the bare writes stayed bare with their comment intact, and the prior art was
read and correctly judged inapplicable. **Two things remain.**

⚠️ **Start from `origin/main`, NOT from round 1's branch.** Round 1's diff is
yours to re-apply or rewrite as you see fit — take what's right (most of it is),
but the design below supersedes its indexing structure.

---

## 1. ⛔ FINDING A — a real regression, and the suites you must run

`apps/commonplace/test/commonplace/store/commit_id_range_scan_test.exs` goes
from **6 tests / 0 failures on main** to **4 failures** on round 1's branch.
Measured both directions.

⚠️ **This escaped because "run the full suite" was the acceptance, and the full
suite was blocked by a legitimate `tmp/test_data/commits.lock`.** You were right
to refuse to bypass that lock and should refuse again. **The fix is that this
brief names the suites instead.** ⇒ **Run these, by name, and report counts:**

```
apps/commonplace/test/commonplace/store/commit_id_range_scan_test.exs   # 6 on main
apps/commonplace/test/commonplace/store/doc_commit_index_test.exs       # round 1's new file
apps/commonplace/test/commonplace/sibling_merger_test.exs               # 8 on main
apps/commonplace/test/commonplace/store                                 # ~455 incl. 5 doctests
```

⚠️ **Do not run them concurrently with each other** — they share
`tmp/test_data`, and round 1's blocked run was self-contention, not another
agent. One at a time, via `bin/cp-test-guard --min N --apps 1 -- …`.

## 2. ⛔ FINDING B — `ready` means THE REBUILD RAN, not THE INDEX IS COMPLETE

Round 1's failure mode, in the shape that matters:

> commit rows present · index state says **`ready`** · `all_commit_ids_for_doc`
> returns **`MapSet.new([])`** · **nothing raises**

Round 1's invariant 2 asked a stale index to be *detectable*. It isn't: the
raise fires only when state **≠ ready**, so it cannot see *"ready but
incomplete."* ⇒ **The day a future write site adds a `{:commit,_}` row and
forgets the index, the result is a silent empty — which is the exact class this
ticket exists to prevent, moved up one level.**

⛔ **DO NOT TRY TO FIX THIS WITH DETECTION.** A genuine completeness check is
O(store) — it is the full scan we are deleting, so paying it to guard against
its own absence is circular. **Split the two jobs and let each cover what it
actually can:**

| job | mechanism |
|---|---|
| **missing call sites** | ⭐ the choke (§3) — structural, at compile-and-review time |
| **crash mid-write** | the dirty marker — which is all it was ever able to do |

⚠️ Right now the marker is asked to cover both and silently can't. ⭐ **A guard
that covers one of its two advertised jobs is worse than one that covers
neither, because the half it does cover is the evidence people cite for the
half it doesn't.**

## 3. ⛔ THE WORK — a ROW BUILDER, not a writer

The seven `{:commit,_}` write sites do **not** share a write mechanism: two are
bare `CubDB.put` (`:2434` sibling import, `:1948` `ensure_genesis`), five ride
inside `put_latest`'s `extra_rows`, and two of *those* carry a piggybacked
genesis. ⇒ **A writer helper could only serve the bare two; the other five
would need a parallel path — and a choke with two implementations is not a
choke.**

**So build a pure function:**

```elixir
# every {:commit,_} row in this store is produced HERE, with its index row
# structurally attached. There is no way to write one without the other.
defp commit_rows(%{id: id, doc_uuid: doc_uuid} = commit) do
  [{{:commit, id}, commit}, {{:doc_commit, doc_uuid, id}, true}]
end
```

- Use it to **build `extra_rows`** at all five `put_latest` sites (including
  both piggybacked-genesis sites, where it naturally yields four rows).
- Use it inside the bare-write helper for `:2434` and `:1948`.

⇒ **Then the index row is inseparable from the commit row at every site, and
"forgot to index" stops being a mistake anyone can make.**

⛔ **`:2434` STAYS SEMANTICALLY UNCHANGED** — bare write, no advance dispatched,
`:latest` untouched, its `_existing_latest` comment preserved verbatim. Routing
it through a row builder changes **what rows are written**, not **what the
branch does**. (boss-clod, 2026-08-08: the earlier ruling forbade a semantic
change to that branch; a pass-through is not one, and this completes the fix
round 1 started rather than restructuring anything.)

## 4. ⚠️ The raw-seeding tests need a DECISION, not an accident

`commit_id_range_scan_test.exs` seeds commit rows with raw `CubDB.put` **on
purpose** — its moduledoc explains that commit ids are content-addressed, so it
cannot go through `create_commit` and still control the id bytes it is testing.

⇒ **Pick one and say WHY in the test file:** either it seeds through the row
builder, or it explicitly marks the index dirty after seeding. ⭐ **Whichever
you choose, the next person will read a raw `CubDB.put` sitting next to a choke
and assume one of them is a bug — so the comment is the deliverable, not the
code.**

## 5. Acceptance — red-first, and paste real output

1. ⭐ **A test that fails if a `{:commit,_}` row can be written WITHOUT its
   index row.** Demonstrate it **RED against round 1's branch** (where the five
   `put_latest` sites build `extra_rows` by hand) and green against yours.
   That is the new invariant; prove it can catch its own violation.
2. **Round 1's two proofs still hold** — re-demonstrate both, red against the
   naive implementations:
   - index built only at `put_latest` → the sibling test goes red with
     `{:ok, :no_siblings}`
   - index from the advance's subject → the piggybacked-genesis test goes red
3. **All four named suites green, with counts** (§1). Especially
   `commit_id_range_scan_test.exs` back to **6/0**.
4. **The rows-read measurement preserved**, with its scope and baseline
   (round 1: 5,000 → 11 on a 500-doc / 5,000-commit fixture).
5. `mix compile --warnings-as-errors` rc=0.
6. **Say which criteria you could not verify in-sandbox** and stop rather than
   approximating them. Live-serve contention is not reproducible behind the
   fence; a fixture store you build **is** representative here, because this
   defect's cost is a function of store CONTENTS.

## 6. Out of scope

- `Identity.converge/2` — still out, for the same reason (it would mask whether
  the index fixed the cost). **Report it, don't fix it.**
- Any other defect: **report it, don't fix it.**
