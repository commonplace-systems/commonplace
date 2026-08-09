# BUILD BRIEF — `load_or_mint_keypair/0` mints a NEW node identity when the key file is merely missing

**For:** Sol (codex) · **Queue #3** (plan's ranking: decay + severity)
**Worktree:** `/home/jes/sol-mint/wt` · **branch:** `sol/mint-on-enoent`
**Run log:** `/home/jes/sol-mint/sol-run.log`

---

## 0. Environment contract (standing)

Named worktree off **current** `origin/main`; ⛔ leave changes **UNSTAGED**, no
`git add`, no commit, no push; ⛔ **no serve, no live store** — the live store is
`/home/jes/commonplace/workspace/.commonplace/commits/`, **process-derived, NOT
repo-root and NOT `data/`** (a stale decoy). ⚠️ **`mix deps.get` first.**

⚠️ **rc from the command itself, never through a pipe.** ⛔ **NO BARE ZEROS** —
any `0` arrives with a positive control that the pattern matches something.

## 1. The defect — at the trust root

`apps/commonplace/lib/commonplace/crypto/node_identity.ex:99`:

```elixir
case File.read(path) do
  {:ok, contents}    -> decode_keypair(contents)
  {:error, :enoent}  -> mint_keypair(data_dir, path)   # ⛔ THIS
  {:error, _} = err  -> err
end
```

⇒ **A missing key file is treated as "first boot" and silently mints a NEW node
identity.** ⚠️ **But "the file is missing" and "this node has never existed" are
different claims**, and only one of them justifies minting. A node whose key was
deleted, unmounted, masked, or pointed at the wrong `data_dir` **gets a fresh
identity and carries on**, signing with a key nothing has ever trusted.

⭐ **AND TODAY IT IS DEFUSED ONLY BY COINCIDENCE.** Sol's own fence masks the key
with `--ro-bind /dev/null`, so `File.read` **succeeds and returns empty** →
`decode_keypair("")` → `{:error, :corrupt_node_key}`. ⇒ **The `:enoent` branch is
never reached — by accident of how the mask was implemented.** ⚠️ **Change that
mask to a tmpfs or a deletion and the sandbox starts minting node identities.**
**That is protection by coincidence, and it is the whole reason this is ranked.**

## 2. The discriminator already exists — use it, do not invent one

`Commonplace.Store.CommitStore.prior_world_evidence?/1`
(`commit_store.ex:1260`) already answers *"has a world existed in this
data_dir?"*, and is already used for an analogous decision at `:1303`.

⇒ **Mint only when there is NO prior world. Otherwise refuse, loudly, naming
both facts** (key absent AND a prior world present).

⚠️ **Read `:1260` and `:1303` before writing anything** — if that helper's
notion of evidence does not fit this decision, **say so and stop rather than
bending it.** ⭐ *An ill-fitting reuse at the trust root is worse than a new
predicate.*

## 3. ⛔ Acceptance — three states, distinguishable, each demonstrated

| state | expected |
|---|---|
| key absent, **no** prior world | mints — this is genuine first boot |
| key absent, **prior world present** | ⛔ **REFUSES**, with an error naming both facts |
| key present | loads, unchanged |

1. ⭐ **RED-FIRST: show today's behaviour minting in the middle row**, on
   unmodified `main`, before your change. **Paste it.** ⛔ Without this the fix
   is unmotivated.
2. **All three rows demonstrated after the change**, each with the actual return
   value pasted.
3. ⭐ **The refusal must be DISTINGUISHABLE from `:corrupt_node_key`.** ⚠️ Today
   the fence produces the corrupt error for a *masked* key; a person debugging
   needs to know whether the key was unreadable or deliberately withheld.
4. ⛔ **Do NOT weaken the sandbox's current behaviour**: with the key masked by
   `--ro-bind /dev/null`, the result must still be an error, never a mint.
   **Demonstrate it under that exact mask.**
5. `mix compile --warnings-as-errors` rc=0, and — **baseline first, both
   numbers, one suite at a time:**
   - `apps/commonplace/test/commonplace/trust` — **210 tests, 0 failures on main**
     *(measured 2026-08-09 post-merge; 195/196/197/201/206 in older briefs are all stale)*
   - `apps/commonplace/test/commonplace/crypto` — **baseline it and report both.**

⚠️ `CommitHoistTest` is load-marginal and genuinely unrelated (CX-qzbh: a 10s
budget inside a 9.9–13.9s workload). One line if seen; move on.

## 4. ⛔ Out of scope — read together, change separately

- ⛔ **Do NOT fix the fixed-temp-filename race at `:129`.** It is **CX-37d9**,
  filed separately and deliberately. ⚠️ **It sits four lines from your edit and
  is the same bug that was just fixed on the public path at `:146`** — ⭐ **read
  it so you do not reintroduce it, and leave it alone.**
- ⛔ Do not change `public_key/0`, `public_keys/0`, or the artifact publishing
  that landed today.
- ⛔ Do not change what `Trust.config/0` or `anchor_keys/1` do.
- Any other defect: **one line, don't pursue it.**

## 5. What you cannot verify in-sandbox

- ⛔ Anything requiring the live serve — report **UNVERIFIED** and stop.
- ⚠️ **You genuinely CAN test this one**: the whole decision is a function of a
  `data_dir`'s contents, so build fixture directories. ⭐ **If you find yourself
  wanting the real node key, the scope has drifted — say so and stop.**
