# BUILD BRIEF — measure the nested-type TYPEREF BYTE across three Yjs versions

**For:** Sol (codex)
**Unblocks:** **CX-wzkr** (is the `:xml_fragment` branch untested or dead?) and
**CX-kak5** (what surface should the generators target?)
**This is a MEASUREMENT ticket. The deliverable is a table of bytes, not a fix.**

---

## 0. Environment contract (standing)

Named worktree off **current** `origin/main`; ⛔ git metadata read-only, **leave
changes UNSTAGED**, no `git add`, no commit, **do not work around
`index.lock`**; no serve route (none needed); `bin/cp-test-guard --min N --apps
N -- <cmd>` for any suite, one at a time; ⚠️ **rc from the command itself,
never a pipe**; ⚠️ **a count from a piped listing is not a count**.

## 1. The question, and why it is load-bearing

`Yelixer.Types.sub_type_to_json/2` has an `:xml_fragment` branch. It exists
because of commit **`f87d43e`**, whose message states:

> *"Yjs v14's unified YType encodes all nested types as typeref 4
> (xml_fragment)."*

**That premise is now in doubt.** Measured 2026-08-09 — the v14 **JS API**
walked back the unified-YType model between the clone's rc and the pinned
`14.0.0-16`:

| | `d.get("content")` | `.insert` |
|---|---|---|
| clone v14 **rc** (`/home/jes/yelixer/yjs/src/index.js`) | `YType` | **function** |
| `yjs-preview` **14.0.0-16** | `AbstractType` | **undefined** |

and on 14.0.0-16, `d.getText("t").insert` **is** a function.

⛔ **BUT THAT IS AN API FACT, NOT AN ENCODING FACT, AND THE WHOLE POINT OF THIS
TICKET IS NOT TO CONFUSE THEM.** *typeref 4* is a claim about **bytes on the
wire**; `YType` vs `AbstractType` is a claim about **method names in a JS
object**. It would be very easy — and wrong — to slide from *"the unified model
was walked back"* to *"nested types aren't xml_fragment any more."* **That
slide would be a conclusion built entirely on adjacency.** Nobody has tested
the encoding. You are going to.

**The port's mapping, for reference** (`encoding.ex:858-864`):
`0 array · 1 map · 2 text · 3 xml_element · 4 xml_fragment · 5 xml_hook ·
6 xml_text`

## 2. The measurement

Both oracles are already installed by CX-wzkr as npm aliases in
`apps/yelixer/test/fixtures/` — `yjs-stable` (13.6.32) and `yjs-preview`
(14.0.0-16). The clone's rc is at `/home/jes/yelixer/yjs/src/index.js` and can
be imported by absolute path.

**For each of the three versions:** build a doc containing a **nested type**
(a map whose value is a nested Y type — the shape that reaches
`sub_type_to_json/2` at all), `Y.encodeStateAsUpdate`, and **report the typeref
byte actually emitted for the nested type.**

⇒ **Deliverable: a three-row table.** version → typeref byte → what the port's
mapping calls it.

⚠️ **How you extract the byte is yours to choose** — decode with
`Yelixer.Encoding` (it already decodes typerefs), or read the update bytes
directly. **Say which, and why it is faithful.**

## 3. ⛔ Two controls, both mandatory

1. ⭐ **A POSITIVE CONTROL: a case whose typeref you already know must come back
   as expected.** A top-level `getText` should encode as **2 (`:text`)**, a
   `getMap` as **1 (`:map`)**. ⛔ **Without this, a result of "no typeref 4
   anywhere" is unfalsifiable** — indistinguishable from an extraction that
   reads the wrong offset, or a doc that never contained a nested type.
2. ⭐ **ASSERT THE ENCODE ACTUALLY RAN before comparing anything.** Non-empty
   update bytes, process exit 0.
   ⚠️ **This is not boilerplate — it is the exact hole found hours ago:** a
   byte-identity check reported `before X / after X / cmp rc=0` **because the
   generator had crashed before writing**. A comparison that passes hardest
   when the work did not happen is worthless. **Prove the work happened, then
   compare.**

## 4. ⚠️ A second trap, one level down

`getText` / `getMap` / `getArray` exist in **both** 13.6.32 and 14.0.0-16,
which makes them the obvious conversion target for CX-kak5's generators.
⛔ **"Both versions have this method" is an API claim, not an encoding claim.**
Converting to a shared surface **does not guarantee the two lines emit the same
bytes.**

⇒ **So also report: for the SAME construction, do 13.6.32 and 14.0.0-16 emit
the same typeref byte?** If they differ, that is a **finding, not a problem** —
it is precisely what the two-oracle matrix exists to surface.

## 5. Acceptance

1. **The three-row table** (rc / 13.6.32 / 14.0.0-16), with the raw bytes shown.
2. **Both controls demonstrated**, with output.
3. **A one-line answer to the question that unblocks CX-wzkr:** does any
   currently-supported Yjs version encode nested types as **typeref 4**?
4. **The same-construction comparison from §4.**
5. ⛔ **REPORT ONLY. Change no production code.** The decision this enables —
   *add nested coverage* vs *delete the branch and correct the docstring* — is
   mine, and they are **completely different fixes; shipping the wrong one is
   worse than shipping neither.**
6. **Name anything you could not verify in-sandbox** and stop rather than
   approximating.

## 6. Out of scope

- Fixing `sub_type_to_json/2` either way.
- CX-kak5's generators.
- Any other defect: **report it, don't fix it.**
