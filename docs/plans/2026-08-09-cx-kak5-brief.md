# BUILD BRIEF — CX-kak5: de-hardcode the seven fixture generators

**For:** Sol (codex)
**Ticket:** **CX-kak5** (p2/bug)
**Deadline that matters:** this must land **before CX-1mn4 / CX-fbah rewrite
`/home/jes/yelixer`.** After that, the breakage lands on whoever next
regenerates a fixture, at the moment they can least tell whether the generator
or their own change is at fault.

⚠️ **This ticket's BODY contains two errors, corrected in its title and a
comment. Read them before the body.** The body says *six* files (it is
**seven**) and says to import bare `'yjs'` (that package **no longer exists**).
Details in §1 and §2.

---

## 0. Environment contract (standing)

- **Named worktree**, named branch, off **current** `origin/main`.
- ⛔ **Git metadata read-only. LEAVE CHANGES UNSTAGED.** No `git add`, no
  commit, **do not work around `index.lock`.**
- ⛔ **No route to the live serve or live store.** None needed.
- ⚠️ **`mix test apps/<app>` selects NOTHING** and exits 0 — use
  `apps/yelixer/test` with `bin/cp-test-guard --min N --apps N -- <cmd>`.
- ⚠️ **Run named suites ONE AT A TIME** (shared `tmp/test_data`).
- ⚠️ **rc from the command itself, never through a pipe.**
- ⚠️ **A count from a piped listing is not a count** — `wc -l` on the unpiped
  set, and `head` only to *look*. (This ticket exists partly because that rule
  was broken while filing it.)

## 1. ⛔ IT IS SEVEN FILES, NOT SIX

All seven import Yjs from the stale standalone clone. Established with
`grep -rlE "from '.*yjs/src/index\.js'" apps/yelixer/test/fixtures/*.mjs | wc -l`:

```
apps/yelixer/test/fixtures/complex_interop.mjs          '../../yjs/src/index.js'
apps/yelixer/test/fixtures/generate.mjs                 '../../yjs/src/index.js'
apps/yelixer/test/fixtures/multi_commit_generator.mjs   '/home/jes/yelixer/yjs/src/index.js'
apps/yelixer/test/fixtures/roundtrip.mjs                '../../yjs/src/index.js'
apps/yelixer/test/fixtures/verify_yelixer_in_yjs.mjs    '../../yjs/src/index.js'
apps/yelixer/test/fixtures/yjs_oracle.mjs               '../../../../../yelixer/yjs/src/index.js'
apps/yelixer/test/fixtures/yjs_verify.mjs               '../../../../../yelixer/yjs/src/index.js'
```

⚠️ **Note THREE different relative depths plus one absolute path.** At least one
was already wrong for its own location at some point — worth a moment's check
rather than assuming they all resolve today.

## 2. ⛔ THE FIX IS `'yjs-stable'`, NOT BARE `'yjs'`

CX-wzkr (merged @b589471, hours after CX-kak5 was filed) replaced the single
dependency with **two npm aliases**:

```json
"yjs-stable":  "npm:yjs@13.6.32",
"yjs-preview": "npm:yjs@14.0.0-16"
```

⇒ **There is no package named `yjs` any more.** A generator importing bare
`'yjs'` would fail to resolve.

⇒ **These are fixture GENERATORS, so they generate against the STABLE line:
`import * as Y from 'yjs-stable'`.** (jes's ruling: *new features* track the
preview; committed fixtures are not new features.)

⚠️ Node resolution note, verified: these live in
`apps/yelixer/test/fixtures/`, the same directory as `package.json` and
`node_modules/`, so a bare specifier resolves without extra configuration —
the same way `yjs_diff_driver.mjs` already works.

## 3. What these are, and what they are not

⚠️ **Nothing runs these automatically.** They are **generators**: they produce
fixture files that committed tests then load (e.g.
`multi_commit_fixture_test.exs` loads `multi_commit_fixtures.json` and
documents the regeneration command in a comment). **CI does not execute them.**

⇒ So the acceptance is **"they run and produce the same output"**, not "the
suite goes green" — the suite will go green either way, which is exactly why
this can rot unnoticed.

## 4. Acceptance — paste real output

1. **The census returns zero:**
   `grep -rlE "from '.*yjs/src/index\.js'" apps/yelixer/test/fixtures/*.mjs`
   → empty. Report it **unpiped**.
2. ⭐ **Each of the seven RUNS.** They currently work only because
   `/home/jes/yelixer` happens to exist; after your change they must work
   because the dependency is declared. **Run each one and report what
   happened** — some may need arguments or may fail for unrelated pre-existing
   reasons. ⛔ **If one was already broken before your change, say so and leave
   it broken** — do not repair unrelated breakage inside this ticket, and do
   not let a pre-existing failure read as one you caused.
3. ⭐ **Byte-identical output where a generator has committed output.**
   `multi_commit_generator.mjs` regenerates `multi_commit_fixtures.json`, which
   is committed — regenerate it and confirm **no diff**. If it differs, **stop
   and report**: that is a finding about the fixture, not a licence to commit
   new bytes.
4. **Prove the binding is gone**, not just redirected: move or rename
   `/home/jes/yelixer` **is NOT available to you** (outside the worktree) — so
   instead demonstrate resolution comes from `node_modules` by showing
   `node --input-type=module -e "console.log(await import.meta.resolve('yjs-stable'))"`
   from the fixtures dir resolves inside the worktree.
5. `apps/yelixer/test` green with counts — **1 doctest, 33 properties, 390
   tests on main.**
6. `mix compile --warnings-as-errors` rc=0.
7. **Say which criteria you could not verify in-sandbox** and stop rather than
   approximating.

## 5. Out of scope

- `yjs_diff_driver.mjs` — already de-hardcoded (CX-3mj2) and oracle-selecting
  (CX-wzkr). **Do not touch it.**
- Regenerating fixtures for any reason other than §4.3's identity check.
- Any other defect: **report it, don't fix it.**
