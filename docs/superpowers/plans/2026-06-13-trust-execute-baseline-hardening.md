# Trust Execute-Baseline Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax. Serial, no background subagents, commit per task (boss directive).

**Goal:** Make the interim execute-baseline trust policy real in code — (.28) refuse minting a `:write`-without-`:execute` cert scoped to a code doc, and (.27) make the Gate-B contributor walk treat a snapshot as a terminal execute baseline only when its collapsed chain was execute-clean, so a node-signed snapshot can't launder write-only contributions into the execute baseline.

**Architecture:** Two complementary beads. **.28** is the interim, defense-in-depth mint-time guard (`Capability.issue/delegate` refuses write-without-execute on code-looking docs, best-effort content-sniff). **.27** is the airtight backstop: the Gate-B contributor walk (`Trust.authorized_to_execute?`) treats a snapshot as a terminal execute baseline **only if** a node-**local** `execute_clean` cache says the chain it collapses was execute-clean; an un-clean/uncached snapshot is non-terminal and the walk **continues** over the still-present (append-only) history. The verdict is **node-subjective** (config-relative), so it lives in a **local recomputable watermark cache** (§2(a)'s named mechanism) — *not* in the synced commit — computed lazily during the walk and served on the next walk. This keeps the phase-2.5 determinism property untouched (nothing node-subjective enters the content-addressed commit id). Revocation-driven invalidation stays a separate concern (CX-tdkq.21); within a fixed trust config the cache is sound because history below a snapshot is immutable (append-only).

**Tech Stack:** Elixir/OTP umbrella. `Commonplace.Trust`, `Commonplace.Trust.Capability`, `Commonplace.Store.{CommitStore, CommitStoreClient}`, `Commonplace.Document.ContentType`, `Commonplace.Tree.DocBuilder`. CLI: `Commonplace.CLI.Cap`.

---

## Key design decisions (converged with commonplace-plan, 2026-06-13, msgs #5234–#5246)

1. **CONTINUE-default, not deny.** CommitStore is append-only (verified: zero `CubDB.delete` on commit keys; `do_commit_log` returns full history past snapshots). So an un-clean/uncached snapshot is **non-terminal** — the walk continues over the still-present absorbed history and checks each contributor at its original signer. This is verbatim what `trust-and-attenuation.md` §2(a) says ("un-clean snapshots store fine but don't halt the execute walk"). **No legacy bricking, no migration, no grace window** — existing strict code docs keep passing because their pre-fix history is execute-clean (the write-without-execute-cert input didn't exist pre-phase-3). *(This corrected commonplace-plan's initial "GC'd → fail-closed deny" framing; the store is append-only.)*
2. **Local watermark cache, NOT a metadata stamp.** The verdict is node-subjective (depends on local trust config), so putting it in content-addressed metadata would give differently-configured nodes different commit ids for the "same" deterministic snapshot — denting the phase-2.5 convergence/CAS-dedup property. And a synced/tamper-evident stamp buys nothing usable: we'd never trust a *peer's* config-relative verdict; each node must recompute under its own config. So the verdict is a **local `{:execute_clean, cfg_fingerprint, commit_id} → bool` cache** (a non-synced CubDB key, not part of the commit), keyed by a fingerprint of the trusted set so a trust-config change naturally invalidates old entries (no stale-`true` foot-gun; CX-tdkq.21 may also flush). Correctness never depends on the cache — the continue-default re-walks full append-only history regardless — so the cache is **purely** a halt-early optimization that also bounds the §5 10k-`commit_log`-limit risk.
3. **Lazy compute, served on next walk.** The walk computes verdicts as a side effect (backfill) and serves them on subsequent walks — covering local-minted, peer-imported, and legacy snapshots uniformly with **no mint-path change**. Reads go through `resolve_db` (no GenServer round-trip, like `commit_log`); backfill writes are fire-and-forget `cast` (a lost write just means recompute next time), so the compile hot path is never blocked on cache I/O.
4. **Merges (scoped to moduledoc fix in .27).** The cache model needs no merge stamp. `.27` only fixes the stale "merges unsigned → strict denies converged code docs" moduledoc (false since 2.5 node-signs merges). The real merge fix — the `merge_parents`-omission (the walk follows `parent_id` only, never visiting the merged-in side, so an unclean merge can launder *and* poison a cached `true` above it) — is a **separate follow-up bead** commonplace-plan files: traverse `merge_parents` in the walk, or enforce the documented-not-enforced no-delta-merge-on-code-docs invariant. `.27` notes this cache limitation explicitly.
5. **.28 is best-effort.** The content-sniff is genuinely holey (non-`defmodule` code, view-XML/compute docs, remote/future-doc delegations). Do **not** oversell it as airtight in comments — `.27` is the backstop.

---

## File structure

| File | Responsibility | Bead |
|---|---|---|
| `apps/commonplace/lib/commonplace/trust/code_doc_heuristic.ex` (new) | Best-effort "does this UUID look like code / a process-decl doc?" | .28 |
| `apps/commonplace/lib/commonplace/trust/capability.ex` (modify) | Mint-time guard in `issue/5` | .28 |
| `apps/commonplace_cli/lib/commonplace/cli/cap.ex` (modify) | `--allow-write-without-execute` flag + store wiring | .28 |
| `apps/commonplace/lib/commonplace/store/commit_store.ex` (modify) | Local `execute_clean` cache ops (`get`/`put` cast/`flush`), `{:execute_clean, fp, commit_id}` non-synced keys | .27 |
| `apps/commonplace/lib/commonplace/store/commit_store_client.ex` (modify) | Passthroughs for the cache ops | .27 |
| `apps/commonplace/lib/commonplace/trust.ex` (modify) | Continue-default walk + cache read/backfill + moduledoc fix | .27 |

---

## Task 1 (.28): `CodeDocHeuristic` — best-effort code-doc classifier

**Files:**
- Create: `apps/commonplace/lib/commonplace/trust/code_doc_heuristic.ex`
- Test: `apps/commonplace/test/commonplace/trust/code_doc_heuristic_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Commonplace.Trust.CodeDocHeuristicTest do
  use ExUnit.Case, async: false
  alias Commonplace.Trust.CodeDocHeuristic
  alias Commonplace.Document.ContentType
  alias Commonplace.Store.CommitStore
  alias Yelixer.Doc

  setup do
    # Start an isolated CommitStore (follow commit_store_test.exs setup); bind `store`.
    {:ok, store: start_isolated_store()}
  end

  defp commit_doc(store, uuid, doc) do
    update = Yelixer.Encoding.encode_update(doc)
    CommitStore.create_commit(store, uuid, update, nil, %{})
  end

  test "elixir source content is classified as code", %{store: store} do
    doc = Doc.new() |> ContentType.create(:text, "_renderer.ex")
    doc = ContentType.insert_text(doc, 0, "defmodule Foo do\n  def x, do: 1\nend\n")
    uuid = "11111111-1111-1111-1111-111111111111"
    commit_doc(store, uuid, doc)
    assert CodeDocHeuristic.code_doc?(uuid, store)
  end

  test "plain prose text is NOT code", %{store: store} do
    doc = Doc.new() |> ContentType.create(:text, "notes")
    doc = ContentType.insert_text(doc, 0, "the quick brown fox, defmodule mentioned in prose")
    uuid = "22222222-2222-2222-2222-222222222222"
    commit_doc(store, uuid, doc)
    refute CodeDocHeuristic.code_doc?(uuid, store)
  end

  test "missing doc → not classifiable → false (best-effort)", %{store: store} do
    refute CodeDocHeuristic.code_doc?("00000000-0000-0000-0000-000000000000", store)
  end
end
```

- [ ] **Step 2: Run, verify it fails** — `mix test apps/commonplace/test/commonplace/trust/code_doc_heuristic_test.exs` → FAIL (module/function undefined). (Confirm the prose case `refute`s: the regex must anchor `defmodule` at line-start + a module name, not match the word in prose.)

- [ ] **Step 3: Implement**

```elixir
defmodule Commonplace.Trust.CodeDocHeuristic do
  @moduledoc """
  Best-effort, defense-in-depth classifier: does this doc UUID *look like*
  executable code or a process declaration? Used by the mint-time guard
  (CX-tdkq.28) to refuse a `:write`-without-`:execute` cert scoped to a code
  doc — closing the laundering INPUT.

  NOT airtight. The content-sniff misses non-`defmodule` code, view-XML /
  compute-spec docs, and remote/future docs not present locally. That is
  acceptable: the airtight backstop is the execute-clean Gate-B walk
  (CX-tdkq.27). A doc we can't reconstruct → `false` (can't prove it's code;
  the backstop covers a miss).
  """

  alias Commonplace.Document.ContentType
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.DocBuilder

  @doc "Best-effort: true if the doc at `uuid` content-sniffs as code / process-decl."
  @spec code_doc?(String.t(), GenServer.server()) :: boolean()
  def code_doc?(uuid, store \\ CommitStoreClient) when is_binary(uuid) do
    case safe_reconstruct(store, uuid) do
      {:ok, doc} -> classify(ContentType.get_content(doc))
      _ -> false
    end
  end

  defp safe_reconstruct(store, uuid) do
    DocBuilder.reconstruct_snapshot(store, uuid)
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  defp classify(content) when is_binary(content), do: elixir_source?(content) or process_decl_json?(content)
  defp classify(_), do: false

  # An Elixir source doc self-names with `defmodule X` — the SourceDoc.compile
  # vector. Anchor to line-start + a capitalized module head so prose mentioning
  # "defmodule" doesn't trip it.
  defp elixir_source?(content), do: Regex.match?(~r/^\s*defmodule\s+[A-Z]/m, content)

  # A `__processes.json` declaration is a JSON object of named process specs
  # (the Orchestrator's second execute ingress). Best-effort: parses as a
  # non-empty JSON map whose values are themselves maps (process specs).
  defp process_decl_json?(content) do
    case Jason.decode(content) do
      {:ok, map} when is_map(map) and map_size(map) > 0 -> Enum.all?(Map.values(map), &is_map/1)
      _ -> false
    end
  end
end
```

- [ ] **Step 4: Run, verify pass** — `mix test apps/commonplace/test/commonplace/trust/code_doc_heuristic_test.exs`

- [ ] **Step 5: Commit** — `git commit -m "feat(trust): best-effort code-doc heuristic for mint-time guard (CX-tdkq.28)"`

---

## Task 2 (.28): mint-time guard in `Capability.issue/5`

**Files:**
- Modify: `apps/commonplace/lib/commonplace/trust/capability.ex` (`issue/5` + a private `check_mint_policy/2`)
- Test: `apps/commonplace/test/commonplace/trust/capability_test.exs`

- [ ] **Step 1: Write the failing test** (add to existing file; reuse Task 1's store + `commit_doc` helper to seed a code doc at `code_uuid` and a plain doc at `data_uuid`; build `ctx` + `audience` as the existing capability tests do)

```elixir
describe "mint-time write-without-execute guard (CX-tdkq.28)" do
  test "refuses write-without-execute scoped to a code doc", %{store: s, code_uuid: c, ctx: ctx, audience: aud} do
    claim = %{verbs: [:write], scope: {:docs, [c]}, caveats: %{}}
    assert {:error, {:write_without_execute_on_code_doc, ^c}} =
             Capability.issue(ctx, aud, claim, nil, store: s)
  end

  test "allows write-without-execute on a non-code doc", %{store: s, data_uuid: d, ctx: ctx, audience: aud} do
    claim = %{verbs: [:write], scope: {:docs, [d]}, caveats: %{}}
    assert {:ok, _} = Capability.issue(ctx, aud, claim, nil, store: s)
  end

  test "allows write+execute on a code doc", %{store: s, code_uuid: c, ctx: ctx, audience: aud} do
    claim = %{verbs: [:write, :execute], scope: {:docs, [c]}, caveats: %{}}
    assert {:ok, _} = Capability.issue(ctx, aud, claim, nil, store: s)
  end

  test "override flag allows write-without-execute on a code doc", %{store: s, code_uuid: c, ctx: ctx, audience: aud} do
    claim = %{verbs: [:write], scope: {:docs, [c]}, caveats: %{}}
    assert {:ok, _} =
             Capability.issue(ctx, aud, claim, nil, store: s, allow_write_without_execute: true)
  end
end
```

- [ ] **Step 2: Run, verify it fails** — `mix test apps/commonplace/test/commonplace/trust/capability_test.exs` → FAIL (first test gets `{:ok, _}`).

- [ ] **Step 3: Implement** — thread the policy into `issue/5`:

```elixir
def issue(%SigningContext{} = issuer_ctx, audience, claim, parent_cid \\ nil, opts \\ []) do
  issuer = {issuer_ctx.identity_uuid, issuer_ctx.public_key}
  claim = normalize_claim(claim)

  with :ok <- check_mint_policy(claim, opts),
       :ok <- check_attenuation(claim, opts[:parent]) do
    cap = new(issuer, audience, claim, parent_cid) |> sign(issuer_ctx.private_key)
    {:ok, cap}
  end
end
```

Add the guard near `check_attenuation`:

```elixir
# CX-tdkq.28 — interim, defense-in-depth: refuse minting a :write-without-:execute
# cert scoped to a doc that *looks like* code (best-effort, CodeDocHeuristic). A
# write-only cert on a code doc is the LAUNDERING INPUT: a peer lands code bytes
# under :write that a later node-signed snapshot can absorb into the execute
# baseline. Closing it at mint stops the input; CX-tdkq.27 is the airtight backstop
# for when this heuristic misses. Override: opts[:allow_write_without_execute].
defp check_mint_policy(claim, opts) do
  verbs = MapSet.new(claim.verbs)
  write_without_execute? = MapSet.member?(verbs, :write) and not MapSet.member?(verbs, :execute)

  cond do
    not write_without_execute? -> :ok
    opts[:allow_write_without_execute] -> :ok
    true -> check_no_code_doc_in_scope(claim.scope, opts)
  end
end

defp check_no_code_doc_in_scope({:docs, uuids}, opts) do
  store = opts[:store] || Commonplace.Store.CommitStoreClient

  case Enum.find(uuids, &Commonplace.Trust.CodeDocHeuristic.code_doc?(&1, store)) do
    nil -> :ok
    uuid -> {:error, {:write_without_execute_on_code_doc, uuid}}
  end
end
```

`delegate/5` funnels through `issue/5`, so it inherits the guard. `opts` already carries `:parent`; `:store` and `:allow_write_without_execute` are additive.

- [ ] **Step 4: Run, verify pass** — `mix test apps/commonplace/test/commonplace/trust/capability_test.exs`, then the full trust + capability-store suites to confirm no existing write-only mint test regressed (existing tests pass random/no-store UUIDs → heuristic `false` → allowed): `mix test apps/commonplace/test/commonplace/trust apps/commonplace/test/commonplace/store/capability_envelope_test.exs apps/commonplace/test/commonplace/store/capability_store_test.exs`.

- [ ] **Step 5: Commit** — `git commit -m "feat(trust): mint-time write-without-execute guard on code docs (CX-tdkq.28)"`

---

## Task 3 (.28): `cap` CLI — override flag + store wiring

**Files:**
- Modify: `apps/commonplace_cli/lib/commonplace/cli/cap.ex`
- Test: existing cap CLI test if present (`parse_*`); else assert the new flag parses + forwards.

- [ ] **Step 1: Write the failing test** — assert `OptionParser` accepts `--allow-write-without-execute` and that `mint/2` forwards `store: CommitStoreClient` + the override into `Capability.issue`/`delegate`.

- [ ] **Step 2: Run, verify it fails.**

- [ ] **Step 3: Implement** — in `cap.ex`:
  - Add `allow_write_without_execute: :boolean` to the `OptionParser.parse` `strict:` list.
  - `mint_opts = [store: CommitStoreClient, allow_write_without_execute: !!opts[:allow_write_without_execute]]`.
  - `do_mint(:issue, ...)` → `Capability.issue(ctx, audience, claim, nil, mint_opts)`.
  - `do_mint(:delegate, ...)` → `Capability.delegate(ctx, audience, claim, parent_cid, [parent: parent] ++ mint_opts)`.
  - Add the flag to `usage/0`; on `{:error, {:write_without_execute_on_code_doc, uuid}}` print a stderr hint naming `--allow-write-without-execute`.

- [ ] **Step 4: Run, verify pass** — `mix test apps/commonplace_cli`.

- [ ] **Step 5: Commit** — `git commit -m "feat(cli): cap --allow-write-without-execute override + store wiring (CX-tdkq.28)"`

---

## Task 4 (.27): local `execute_clean` watermark-cache ops on CommitStore

**Files:**
- Modify: `apps/commonplace/lib/commonplace/store/commit_store.ex` (read via `resolve_db`; write via `handle_cast`; `flush` via `handle_call`)
- Modify: `apps/commonplace/lib/commonplace/store/commit_store_client.ex` (passthroughs)
- Test: `apps/commonplace/test/commonplace/store/commit_store_test.exs`

The cache is a **local, non-synced** derived verdict: `{:execute_clean, fp, commit_id} → bool`, `fp` a fingerprint of the trust config (so a config change invalidates old entries). It is NOT a commit and NOT part of any commit's bytes — federation/sync never reads or writes these keys.

- [ ] **Step 1: Write the failing test** — `put_execute_clean(store, fp, cid, true)`; then `get_execute_clean(store, fp, cid) == {:ok, true}`; a different `fp` or unknown `cid` → `:miss`; after `flush_execute_clean(store)`, `get` → `:miss`. (Use a `Process.sleep`-free sync: the `put` is a cast, so issue a trivial `get_db`/`flush` `call` afterward to barrier the cast before asserting `get`.)

- [ ] **Step 2: Run, verify it fails.**

- [ ] **Step 3: Implement** — in `commit_store.ex`:

```elixir
@doc "Read a cached execute-clean verdict (local, non-synced). Reads via resolve_db (no GenServer round-trip)."
@spec get_execute_clean(GenServer.server(), term(), binary()) :: {:ok, boolean()} | :miss
def get_execute_clean(server \\ __MODULE__, fp, commit_id) do
  case CubDB.get(resolve_db(server), {:execute_clean, fp, commit_id}) do
    nil -> :miss
    bool when is_boolean(bool) -> {:ok, bool}
  end
end

@doc "Cache an execute-clean verdict. Fire-and-forget cast — a lost write just means recompute next walk."
@spec put_execute_clean(GenServer.server(), term(), binary(), boolean()) :: :ok
def put_execute_clean(server \\ __MODULE__, fp, commit_id, bool) when is_boolean(bool) do
  GenServer.cast(server, {:put_execute_clean, fp, commit_id, bool})
end

@doc "Drop all execute-clean cache entries (e.g. on a trust-config change — CX-tdkq.21)."
def flush_execute_clean(server \\ __MODULE__), do: GenServer.call(server, :flush_execute_clean)
```

Handlers:

```elixir
@impl true
def handle_cast({:put_execute_clean, fp, commit_id, bool}, state) do
  CubDB.put(state.db, {:execute_clean, fp, commit_id}, bool)
  {:noreply, state}
end

@impl true
def handle_call(:flush_execute_clean, _from, state) do
  keys =
    CubDB.select(state.db)
    |> Stream.map(fn {k, _v} -> k end)
    |> Stream.filter(&match?({:execute_clean, _, _}, &1))
    |> Enum.to_list()

  if keys != [], do: CubDB.delete_multi(state.db, keys)
  {:reply, :ok, state}
end
```

(Filtering all keys keeps `flush` simple and order-agnostic; it's a rare op. If a tighter `min_key`/`max_key` bracket is preferred, verify it brackets the `{:execute_clean, _, _}` keyspace under Erlang term ordering first.) Add the three passthroughs in `commit_store_client.ex` mirroring the existing `commit_log`/`get_capability` style.

- [ ] **Step 4: Run, verify pass** — `mix test apps/commonplace/test/commonplace/store/commit_store_test.exs`.

- [ ] **Step 5: Commit** — `git commit -m "feat(store): local execute_clean watermark cache (CX-tdkq.27)"`

---

## Task 5 (.27): Gate-B walk — continue-default + cache read/backfill + moduledoc fix

**Files:**
- Modify: `apps/commonplace/lib/commonplace/trust.ex`
- Test: `apps/commonplace/test/commonplace/trust/execute_baseline_test.exs` (new)

- [ ] **Step 1: Write the failing tests** — strict config (`accept_unsigned: false`, a user identity pinned + node auto-trust). For an "untrusted-for-execute" contributor, sign with a key NOT in `trusted_identities` (under the flat allowlist, an untrusted signer fails `authorized?(:execute)` in strict mode):
  - **(a) laundering CLOSED**: chain `genesis → untrusted contributor → node-signed snapshot`; `authorized_to_execute?` = `{:error, {:untrusted_contributor, _, _}}`. The walk **continues past the snapshot** (cache miss), re-checks the untrusted commit, denies. **Core test.**
  - **(b) no bricking**: chain `genesis → trusted-exec contributor → node-signed snapshot` (all clean); `:ok` (continues to genesis, all authorized).
  - **(c) cache halt-optimization**: from (b), run `authorized_to_execute?` once (cold → backfills the snapshot `true`); barrier the cast; assert `get_execute_clean(store, fp, snapshot.id) == {:ok, true}`; a second run still `:ok`. Compute `fp` in the test the same way `trust.ex` does (`:erlang.phash2(cfg.trusted_identities)`).
  - **(d) deny backfills false**: from (a), after the walk + barrier, `get_execute_clean(store, fp, snapshot.id) == {:ok, false}`.
  - **(e) permissive fast-path**: `accept_unsigned: true, trusted_identities: %{}` → `:ok`, no cache writes (returns before the walk).

- [ ] **Step 2: Run, verify they fail** (current walk halts at *any* authorized snapshot, so (a) wrongly returns `:ok`).

- [ ] **Step 3: Implement** — replace `walk_contributors/3` with a cache-aware continue-default walk:

```elixir
def authorized_to_execute?(store, doc_uuid, cfg \\ nil) do
  cfg = cfg || config()

  if fully_permissive?(cfg) do
    :ok
  else
    log = Commonplace.Store.CommitStoreClient.commit_log(store, doc_uuid, limit: 10_000)
    walk(store, doc_uuid, log, cfg)
  end
end

defp fully_permissive?(cfg), do: cfg.accept_unsigned and cfg.trusted_identities == %{}

# Config fingerprint keys the cache so a trust-config change invalidates stale verdicts.
defp cfg_fingerprint(cfg), do: :erlang.phash2(cfg.trusted_identities)

# Walk contributors newest-first (append-only store ⇒ full pre-snapshot history is
# present, so an un-clean/legacy snapshot can be re-examined by CONTINUING — this is
# what closes the laundering path WITHOUT bricking legacy snapshots).
#   * genesis                         → halt :ok (synthetic, empty)
#   * snapshot, cache says clean=true → halt :ok (terminal baseline — the optimization)
#   * snapshot, cache miss/false      → CONTINUE; remember it for backfill
#   * any commit not :execute-authz   → halt :error (untrusted_contributor)
# On finish, backfill every CONTINUED-past snapshot: true if the walk ended :ok
# (everything below was clean), false if it ended :error (something below is dirty).
#
# Merges are NOT special-cased (see the merge-omission follow-up bead): the walk
# follows parent_id only, so a snapshot cached `true` above an unclean merge could be
# wrong until that bead traverses merge_parents. Latent — no write-without-execute
# contributor exists pre-phase-3, and .28 guards the input meanwhile.
defp walk(store, doc_uuid, log, cfg) do
  fp = cfg_fingerprint(cfg)

  {verdict, passed} =
    Enum.reduce_while(log, {:ok, []}, fn commit, {:ok, passed} ->
      cond do
        match?(%{metadata: %{kind: :genesis}}, commit) ->
          {:halt, {:ok, passed}}

        true ->
          case authorized?(commit, :execute, {:doc, doc_uuid}, cfg) do
            {:error, reason} ->
              {:halt, {{:error, {:untrusted_contributor, commit.id, reason}}, passed}}

            :ok ->
              if match?(%{metadata: %{kind: :snapshot}}, commit) do
                case Commonplace.Store.CommitStoreClient.get_execute_clean(store, fp, commit.id) do
                  {:ok, true} -> {:halt, {:ok, passed}}
                  _ -> {:cont, {:ok, [commit.id | passed]}}
                end
              else
                {:cont, {:ok, passed}}
              end
          end
      end
    end)

  clean? = verdict == :ok
  Enum.each(passed, &Commonplace.Store.CommitStoreClient.put_execute_clean(store, fp, &1, clean?))
  verdict
end
```

Delete the old `walk_contributors/3`. Rewrite the `authorized_to_execute?` moduledoc: replace "halts at the first passing `:snapshot`" + the stale "node-signed snapshot absorbs earlier write-only contributors … tracked in the follow-up bead" caveat with the continue-default + local-cache description, and note the merge-omission cache limitation. Also fix any **stale merge moduledoc** (in `trust.ex`, and the Gate-B comment block in `code/source_doc.ex` if it repeats it) claiming "merges unsigned → strict denies converged code docs" — false since 2.5 node-signs merges.

- [ ] **Step 4: Run, verify pass** — `mix test apps/commonplace/test/commonplace/trust apps/commonplace/test/commonplace/code`.

- [ ] **Step 5: Commit** — `git commit -m "feat(trust): execute-clean continue-default walk + local watermark cache closes laundering (CX-tdkq.27)"`

---

## Final verification

- [ ] `mix test apps/commonplace` (full core suite) green.
- [ ] `mix test apps/commonplace_cli` green.
- [ ] No compiler warnings (CI uses `--warnings-as-errors`): `mix compile --warnings-as-errors` from the umbrella root.
- [ ] Relay to the commonplace worker: close CX-tdkq.28 + .27; confirm the **merge-omission follow-up bead** is filed by commonplace-plan.

## Out of scope (follow-up bead — commonplace-plan files)

- The `merge_parents`-omission airtight fix: either traverse `merge_parents` in `walk/4` (and cache merge verdicts), or enforce the documented-not-enforced no-delta-merge-on-code-docs invariant. Until then, a snapshot cached `true` above an unclean merge can be wrong (noted in `.27`).
- Revocation-driven cache flush wiring (CX-tdkq.21 owns eviction; `flush_execute_clean/1` is provided for it to call; cfg-fingerprint keying already invalidates on config change).
- Halt-optimization warming for peer-imported snapshots at import time (currently warmed lazily on first local walk).
