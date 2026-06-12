# Outliner MVP Implementation Plan (move #3, CX-saix → CX-sugc → CX-k8tn → CX-2qjd)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. (This run: SERIAL inline execution per boss directive.)

**Goal:** A Workflowy-style collaborative outliner on the flat-bag-of-xml-items model — the daily-use "substrate for thinking" artifact, exercising structured-XML mutation, fractional ordering, the View layer, and the MCP action surface.

**Architecture:** The design is COMPLETE in commonplace-plan `docs/outliner.md` — this plan implements it without re-deciding anything. One `xml`-typed `_outline` doc holds flat `<item id parent order collapsed>` elements with `xml_text` content; the tree is reconstructed at render time from `parent`+`order(,id)`. Reparent = LWW `set_attribute` (never destroys the element — the §1 load-bearing result). Four beads: **i** the `Commonplace.Outline` mutation module + fractional-index minter, **ii** pure tree reconstruction with defensive orphan-to-root, **iii** `OutlineLive` (chat-shaped LiveView), **iv** `_view.xml` actions for the MCP/agent surface.

**Tech Stack:** `Yelixer.Types.XmlElement/XmlFragment/XmlText` (verified: `set_attribute/4`, `insert_child/4`, `delete_child/4` exist), CommitStoreClient CRDT-update commit path (NEVER CommandRouter string-merge — outliner.md §2), Phoenix LiveView, ViewActionDispatch/ArgResolver.

**Design doc:** commonplace-plan `docs/outliner.md` (§ references throughout). Pre-noodle audit: clod-squad msgs 5150/5152.

---

## Pre-verified facts (audit, msgs 5150/5152)

| Fact | Status |
|---|---|
| Structured XML API exists (`XmlElement.set_attribute/insert_child/delete_child`, `XmlFragment.*`) | ✅ yelixer/types/xml_element.ex:61/104/126 |
| XML survives snapshot compaction (CX-α is a map/array gap, NOT xml) | ✅ doc.ex: "XML sub-types ARE replayed structurally via replay_xml_*" (:439-441) — bead i pins it with a roundtrip test anyway |
| Fractional indexing | ❌ does not exist — bead i mints `between/2` + `(order, id)` comparator, property-tested |
| Commit entrypoint for structured ops | To verify FIRST in bead i (outliner.md §2's one load-bearing assumption): structured mutation → `Yelixer.Encoding.encode_update` → `CommitStoreClient.create_chained_commit` (chat's `commit_entry` shape) |
| ViewActionDispatch/ArgResolver MCP-wired with per-agent signing | ✅ verified during CX-88mw |

## File structure

- Create: `apps/commonplace/lib/commonplace/outline.ex` (mutations: create_outline, add_item, edit_text, reparent/indent/outdent, reorder, set_collapsed, delete_item)
- Create: `apps/commonplace/lib/commonplace/outline/order.ex` (fractional `between/2` + `compare/2`)
- Create: `apps/commonplace/lib/commonplace/outline/tree.ex` (bead ii: pure reconstruction + orphan-to-root)
- Create: `apps/commonplace_web/lib/commonplace_web_web/live/outline_live.ex` + route `live "/outline/:name"`
- Create: outline room scaffolding for `_view.xml` actions (bead iv — mirror chat's action declaration + handler registration in ViewActionDispatch)
- Tests: `apps/commonplace/test/commonplace/outline/{order_test,outline_test,tree_test}.exs`, `apps/commonplace_web/test/commonplace_web_web/live/outline_live_test.exs`, action-dispatch test mirroring chat's

---

## Bead i — CX-saix: `_outline` doc shape + structured mutation layer (M)

### Task 1: `Outline.Order` — fractional index
- [ ] Failing tests (property-style): `between(nil, nil)` mints a middle key; `between(l, r)` is strictly between for random pairs; repeated head/tail/bisection inserts stay sorted and key length grows boundedly (e.g. ≤ O(inserts) chars, no pathological blowup on 1000 bisections); `compare({o1,id1},{o2,id2})` total-orders with id tiebreak on equal `order`.
- [ ] Implement base-62 LexoRank-style minter (pure, ~60 lines).
- [ ] Commit `CX-saix(i): fractional-index order keys with (order, id) tiebreak`.

### Task 2: commit-entrypoint verification + `Outline` module core
- [ ] FIRST: a failing integration test that (a) creates an `_outline` xml doc via the structured API, commits through `CommitStoreClient.create_chained_commit`, reconstructs via DocBuilder, and round-trips attributes + text; (b) SNAPSHOT PIN: force a snapshot of the doc, reconstruct from the snapshot, assert identical items/attributes/text and identical `(order,id)` sort (the msg-5152 regression pin).
- [ ] Implement `Commonplace.Outline`: `create_outline(name, root_uuid, store, opts)` (room dir + `_outline` doc + `_view.xml` placeholder, chat's room-creation shape); `add_item(outline_uuid, %{parent:, after_sibling:, text:}, store, opts)` (mints id + order via `Order.between` of neighbors); `edit_text/4` (XmlText ops); `reparent/4` + `indent/3` + `outdent/3` (pure `set_attribute` per §3 — indent = preceding sibling's id, outdent = grandparent); `reorder/4` (order attr between new neighbors); `set_collapsed/4`; `delete_item/3`. ALL accept `opts[:signing_context]` (agents-as-principals applies — move-#1 keystone).
- [ ] All ops tested against reconstructed doc state; concurrent-reparent LWW test (two docs, conflicting `parent` writes, merge → exactly one parent, text edits to subtree survive).
- [ ] Commit `CX-saix(ii): Outline mutations — structured-XML ops on the flat bag, signing-context aware`.

## Bead ii — CX-sugc: tree reconstruction + defensive handling (S)

- [ ] Failing tests for `Outline.Tree.reconstruct(items)`: nested ordering by `(order, id)`; orphan (`parent` → missing id) re-rooted to top-level FOR DISPLAY (input untouched — pure function, no writes); 2-cycle (`X→Y→X`) both re-rooted; collapsed flag carried; stable across permuted input order.
- [ ] Implement: `%{id => item}` index → group by parent → sort groups → attach; reachability walk from roots; unreached → root. Pure, no store access.
- [ ] Commit `CX-sugc: pure tree reconstruction with orphan-to-root (display-only, never mutating)`.

## Bead iii — CX-k8tn: `OutlineLive` (M)

- [ ] Route `live "/outline/:name"`; mount = schema-walk `outline/{name}/_outline` (chat's resolution path), subscribe `commits:{uuid}`, reconstruct via `Outline.Tree`, render `<ul>/<li>` with collapse toggles + contenteditable bullets (wiki/chat daisyUI idiom).
- [ ] Keybind events → `Outline.*` directly (§5: LiveView does NOT round-trip through `_view.xml`): `Enter` new sibling, `Tab`/`Shift-Tab` indent/outdent, `Alt-↑↓` reorder, `Ctrl-.` collapse, `Backspace`-on-empty delete.
- [ ] On `{:commit, ...}`: re-read + re-reconstruct (cheap+pure per §5).
- [ ] LiveView tests (wiki_live_test store-restart pattern): render seeded outline; keybind event mutates doc + re-renders; second-client live update via PubSub.
- [ ] Commit `CX-k8tn: OutlineLive — render, keybinds, live updates`.

## Bead iv — CX-2qjd: `_view.xml` actions → MCP surface (S/M)

- [ ] `_view.xml` written by `create_outline` declares: `add_item`, `edit_text`, `indent_item`, `outdent_item`, `reorder_item`, `toggle_collapse`, `delete_item` with `<arg>`s (chat's declaration vocabulary).
- [ ] Handlers registered the way chat's actions are (find chat's ViewActionDispatch registration; same shape), each delegating to `Commonplace.Outline.*` with the session `signing_context` threaded (agent mutations are SIGNED — move-#1 applies).
- [ ] Dispatch test mirroring chat's: invoke `indent_item` through ViewActionDispatch with a SigningContext; assert mutation landed + commit signer is the agent.
- [ ] Commit `CX-2qjd: outline actions on the MCP surface — declared in _view.xml, signed by agents`.

## Acceptance (the move-#3 exit)

- [ ] Full umbrella verification (core/cli/web/mcp, warnings-as-errors).
- [ ] Live demo-grade proof: scripted two-browser (or LiveView-test) session — two clients edit concurrently (text char-merge + concurrent reparent), an MCP agent restructures via action dispatch with its signed identity; transcript into the bead close.

## NOT in scope (outliner.md §6 follow-ups — beads exist)
Kleppmann cycle-safe move (CX-liim), mirrors/node-id transclusion (CX-lm7p), zoom (CX-f3n5), per-viewer collapse (CX-puo8), generic structured-source renderer.
