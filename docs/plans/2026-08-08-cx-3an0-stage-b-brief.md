# BUILD BRIEF — CX-3an0 Stage B: stop full-scanning the commit store on every web session read

**For:** Sol (codex)
**Ticket:** **CX-3an0** (p1/bug) — *"EVERY WEB SESSION IDENTITY READ FULL-SCANS
THE COMMIT STORE"*
**Prior art:** Stage A shipped @1ecb5d1 — it fixed **only the scanner's own
enumeration** (one pass grouped by doc, instead of one pass per doc). **The hot
path in the ticket's title is still unfixed.** This is Stage B.

---

## 0. Environment contract (standing — true of every Sol task)

- **Work in the named worktree**, on the named branch, off **current**
  `origin/main`.
- ⛔ **Git metadata is read-only. LEAVE YOUR CHANGES UNSTAGED.** Do not
  `git add`, do not commit, and **do not work around `index.lock`** — hitting
  it is the sandbox working correctly.
- ⛔ **No route to the live serve or the live store.** Build your own fixture
  stores. The live store has one legitimate opener and it is not you.
- ⚠️ **`mix test apps/<app>` selects NOTHING** — it exits 0 having run zero
  tests. Use `bin/cp-test-guard --min N --apps N -- <cmd>` and report counts.
- ⚠️ **Capture the return code from the command itself, never from a pipe.**
- ⚠️ **Read the source for signatures.** Never infer an arity or return shape.
- ⚠️ **`tmp/test_data` is shared** — do not run overlapping suites.

## 1. ⛔ THE INVARIANTS — state these back in your report

1. ⛔ **THE INDEX MUST COVER EVERY `{:commit, _}` ROW, FROM EVERY WRITE SITE.**
   Not "the main one". See §3 — there are three, and the one that is easiest to
   miss is the one that matters most.
2. ⛔ **A MISSING OR STALE INDEX MUST BE DETECTABLE, NEVER A SILENT FALLBACK.**
   If `all_commit_ids_for_doc` quietly falls back to the full scan when the
   index is absent, the fix becomes invisible: still correct, still slow,
   nobody notices for months. Whatever the fallback is, it must **say so** —
   loudly, once, with the doc_uuid.
3. ⛔ **THE ACCEPTANCE IS A MEASUREMENT OF ROWS READ, not the existence of an
   index.** See §5.

## 2. The defect

`apps/commonplace/lib/commonplace/store/commit_store.ex:2596`:

```elixir
defp do_all_commit_ids_for_doc(db, doc_uuid) do
  CubDB.select(db, min_key: {:commit, ""}, max_key: {:commit, @max_key_binary})
  |> Enum.reduce(MapSet.new(), fn
    {{:commit, id}, %{doc_uuid: ^doc_uuid}}, acc -> MapSet.put(acc, id)
    _, acc -> acc
  end)
end
```

**It selects the ENTIRE commit range and filters in Elixir.** Every call reads
every commit row in the store — 71,042 rows as of the ticket, and the number
only grows.

The call path that makes this a p1 rather than a slow batch job:

```
web session identity read
  └─ Presence.Identity.read/3 · touch_last_seen/3   (identity.ex:224, :285, :314)
      └─ Identity.converge/2                        (unguarded — runs every read)
          └─ SiblingMerger.maybe_merge_siblings/3   (sibling_merger.ex:118)
              └─ CommitStore.all_commit_ids_for_doc/2   ← full scan
```

⇒ **Every web page view pays a full store scan.** Observed consequence
2026-08-08: with the umbrella test suite running concurrently, a
`ticket_create` through the serve blew CubDB's **5s GenServer call timeout**
mid-write (the ticket landed; the caller saw a timeout). The write path is that
close to the edge under load.

## 3. ⛔ THE TRAP — an index built "at the choke" MISSES SIBLINGS, which is exactly what the query is for

`{:commit, id}` rows are written at **three** places, and **only one of them is
the head-advance choke**:

| site | path | goes through `put_latest`? |
|---|---|---|
| `commit_store.ex:2434` | **sibling import** — commit persisted off a shared ancestor, `:latest` deliberately NOT advanced | ⛔ **NO** |
| `commit_store.ex:2426` | imported genesis | ✅ yes (`extra_rows`) |
| `commit_store.ex:1948` | `ensure_genesis` | ⛔ **NO** |

The R1 choke (`put_latest`, :2652) is a choke for **head advances**, not for
commit rows — and its own comment says the sibling branch *"deliberately does
NOT go through the choke"*.

⇒ ⚠️ **So the obvious implementation — maintain the index inside `put_latest`
— would omit precisely the sibling rows.** `maybe_merge_siblings` computes
`all_for_doc − dag_reachable_from(latest)`; if siblings are missing from
`all_for_doc`, that difference is **empty**, the function returns
`{:ok, :no_siblings}`, and **sibling merging silently stops happening.** The
store keeps accepting siblings; nothing ever merges them; every symptom appears
somewhere else, much later.

**That failure would be fast, green, and wrong** — and it is the single most
likely way to get this ticket wrong. Your report must state explicitly how all
three sites are covered.

## 4. Work

1. **Add a per-doc commit index**, e.g. `{:doc_commit, doc_uuid, commit_id} → true`,
   so `all_commit_ids_for_doc` becomes a bounded range select over one doc
   instead of a scan of all commits.
2. **Write it at every site that writes a `{:commit, _}` row** (§3), in the
   **same `put_multi`** as the commit row wherever one exists — the store's
   standing atomicity contract is that a commit row and its advance land
   together or not at all, and the index entry belongs in that same unit.
   ⚠️ If you find you cannot make it atomic somewhere, **say so** rather than
   quietly writing it separately.
3. **Backfill.** Existing stores have ~71k commit rows and no index entries. A
   store opened without a backfill must not silently answer from an empty
   index — that would report *no commits for any doc*, which is
   catastrophically wrong and completely quiet. Decide and state your approach
   (migration on open / lazy per-doc build / explicit task), and make the
   un-backfilled state **detectable**, per invariant 2.
4. **Keep the old function's contract**: it returns a `MapSet` of ids.

## 5. Acceptance — a MEASUREMENT, not an assertion

⛔ **"The index exists" and "the tests pass" are not acceptance.** The claim is
about rows read; measure rows read.

1. **Before/after row counts for ONE `all_commit_ids_for_doc` call**, on a
   fixture store with a realistic ratio (e.g. 5,000 commits across 500 docs,
   ~10 per doc). Report both numbers. The "after" should be proportional to
   that doc's commits, not the store's.
   ⚠️ **Instrument the measurement so it counts what CubDB actually reads**,
   not what your code chose to iterate. If you cannot count rows directly,
   state the proxy you used and why it is faithful.
2. ⭐ **A test that FAILS if the full scan comes back.** Build a store where
   one doc has few commits and the store has many; assert the call's cost does
   not grow with the store's size. Demonstrate it **red** against the current
   implementation and green against yours, and paste both.
3. ⛔ **A test proving siblings are still found** (§3): persist a sibling via
   the non-choke path, then assert `maybe_merge_siblings` still finds it.
   **Show this test red against an index built only at `put_latest`** — that is
   the failure this brief exists to prevent, so prove your code isn't it.
4. `mix compile --warnings-as-errors` rc=0; suites green **with counts**, via
   `bin/cp-test-guard`.
5. State how the un-backfilled / stale-index state is detected, and show it.

## 6. Out of scope

- The scanner path (Stage A, already shipped @1ecb5d1).
- Making `Identity.converge/2` conditional. It may well be wrong that a read
  path converges at all — **but that is a separate ticket**; changing it here
  would mask whether the index actually fixed the cost. **Report it, don't fix
  it.**
- Any other defect you find: **report it, don't fix it.**
