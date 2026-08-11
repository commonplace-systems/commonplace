# S6 absent-config posture census

This census covers every operator-facing input found in the trust, gate, and
boot paths whose absence silently selects an enforcement, recording,
destructive-recovery, invariant, or citizenship posture. Internal serve-role
flags (for example `:workspace_lock_on_boot`) and tuning values are not separate
operator posture inputs; their external posture inputs are listed below.

| Knob | Absent default | Posture selected by absence | Invalid value | Resolved/read at |
| --- | --- | --- | --- | --- |
| `COMMONPLACE_LOCAL_WRITE_GATE` / `:local_write_gate` | `:dry_run` | Observe denials but allow the write to land. | Named `ArgumentError` refusal at boot; valid set is `off \| dry_run \| enforce`. The raw string is never atomized. | `apps/commonplace/lib/commonplace/trust.ex:1295`; raw bridge `config/runtime.exs:136` |
| `COMMONPLACE_LOCAL_READ_GATE` / `:local_read_gate` | `:permissive` | Serve reads without applying the authorization gate. | Named `ArgumentError` refusal at boot; valid set is `permissive \| dry_run \| enforce`. The raw string is never atomized. Red-first evidence captured the prior silent atom mint and `CaseClauseError` at the first gated read. | `apps/commonplace/lib/commonplace/trust.ex:1337`; raw bridge `config/runtime.exs:152` |
| `<data_dir>/trust.json` (or app env `:trust`) | `%{accept_unsigned: true, trusted_identities: %{}}` | Accept unsigned commits; local-node trust is folded in separately. | A present unreadable, malformed, or non-map file logs an error and resolves fail-closed to `accept_unsigned: false`; it does not halt boot. | `apps/commonplace/lib/commonplace/trust.ex:1176`, default at `apps/commonplace/lib/commonplace/trust.ex:1273` |
| `COMMONPLACE_REFLOG_ON_BOOT` / `:reflog_on_boot` | `false` | Do not start the checkpoint timer; no boot-driven reflog writes. | Any string except `1` or `true` resolves `false` (off). | `config/runtime.exs:102`; consumer `apps/commonplace/lib/commonplace/application.ex:554` (CLI mirror `apps/commonplace_cli/lib/commonplace/cli/serve.ex:48`) |
| `COMMONPLACE_SCHEDULER_ON_BOOT` / `:scheduler_on_boot` | `false` | Do not start the userland timer agent; scheduled jobs do not fire or write. | Any string except `1` or `true` resolves `false` (off). | `config/runtime.exs:111`; consumer `apps/commonplace/lib/commonplace/application.ex:649` |
| `COMMONPLACE_INVARIANT_ENFORCEMENT` / `:invariant_enforcement` | `:alarm_only` | Detect and report invariant failures without refusing mutations. | Named `ArgumentError`; valid set is `alarm_only \| enforce`. | `apps/commonplace/lib/commonplace/invariants/mode.ex:76` |
| `COMMONPLACE_ACCEPT_FRESH_REINIT` / `:accept_fresh_reinit` | `false` | Refuse to replace unreadable prior-world state with a fresh store. | Any string outside `1 \| true \| yes \| on \| enforce` resolves `false` (the refusal posture). | `config/runtime.exs:165`; consumer `apps/commonplace/lib/commonplace/store/commit_store.ex:1296` |
| `COMMONPLACE_MUD_FULL_CITIZENSHIP` / `:mud_full_citizenship` | `false` | Bots use starter certificates and the shared-start spawn behavior. | Any string outside `1 \| true \| yes \| enforce \| on` resolves `false` (legacy/simple citizenship). | `config/runtime.exs:173`; consumer `apps/commonplace/lib/commonplace/mud/bot.ex:499` |

The S6 boot fact prints the resolved value and provenance of all eight rows in
one log block. `ABSENT — defaulted` is intentionally distinct from `env-set`;
`trust.json`, application-env, and invariant-mode sources are named where those
resolvers have additional source tiers.
