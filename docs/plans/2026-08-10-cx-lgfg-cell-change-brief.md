# BUILD BRIEF — CX-lgfg: promote the root-tag re-registration fixup into Yelixer

**For:** Sol (codex) · **the cell demo's step-3 change (2b slice 1) — but a
real fix on its own terms**
**Worktree:** `/home/jes/cell-1/wt` · **branch:** `cell/cx-lgfg-demo`
**Run log:** `/home/jes/cell-1/sol-run.log`

---

## 0. Environment contract (standing)

⛔ **UNSTAGED only — no `git add`, no commit, no push.** (This matters MORE
than usual here: your unstaged diff will be committed by the operator through
an instrumented git as part of a ceremony you are not part of. A commit from
you would corrupt the experiment.) ⛔ No serve, no live store.
⚠️ `mix deps.get` first. ⚠️ rc direct, never through a pipe. ⛔ NO BARE ZEROS.

## 1. The defect (CX-lgfg, diagnosis already done — do not re-derive)

A top-level named XMLElement's tag registration
(`doc.types[name] = {:xml_element, tag}`) is set locally by
`XMLElement.new_element/3` but never encoded onto the Yjs wire — only Items
are. On reconstruct/apply_update, `infer_type_ref` recovers `{:id,_}`-parented
items and `::children` keys but NOT a root registered under a named key: the
first item integrated with parent `{:named, name}` sticks
`get_or_create_type(doc, name, :unknown)`, `get_or_create_type` never
overwrites, so `tag_name(doc, name)` is nil forever after replay and
`XMLElement.to_string` emits corrupt `<>` open/close tags. Child elements
recover fine (synthetic names); ONLY the named root is affected.
`Commonplace.MUD.SessionView` works around it with a local
`reregister_root_tag/1` (force the types entry after reconstruct — safe
because the root name/tag are static).

## 2. The fix — the API route, and ONLY the API route

⛔⛔ **THE WIRE FORMAT IS UNTOUCHABLE.** Encoding the tag onto the wire would
be a Yjs-V1-compat change and an investigation; both are excluded by ruling.
No changes to `Yelixer.Encoding`, no new wire bytes, no changes to
`infer_type_ref`'s wire-derived behaviour.

✅ **IN SCOPE:** a small, documented, public Yelixer API that lets a caller
re-declare a named root's element tag after reconstruction — the promotion of
SessionView's workaround to where it belongs. Shape is yours within these
properties:

- It must UPGRADE an `:unknown`-typed named root to `{:xml_element, tag}`,
  and be idempotent when the registration is already correct.
- It must REFUSE (or make impossible) silently clobbering a DIFFERENT
  existing registration — re-declaring `{:xml_element, "mud"}` over
  `{:xml_element, "other"}` or over a `:map` is a caller error and must be
  loud, not a shrug. (SessionView's blind force-write is the workaround's
  weakness; do not promote the weakness.)
- `@doc` states WHY it exists (the wire carries no root tag; cite CX-lgfg)
  and when to call it (after reconstruct, before to_string).
- ⛔ Do NOT modify SessionView or anything under `apps/commonplace` — the
  callsite migration is a separate commonplace-side change, not this one.

## 3. The test — a replay round-trip that is RED without the fix

In yelixer's test tree: build a named root XMLElement with a tag, add a child
or two, `encode_update` → fresh doc → `apply_update`, show `to_string` emits
the corrupt `<>` root WITHOUT the new call (that is the red — keep it as an
assertion documenting current behaviour, not a skip), then the new API call
restores `<tag>…</tag>` byte-for-byte against the pre-replay rendering. Plus
the refusal case from §2 (conflicting registration is loud).

## 4. ⛔ Acceptance — artifacts

1. RED FIRST: the round-trip corruption reproduced in your tree before the
   fix, pasted.
2. The diff: yelixer lib + yelixer test only.
3. `mix test apps/yelixer/test` from the worktree root — rc + FULL counts.
   ⚠️ **Known fresh-worktree hazard (CX-ye7n, diagnosed): the 11 yjs-oracle
   `diff_yjs` tests go INVALID in a fresh worktree because the oracle needs
   an npm install in `test/fixtures`.** If you hit that: report the counts
   with the invalid set NAMED, and run the rest; do NOT chase the oracle
   setup and do NOT exclude anything silently. A clean run is ~5,320 dataset
   cases + unit tests; a count wildly below that means a subtree ran — VOID.
4. `mix compile --warnings-as-errors` rc=0.
5. ⛔ Your tree ends UNSTAGED. State it explicitly in the report.

## 5. Out of scope

- ⛔ Wire/encoding changes of any kind (§2).
- ⛔ SessionView / commonplace-side callsite migration.
- ⛔ The yjs-oracle fixture setup (CX-ye7n's own ticket).
- Any other defect: one line, don't pursue.
