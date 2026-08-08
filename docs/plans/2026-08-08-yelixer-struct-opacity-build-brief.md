# BUILD BRIEF — yelixer struct-opacity pass

**For:** Sol (codex)
**Design authority:** `commonplace-plan/docs/plans/2026-08-08-yelixer-struct-opacity-api-spec.md`
(and its companion `2026-08-08-repo-extractability-ruling.md` §2). Read §0 of the
spec first. This brief is the **contract**; where brief and spec differ, the brief
wins and says why.

**Ordering:** this lands BEFORE Phase 1 of the extractability work — 4 of the 8
sites sit in CommitStore's immediate neighbourhood.

---

## 0. Environment contract (standing — true of every Sol task, not just this one)

These are environment facts, not ticket facts. They do not change per brief.

- **Work in the named worktree**, on the named branch, off main.
- ⛔ **Git metadata is read-only. LEAVE YOUR CHANGES UNSTAGED.** Do not `git add`,
  do not commit, and **do not work around `index.lock`** — hitting it is the
  sandbox working correctly, not an obstacle to route around. Improvising here
  cost a whole run on 2026-08-07.
- ⛔ **No BEAM distribution, no route to the live serve** (closed at 4af35a7).
  Nothing in this task needs one. If you think you need live access, stop and
  say so.
- ⚠️ **`mix test apps/<app>` selects NOTHING** in this umbrella — it silently
  runs zero tests and exits 0. Run per-app from the app directory, and **check
  the test count**.
- ⚠️ **Before counting a run, establish that it ran.** A zero-failure line over
  zero tests is indistinguishable from success. Report counts, not verdicts.
- ⚠️ **Capture the return code from the command itself, never from a pipe.** A
  pipeline's status is the *tail's* status; a pipe that swallows status also
  swallows the failing test's name.
- ⚠️ **`tmp/test_data` is shared** — concurrent runs collide there.
- ⚠️ **Read the source for signatures.** Do not infer an arity or a return shape
  from a name, a docstring, or this brief.

---

## 1. The rule, and its bound

> yelixer owns its structs; commonplace may **hold and pass** them, never
> **construct or destructure** them.

The bound is the load-bearing half. `Doc` is a **container** — opaque, because
reaching through it binds you to its internal layout. `Item`, `ID`, `DeleteSet`
are **value types** — their fields *are* their interface.

| Forbidden | Permitted — do NOT change these |
|---|---|
| Constructing `%Doc{…}` outside yelixer | `%Doc{} = doc` as a bare type assertion (no field bindings) |
| Traversing through a Doc — `doc.store`, `%Doc{store: %{clients: c}}` | Reading a field off a value type — `item.deleted`, `item.parent_sub`, `id.client` |
| Rewriting a Doc field — `%{doc \| types: …}` | Any `Yelixer.*` public function call, including `BlockStore.f(store)` when `store` came from an API |

Concretely: `%Doc{} = source` at `snapshotter.ex:157`, `:205` and
`merge_snapshotter.ex:294` **stay**. The ~40 `item.deleted` / `&1.parent_sub`
reads **stay**. `BlockStore` stays public — the leak was never `BlockStore.f(…)`,
it was **`doc.store`** as the way to get its argument.

If the diff grows past ~9 commonplace files and ~7 new yelixer functions, you
have exceeded the bound. Stop and report rather than continuing.

---

## 2. Work — Tier 1: pure delegation

Precedent already exists in `apps/yelixer/lib/yelixer/doc.ex:277`:

```elixir
def state_vector(%__MODULE__{store: store}), do: BlockStore.state_vector(store)
```

Add its siblings in the same file, same shape, each with a `@doc`:

```elixir
def client_ids(%__MODULE__{store: store}), do: BlockStore.client_ids(store)
def all_items(%__MODULE__{store: store}),  do: BlockStore.all_items(store)
def get_item(%__MODULE__{store: store}, %ID{} = id), do: BlockStore.get(store, id)
def sequence(%__MODULE__{store: store}, type_name), do: BlockStore.get_sequence(store, type_name)
def types(%__MODULE__{types: types}), do: types
```

(Verified present and matching arity: `BlockStore.client_ids/1` :277,
`all_items/1` :293, `get/2` :189 — takes `%ID{client:, clock:}` — 
`get_sequence/2` :594.)

Call sites to retire — **line numbers verified against HEAD 7838704**:

| Site | Now | After |
|---|---|---|
| `commonplace/store/snapshotter.ex:226` | `%Yelixer.Doc{store: store}` → `BlockStore.client_ids(store)` (:230) | `Doc.client_ids(doc)` |
| `commonplace/store/merge_snapshotter.ex:319` | `%Doc{store: store}` → `BlockStore.client_ids(store)` (:323) | `Doc.client_ids(doc)` |
| `commonplace/store/merge_snapshotter.ex:311,312` | `BlockStore.get_sequence(source.store, n)` / `(new_doc.store, n)` | `Doc.sequence(source, n)` / `Doc.sequence(new_doc, n)` |
| `commonplace/store/cross_epoch_merge.ex:316` | `BlockStore.state_vector(d_c.store)` | `Doc.state_vector(d_c)` *(already exists)* |
| `commonplace/projection/mixed_plane.ex:71` (+ `:85`) | `%Doc{types: types, store: store}` then `BlockStore.get_sequence(store, name)` | `Doc.types(doc)`; thread `doc` (not `store`) into `classify/3` and call `Doc.sequence(doc, name)` |
| `commonplace/audit/lww_loss.ex:181,182` | `%Doc{store: store}` → `BlockStore.get(store, id)` | `Doc.get_item(doc, id)` |
| `commonplace_cli/.../inspect_cmd.ex:118,121,140,153` | `doc.types`, `BlockStore.state_vector(doc.store)`, `BlockStore.all_items(doc.store)` | `Doc.types/1`, `Doc.state_vector/1`, `Doc.all_items/1` |

`mixed_plane.ex:85` is the one that isn't a one-liner: `classify/3` currently
takes `store`. Change its signature to take `doc`. That is in scope.

`inspect_cmd.ex:152` is a **comment** mentioning `doc.store.clients` — leave the
prose alone unless it becomes wrong; it doesn't.

---

## 3. Work — Tier 2: `Doc.put_type/3`

`mud/session_view.ex:493` and `trust/read_meta.ex:99` both do
`%{doc | types: Map.put(doc.types, name, {:xml_element, "view"})}`.

This is **not** `Doc.get_or_create_type/3` (`doc.ex:310`) — that one deliberately
never overwrites; these two callers deliberately need force-overwrite.

```elixir
@doc """
Force-registers `name` → `type_ref`, overwriting any existing entry.
Unlike `get_or_create_type/3`, this OVERWRITES …
"""
def put_type(%__MODULE__{types: types} = doc, name, type_ref),
  do: %{doc | types: Map.put(types, name, type_ref)}
```

**Carry `session_view.ex`'s replay-quirk rationale into that docstring** (the
one at :476 — a named root's tag is never recovered off the wire after replay,
so it must be re-registered or `to_string/2` silently emits wrong tags). It is a
statement about *yelixer's replay behaviour* and belongs in yelixer.

Note what this buys beyond packaging: `read_meta.ex`'s comment says "Mirror
SessionView.read_meta/2" — the struct reach caused a subtle invariant to be
**copy-pasted across two files**. One named function replaces two copies of a
rationale. Delete the now-redundant copy in `read_meta.ex`, keeping a one-line
pointer to `Doc.put_type/3`.

---

## 4. Work — Tier 3: `Encoding.encode_items/2`

`store/late_edit_translator.ex:153` and `store/cross_epoch_merge.ex:389` build
byte-identical synthetic `%Doc{}`s (`client_id: 0`, a `BlockStore` folded from
items at :144-145 / :385-386, the delete-set, `types: %{}`) purely to hand to
`Encoding.encode_update/1`.

⚠️ **Do not add `Doc.from_items/2`.** That relocates the leak — commonplace would
still be assembling a yelixer document in order to re-encode it. Name the API
after the **caller's purpose**:

```elixir
# apps/yelixer/lib/yelixer/encoding.ex
def encode_items(items, delete_set) when is_list(items) do
  store = Enum.reduce(items, BlockStore.new(), &BlockStore.push(&2, &1))
  encode_update(%Doc{client_id: 0, store: store, delete_set: delete_set, types: %{}})
end
```

Both call sites collapse to `Encoding.encode_items(items, delete_set)`.

**Move `late_edit_translator.ex`'s 17-line comment block (from ~:124) into that
docstring.** Every claim in it — `client_id` is never read by `encode_update/1`;
`types: %{}` is safe because type-declaration items carry their names in
`parent: {:named, _}`; the store is consulted only for GC remapping, and
foreign-namespace origins correctly miss — is a statement about **yelixer's
encoder internals**, currently maintained in a commonplace module where a
yelixer change can falsify it silently. That migration is the clearest single
instance of what this whole pass is for. Do not paraphrase it; move it.

---

## 5. ⛔ HARD CARVE-OUT — `merge_snapshotter.ex:284`

```elixir
defp client_ids(%Doc{store: %{clients: clients}}), do: MapSet.new(Map.keys(clients))
```

**Leave this line byte-identical. Do not touch it. State in the PR description
that you left it alone and why.**

It is two levels into another module's struct, and it is the mistake CX-w1fw
fixed, reintroduced. `BlockStore.client_ids/1`'s own docstring
(`block_store.ex:274`) says verbatim that `Map.keys(store.clients)` alone would
miss clients whose only blocks haven't been folded in yet — and **line 323 of
the same file** calls the safe function with the CX-w1fw comment attached. One
file contains both the safe call *with an explanation of why it's safe* and an
unsafe private reimplementation of it.

Suspected consequence: `l_ns_clients` (:142) feeds `split_dm/4`, which decides L
vs R namespace per pair; a client whose blocks sit entirely in `d_l`'s
`client_pending` is misclassified R-side ⇒ derivation-map misattribution ⇒
late-edit translation against the wrong namespace map.

**Graded PLAUSIBLE, not confirmed.** The shape is confirmed; the consequence is
not — it depends on whether `reconstruct/2` can leave pending blocks in `d_l`,
which nobody has verified. Keep that grading in anything you write.

Substituting `Doc.client_ids/1` here is a **semantic change**, and a semantic
change smuggled inside a "no behaviour change" refactor is the worst available
outcome. It gets its own ticket, its own failing-first test, and its own review —
possibly dispatched to you in parallel, but not in this PR.

---

## 6. The pin (same PR, while the invariant is green)

A CI step that fails on any **executable** `Commonplace` reference inside
`apps/yelixer/{lib,test}`.

⚠️ **I verified the 19 current hits and they are all prose — but 15 of them are
inside `@doc """ … """` heredocs, not `#` comment lines.** A checker that only
strips `#` lines goes red immediately on `yelixer.ex:70,296`,
`encoding.ex:1135,1755,1757`, `doc.ex:152,290,425,436` and six test-file
moduledocs. Your checker must strip **both** `#` comments and `"""` heredoc
bodies. This is the actual difficulty of the task; budget for it.

Two non-negotiables:

- **Pin the relation, not a literal.** The check runs against the real tree in
  CI — not a fixture copy, not a hardcoded list of the 19 known hits.
- **Tamper control.** A test that injects a real `alias Commonplace.Foo` into a
  temp copy of the tree and asserts the checker **fails**. Demonstrate it red in
  the PR description with the actual output.

A green checker that cannot go red is decoration — and this one starts green,
which is exactly when that failure mode is invisible.

---

## 7. Acceptance

Run these and paste real output. Do not assert green without it.

1. `mix compile --warnings-as-errors` clean.
2. `mix test --exclude diff_yjs` green (run per-app; umbrella multi-app test
   paths silently drop, so check the counts).
3. **Structural greps — REPAIRED.** The spec's §6 grep is broken in both
   directions: it does not match line 284 at all (which uses the `Doc` alias,
   not `Yelixer.Doc`) and it misses `merge_snapshotter:319`,
   `cross_epoch_merge:316,389`, `mixed_plane:71`, `lww_loss:181` and
   `late_edit_translator:153`. I ran it; it returns 10 lines, none of them 284.
   Use these four instead — all **`lib`-scoped on purpose** (see §8):

   ```bash
   # A — Doc destructure/construct with field bindings.  MUST return ONLY
   #     apps/commonplace/lib/commonplace/store/merge_snapshotter.ex:284
   grep -rnE '%(Yelixer\.)?Doc\{[a-z_]+:' apps/commonplace*/lib

   # A2 — multi-line Doc construction.  MUST be empty.
   grep -rnE '%(Yelixer\.)?Doc\{\s*$' apps/commonplace*/lib

   # B — BlockStore/Encoding called on a `.store` reach.  MUST be empty.
   grep -rnE '(BlockStore|Encoding)\.[a-z_]+\(\s*[a-z_0-9]+\.store' apps/commonplace*/lib

   # C — map-update rewriting :types.  MUST be empty.
   grep -rnE '%\{\s*[a-z_0-9]+\s*\|\s*types:' apps/commonplace*/lib
   ```

   Baseline at HEAD 7838704, so you can see them move:
   A returns 5 lines (mixed_plane:71, snapshotter:226, merge_snapshotter:284,
   merge_snapshotter:319, lww_loss:181); A2 returns 2
   (late_edit_translator:153, cross_epoch_merge:389); B returns 3 in lib
   (cross_epoch_merge:316, merge_snapshotter:311,312) plus inspect_cmd:140,153;
   C returns 2 (session_view:493, read_meta:99).
4. The three migrated rationales (encoder-internals block, replay-quirk comment,
   CX-w1fw note) live in yelixer docstrings and no longer in commonplace.
5. New CI check present and green, **and its tamper control demonstrated red**
   with pasted output.
6. PR description states the line-284 carve-out explicitly.

---

## 8. Explicitly out of scope

- **Tests — DEFERRED UNTIL THE DEP SWITCH, not permanently out of scope.**
  ~60 sites in `apps/commonplace*/test` reach `doc.store` (mostly
  `BlockStore.state_vector(doc_x.store)`), plus one `%Doc{store: store}`
  destructure at `test/commonplace/audit/lww_loss_test.exs:64`. Leaving them is a
  **decision, not an oversight**: while yelixer is an in-umbrella app, sweeping
  them triples the diff for no extractability gain. Do not touch them now, and
  do not scope the acceptance greps to `test` — they'd drown.
  ⚠️ **The reason has an expiry.** Once yelixer becomes an external dependency,
  every one of those test reaches carries the same version-skew hazard as the lib
  ones did, and this deferral must be revisited as part of the dep switch. Stated
  as an expiry so the decision doesn't quietly outlive its rationale.
- `merge_snapshotter.ex:284` (§5).
- Any `item.deleted` / `id.client` value-type read.
- Any behaviour change whatsoever. If you find a second suspected bug, **report
  it, don't fix it** — same reasoning as §5.
