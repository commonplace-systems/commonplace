# S1a build brief: binary-file floor — skip loudly, DECLARED IN THE PIN, and g8r1's crash retires

> Plan's ruling (msg 11170): floor now, fidelity later by design doc
> (binary-as-artifact-reference — NOT this round; do not build any binary
> ContentType or artifact store). The floor releases CX-g8r1's crash fix,
> landing together with it; S1b's refusal (running/landed ahead of this) is
> the protector, so the ordering constraint is satisfied. Plan's summary of
> this round: "no crash, no silent drop, pins that tell the truth about
> what they hold." Dispatch AFTER S1b lands (same files).

## ⛔ Escape hatch, up front

Stop and REPORT if:
- Declaring the skips in the pin requires changing the EVENT schema or
  RedLog beyond adding a field to the proto-pin map built in
  `ProtoChit.cut_pin` — the pin map is the intended home; if the plumbing
  from sync to pin turns out to need more than threading a list through
  `emit`, report the shape you found.
- Yelixer's half-built binary path tempts you to use it. It is ruled OUT of
  this round (it becomes the encoding of the future artifact-reference
  envelope — plan's design doc, not yours).

## The property

1. A file whose content fails `String.valid?/1` NEVER crashes or aborts a
   sync pass (this guard IS the CX-g8r1 crash fix — non-UTF-8 content must
   never reach `Text.insert`). Applies to `do_apply_create_file` AND
   `apply_modify`'s new_content (a text file replaced by binary content
   skips the modify, keeping the existing store content and saying so).
2. Every such file becomes a NAMED PER-FILE SKIP: logged loudly (path +
   reason), no schema entry minted (create) / entry unchanged (modify),
   and the pass's accounting satisfies
   LANDED ∪ REFUSED ∪ SKIPPED == files-encountered.
3. ⭐ THE SKIPS ARE DECLARED IN THE PIN (plan's condition — the fm7x
   invariant "excluded = declared" applied to binaries): the proto-pin map
   that `cut_pin` builds gains a field enumerating the skipped files
   (path + reason, e.g. `"excluded-binary"`), so a pin's meaning is
   self-contained — a witness reading the pin sees what the world does NOT
   hold and why. Additive field on `commonplace-reflog-path-pin/v1`;
   whether that warrants a format-version note is your call — make the
   choice and RECORD it in the schema doc's pin section (a doc edit, in
   scope since the pin section is under your hands).
4. All-text worlds: byte-for-byte today's behavior, pins unchanged except
   the (empty or absent — choose and record) exclusions field.

## Tests (red-first)

- RED-FIRST: repo with one binary among text files → unmodified code
  CRASHES the pass (the CX-g8r1 stack; record it) → after: pass completes,
  text files landed, binary skipped by name, schema clean of it.
- ⭐ Pin declaration: run a tapped emit over such a repo (or drive
  emit/cut_pin at the API level like proto_chit_test does) and READ THE
  EVENT BACK: the pin's exclusion field lists the skipped file with its
  reason. Never asserted from logs alone.
- Modify-to-binary variant: existing text entry keeps its store content;
  skip declared.
- Control: all-text repo — identical behavior, pin exclusions empty/absent
  as chosen.
- Accounting: a mixed repo's pass reports LANDED ∪ REFUSED ∪ SKIPPED ==
  encountered (build the denominator from what ARRIVED).

## Gates

- Watcher/sync tests + core proto-chit tests + cli app suite + full core
  suite; counts reported. `mix compile --warnings-as-errors` clean. Tmp
  stores only.
- ⚠️ Sandbox: trust anchors empty in here; fixture contexts as the existing
  sync tests use.

## Deliverable

Work left UNCOMMITTED for the operator to land. Report: red-first verbatim,
the pin-field choice (name/shape/version note) with where you recorded it,
the accounting evidence, test counts, deviations.
