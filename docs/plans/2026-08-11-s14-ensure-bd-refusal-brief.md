# S14 build brief: ensure_bd_dir failures stop their callers — CX-305k

> Plan ranked this S14 in the refill (msg 11253), noting the S2v4
> root-policy refusals make the path reachable daily: a `:minimal`
> workspace now REFUSES bd mints by class, and a caller that discards
> that refusal proceeds into /bd/-requiring operations against a world
> where /bd/ does not exist. The mechanism is measured (S2v2 caller
> audit + the S13 boot census row): `Bd.Workspace.ensure_bd_dir`
> returns caller-visible failures TODAY (enforce refusals, class
> refusals, store errors) and exactly THREE callers discard them:
>
> 1. `Commonplace.Bd.Importer.import_issues_jsonl/4`
> 2. `Commonplace.Bd.Migrate.import_from_export/5`
> 3. `Commonplace.CLI.Bd.run/3` (cli/bd.ex:27)
>
> The other callers (issues_dir_uuid/labels_dir_uuid/deps_uuid/
> meta_uuid, Frontier.Server.init) consume the returned UUID immediately
> and crash loudly — they are NOT in scope.

## ⛔ Escape hatch, up front

Stop and REPORT if ensure_bd_dir's return shape cannot distinguish
"exists/created (uuid)" from "refused (reason)" without changing its
signature for the loud-crash callers too — a signature change that
touches the healthy callers is a wider round than this brief, and the
seam you'd need is the report. Also stop if you find a FOURTH
discard-and-proceed caller the audit missed — name it.

## The property (the ticket's, verbatim intent)

A failed ensure is handled at each of the three sites as a NAMED
REFUSAL that stops the dependent operation — never proceed-and-fail-
deeper. Per plan's channel ruling (msg 11190): these are lazy/user
paths, so refusals PROPAGATE to the caller (they are not boot
skip-with-info sites). The refusal names what failed (the bd ensure),
why (the underlying reason — class refusal, trust refusal, store
error), and what operation did not run. No retry, no partial import.

## Tests (red-first, driving each site)

- RED-FIRST per site: force ensure_bd_dir to fail (a `:minimal`
  workspace is the natural constructor post-S2v4 — its class refuses
  the bd mint) and record what each of the three callers does on
  unmodified code (the discard-and-proceed shape, verbatim). After:
  each returns/prints the named refusal and the dependent operation
  did NOT run (verify by store re-read: no partial /bd/, no partial
  import).
- Control: on a `:default` workspace all three sites behave exactly as
  today (ensure succeeds, operations run).
- The loud-crash callers stay untouched (no signature change reaches
  them, or the escape hatch fired).

## Gates

bd workspace/importer/migrate + CLI bd test files, then FULL core suite
(mix test apps/commonplace/test) + `mix compile --warnings-as-errors`;
counts reported. Tmp stores only.

## Deliverable

Work left UNCOMMITTED for the operator to land. Report: red-first
verbatim per site, refusal texts verbatim, any fourth caller found,
test counts, deviations.
