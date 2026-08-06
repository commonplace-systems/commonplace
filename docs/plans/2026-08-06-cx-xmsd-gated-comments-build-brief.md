# CX-xmsd build brief: the gated comment path, and a backfill that counts the destination

Ticket: CX-xmsd (tix). Parent principle, binding on acceptance (boss 2026-08-05,
verbatim in the ticket): **a success report is a claim BY THE WRITER ABOUT
ITSELF** — "failed: 0" is equally consistent with wrote-everything,
wrote-nothing, and never-tried; only the DESTINATION count separates them.

## The measured defect (all three layers)

1. `Commonplace.Bd.Comment.add/4` threads NO signing opts, and
   `add_file_entry/4` DISCARDS `create_chained_commit`'s result (`:ok`
   unconditionally). Under Mode-B enforce every comment write is denied at the
   store gate while `add` returns `{:ok, %Comment{}}` — the CX-xxav
   phantom-success family, write-side. `edit`/`soft_delete` share the class
   via `write_comment` (result of `Schemas.write_text_doc` unchecked).
2. `Importer.import_comments_jsonl/4` swallows parse failures AND add failures
   (`_ -> acc`) and reports `{:ok, %{imported: count}}` — during the 2026-08-05
   migration it said "failed: 0" while landing ZERO (verified by destination:
   CX-oc30 bd 6/tix 0; CX-t3bt 5/0; CX-mchn 12/0).
3. Field-shape mismatch: `bd export` comments carry `text`; the importer reads
   `body` — even a signed import would land EMPTY bodies. (Also: export
   comment shape is `{id, issue_id, author, created_at, text}`; ids are
   uuids.)

Denominator, measured fresh 2026-08-06: 798 CX tickets exported; **92 carry
comments; 196 comments total**. The driver RE-MEASURES from its input export
every run (tix-migrate discipline) — never quote these constants as live.

## Build (CX-6cz3 pattern throughout)

### A. Library honesty — `apps/commonplace/lib/commonplace/bd/comment.ex`
- `add/5` (`opts \\ []`): thread opts into `Schemas.create_text_doc` and the
  comments-dir chained commit (`add_file_entry` gains opts). CHECK every write
  result; any denial/error returns `{:error, {:comment_write_failed, stage,
  reason}}` where stage ∈ `:doc_create | :entry_attach` — never `{:ok}` over a
  denied write. Ordering: doc create must SUCCEED before the entry attach is
  attempted; an attach failure reports the orphaned (harmless, append-only)
  doc uuid in the error. A schema entry pointing at an unstored doc must be
  impossible by construction.
- Same treatment for `edit/6` and `soft_delete/5` (opts + checked results).
- Idempotency for backfill: when `attrs.id` is supplied and the comments dir
  already has that filename, compare stored bytes: identical → `{:ok, :noop}`;
  different → `{:error, {:exists_with_different_content, id}}` (named refusal,
  NEVER overwrite).
- Keep `Comment` a library: no WriteGuard call here, no verb logic.

### B. Verb `ticket_comment` — `view_action_dispatch.ex`
Args: `%{"ticket" => id, "body" => body}` + optional `author`, `reply_to`,
`id`, `created_at`. Shape checks in the verb (binary body, ticket must load).
`signing_opts(context)` threaded to `Comment.add`. Returns the created
comment. Moduledoc states WHY WriteGuard is not consulted (comments carry no
protected fields, no graph edges, no close semantics — the §3 ruling scoped
the single-write-path property to TICKET writes; this verb extends the gated
surface to comments so the property no longer needs the qualifier).

### C. Verb `ticket_comments_import` — batch, ONE TICKET PER DISPATCH
(CX-hfxr lesson: the 524-record mega-batch cost a timeout and certified
nothing; bounded per-call work instead.)
Args: `%{"ticket" => id, "records" => [decoded maps in bd wire shape]}`.
Per record: normalize via a NEW PURE `Importer.normalize_comment_record/1`
(text→body, carry id/author/created_at; malformed → named refusal that ENTERS
the denominator) → `Comment.add` with opts → landed | noop | refused(named).
Returns `%{declared, landed, noop, refused: [...], unaccounted: []}` with the
runtime identity `landed+noop+refused == declared` checked in the verb —
build `declared` from what ARRIVED (records list length), never from what
survived normalization.

### D. Retire the ungated door — `importer.ex`
`import_comments_jsonl/4` becomes `Retired.write!` (the import_deps_jsonl
pattern), pointing at `ticket_comments_import`. Update its callers:
`TixMigration` (tix_migration.ex ~436) and the `bin/tix-migrate` header note.
Add `normalize_comment_record/1` (pure) next to `normalize_record/1`.

### E. Driver `bin/tix-backfill-comments`
tix-migrate harness verbatim (flock, inetrc, unique probe node,
`mix run --no-start`, dry-run default / `--execute`). Input: a bd export
jsonl path. Flow: parse export → per-ticket comment record lists (denominator
per ticket = export's list length, parse failures = refusals in the
denominator) → print the pre-write report → on execute, dispatch
`ticket_comments_import` per ticket (signing_context fetched from the serve,
`{:ok, sc}` unwrap) → aggregate. THEN THE ACCEPTANCE PASS, independent of
every import report: `Comment.list` per ticket via erpc, destination count vs
export count over ALL exported CX tickets (the 706 zero-comment tickets are
part of the identity: 0 == 0). Print per-ticket mismatches by name; exit 0
only on full identity. The driver never quotes the verb's own tally as
success — it is displayed, then ignored in favor of the destination count.

### F. Tests — targeted files only, red-first where marked
New file(s) under `apps/commonplace/test/commonplace/bd/`:
1. **RED-FIRST restore-the-bug control**: enforce-mode store (the
   audit_choke_perf_test setup pattern: trust env accept_unsigned false,
   gate :enforce, no signing opts) → OLD behavior: `Comment.add` returns
   `{:ok, _}` while `Comment.list` shows NOTHING (write the assertion that
   exposes the lie, watch it fail against the honest code you are about to
   write — i.e., assert add returns `{:error, {:comment_write_failed, ...}}`
   and confirm this test FAILS before your library fix, PASSES after).
2. Signed path: with signing opts (test key fixtures exist in trust tests),
   add lands; `Comment.list` count == writes made (destination count in the
   test too).
3. `ticket_comments_import`: mixed batch — valid + malformed + duplicate-id
   (re-run) → declared == landed+noop+refused, refusals NAMED; re-run of the
   same batch → all noop, destination count unchanged.
4. text→body: an export-shaped record (`"text"` key) lands with body ==
   text's content, non-empty.
5. Retirement: `import_comments_jsonl` raises `RetiredGraphError`… (use the
   actual Retired error type — check `Retired.write!`'s raise) — same test
   shape as the other retired surfaces.
6. Phantom guard: force the entry-attach stage to fail (denied chained
   commit) → error names `:entry_attach` + orphan uuid, and the comments dir
   schema has NO entry for it.

### G. MCP
Verify (grep) commonplace_mcp has no comment tooling; if truly absent, note
"nothing to reroute" in the completion report; if found, reroute through
`ticket_comment`.

## Constraints (non-negotiable, from today's incident and standing rules)
- Work in the assigned worktree only. NEVER run the CLI escript. NEVER touch
  `workspace/.commonplace` or any live store. No erpc/distribution from tests.
- Targeted test files only (`mix test <file>` per file from repo root),
  output captured to a file, `$?` checked before any formatting. NEVER the
  bare full `mix test`.
- `--warnings-as-errors` compile must pass.
- Commits: small, message names the defect layer each fixes.
