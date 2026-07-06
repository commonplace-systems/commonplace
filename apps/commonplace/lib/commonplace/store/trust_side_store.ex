defmodule Commonplace.Store.TrustSideStore do
  @moduledoc """
  R4c carve-out: the capability-cert store and the execute_clean watermark
  cache, extracted out of `Commonplace.Store.CommitStore`'s GenServer state
  (CX-tdkq.22b / CX-tdkq.27). Owns two row families in the SAME CubDB
  database CommitStore uses — the db handle is obtained via
  `Commonplace.Store.CommitStore.db_handle/1` at `init/1` (persistent_term
  based, no ongoing coupling beyond that one read).

  This module holds two clearly separate facade groups, each documented
  below as its own splittable unit — if either grows enough to warrant its
  own process, it can be lifted out without touching the other.

  ## Direct handle-read license (read this before adding a third row family)

  `get_capability/2` and `get_execute_clean/3` read the CubDB handle
  directly in the CALLING process (no `GenServer.call` into this store's
  mailbox) — the same pattern `CommitStore.get_capability/2` /
  `CommitStore.get_execute_clean/3` used before this carve-out, and the
  same pattern `CommitStore.get_commit/2` etc. still use (R4(a), CX-tdkq.4).
  This is licensed ONLY because of what's true of *these specific* row
  shapes:

    * Capability rows (`{:capability, cid}`) are immutable and
      content-addressed — a cert is written once under its CID and never
      changes; a stale read is impossible, only a "not yet written" read.
    * Execute_clean rows (`{:execute_clean, fp, commit_id}`) are
      last-write-wins booleans keyed by a trust-config fingerprint — a
      config change simply invalidates the whole namespace of keys under
      the OLD fingerprint (they're never read again), so there is no
      "torn write" a direct reader could observe as wrong. Gate B's
      continue-default already tolerates a stale/absent read by re-walking
      history.

  ## The revocation group is the licensed FOURTH family (CX-bepn)

  `{:revocation, revoked_cid}` (a list of `Commonplace.Trust.Revocation`
  records — multiple revokers per cert allowed) and the single
  `{:revocation_meta, :set_hash}` watermark row are also direct
  point-reads. Unlike the capability row, a `{:revocation, cid}` row IS
  mutated in place (new revokers append to the list) — but every mutation
  goes through `store_revocation/2`'s `GenServer.call`, which reads,
  appends, and writes both the row AND the `:set_hash` watermark in ONE
  `CubDB.put_multi/2` (atomic within CubDB). A direct reader therefore
  never observes a torn write, only "before this append" or "after it" —
  the same "last-write-wins, no torn state" property that licenses
  `execute_clean`. Design doc
  docs/plans/2026-07-06-capability-revocation-design.md §1/§4 is explicit
  that there is NO global in-memory revocation set — every consult of
  "is this cert revoked" is a per-link CubDB get against the THREADED
  store (never a bare default-store read — see CX-ziye's store-threading
  rule, which is exactly the bug shape a global set would reintroduce).

  Anyone adding a FIFTH row family to this store that does NOT fit either
  the immutable-by-CID pattern or the atomically-multi-put
  last-write-wins pattern must NOT assume this same direct-read license
  extends to it — that kind of row needs to go through a `GenServer.call`
  for a consistent read, same as any other mutable state.
  """

  use GenServer

  alias Commonplace.Store.CommitStore

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  # ── Capability group (CX-tdkq.22b) ──────────────────────────────────────
  #
  # A capability cert is the immutable trust VALUE, content-addressed by
  # its CID — not a CRDT doc, never merged. This group is a self-contained
  # facade over the `{:capability, cid}` row family; it could be split into
  # its own module/process later without touching the ExecuteClean group.

  @doc """
  Persist a capability cert. Content-addressed by its CID; idempotent (a
  re-put of the same CID overwrites identical bytes). Routes through
  `GenServer.call` to serialize the write with any concurrent writer AND to
  guarantee the row is durable (CubDB.put has returned) before this
  function notifies `Commonplace.Store.PendingImports` that a commit
  deferred with `:awaiting_capability` might now be unblocked.
  """
  def store_capability(server \\ __MODULE__, %Commonplace.Trust.Capability{} = cap) do
    GenServer.call(server, {:store_capability, cap})
  end

  @doc """
  Fetch a capability cert by CID. Returns `{:ok, cap}` or `:none`. Direct
  point-read in the caller process — see the moduledoc's "Direct
  handle-read license" section for why this is safe for this row shape.
  """
  def get_capability(server \\ __MODULE__, cid) do
    case CubDB.get(resolve_db(server), {:capability, cid}) do
      nil -> :none
      cap -> {:ok, cap}
    end
  end

  # ── ExecuteClean group (CX-tdkq.27) ─────────────────────────────────────
  #
  # A node-LOCAL, NON-SYNCED derived verdict cache: "is the chain ending at
  # this snapshot/commit execute-clean under the trust config fingerprinted
  # by `fp`?" NOT a commit, NOT part of any commit's content address —
  # federation never touches these keys. This group is a self-contained
  # facade over the `{:execute_clean, fp, commit_id}` row family.

  @doc """
  Read a cached execute-clean verdict. `{:ok, boolean}` or `:miss`. Direct
  point-read in the caller process — see the moduledoc's "Direct
  handle-read license" section for why this is safe for this row shape.
  """
  def get_execute_clean(server \\ __MODULE__, fp, commit_id) do
    case CubDB.get(resolve_db(server), {:execute_clean, fp, commit_id}) do
      nil -> :miss
      bool when is_boolean(bool) -> {:ok, bool}
    end
  end

  @doc """
  Cache an execute-clean verdict. Fire-and-forget cast — a lost write just
  means the verdict is recomputed on the next walk, so the compile hot
  path never blocks on cache I/O.
  """
  def put_execute_clean(server \\ __MODULE__, fp, commit_id, bool) when is_boolean(bool) do
    GenServer.cast(server, {:put_execute_clean, fp, commit_id, bool})
  end

  # ── Revocation group (CX-bepn) ──────────────────────────────────────────
  #
  # A revocation record is a content-addressed, signed statement that a
  # capability cert is void (design doc §1). Storage mirrors the
  # capability group's "durable row beside the capability rows" home;
  # the `:set_hash` watermark row is the §4 fold-in point that lets
  # `Commonplace.Trust`'s execute-clean cache self-invalidate on a new
  # revocation without ever needing a global in-memory set.

  @doc """
  Persist a revocation record (idempotent by id — re-storing the same
  revoker's revocation of the same cert is a no-op). Routes through
  `GenServer.call` so the `{:revocation, cid}` row and the
  `{:revocation_meta, :set_hash}` watermark update atomically in the
  SAME write — the watermark must never observe "revocation stored" and
  "hash bumped" as separable states, or a concurrent `cfg_fingerprint`
  read could compute a fingerprint that a subsequent revocation, sharing
  that same fingerprint, would fail to invalidate.
  """
  def store_revocation(server \\ __MODULE__, %Commonplace.Trust.Revocation{} = rev) do
    GenServer.call(server, {:store_revocation, rev})
  end

  @doc """
  Fetch every revocation record filed against `revoked_cid` (possibly
  from multiple revokers). `[]` if none. Direct point-read in the caller
  process — see the moduledoc's "the revocation group is the licensed
  FOURTH family" section for why this is safe for this row shape.
  """
  def get_revocations(server \\ __MODULE__, revoked_cid) do
    case CubDB.get(resolve_db(server), {:revocation, revoked_cid}) do
      nil -> []
      list -> list
    end
  end

  @doc """
  The per-store revocation-set watermark (design §4): an opaque integer
  that changes whenever ANY revocation is newly stored in THIS store.
  Folded into `Commonplace.Trust`'s `cfg_fingerprint`, so a revocation
  self-invalidates every execute-clean verdict cached under the old
  fingerprint. `0` if this store has never stored a revocation.
  """
  def revocation_set_hash(server \\ __MODULE__) do
    case CubDB.get(resolve_db(server), {:revocation_meta, :set_hash}) do
      nil -> 0
      hash -> hash
    end
  end

  @doc """
  Drop every execute-clean cache entry (e.g. on a trust-config change —
  CX-tdkq.21). Synchronous `GenServer.call` — callers need the guarantee
  that stale verdicts are wiped before this returns (no timing race with
  the next `get_execute_clean/3`).
  """
  def flush_execute_clean(server \\ __MODULE__), do: GenServer.call(server, :flush_execute_clean)

  # ── GenServer callbacks ──────────────────────────────────────────────────

  @impl true
  def init(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    commit_store = Keyword.get(opts, :commit_store, CommitStore)
    pending_imports = Keyword.get(opts, :pending_imports, Commonplace.Store.PendingImports)

    db = CommitStore.db_handle(commit_store)
    :persistent_term.put({__MODULE__, :db, name}, db)

    {:ok, %{db: db, name: name, commit_store: commit_store, pending_imports: pending_imports}}
  end

  @impl true
  def terminate(_reason, %{name: name}) do
    :persistent_term.erase({__MODULE__, :db, name})
    :ok
  end

  def terminate(_reason, _state), do: :ok

  @impl true
  def handle_call({:store_capability, cap}, _from, state) do
    # CX-tdkq.22b: a cert is a content-addressed immutable VALUE, keyed by
    # its CID (mirrors the attestation store). Idempotent — same CID
    # overwrites identical bytes. No head pointer: certs are referenced by
    # CID (from a commit's metadata / a child cert's proof), not "latest".
    CubDB.put(state.db, {:capability, cap.id}, cap)

    # CX-tdkq.22e: a landed cert may be exactly what a commit deferred with
    # :awaiting_capability was waiting on. Cast AFTER the put returns, so
    # the row is durable before any retry reads it. Fire-and-forget — a
    # dropped cast only delays the retry (PendingImports' periodic sweep is
    # the liveness backstop), it never wedges it.
    GenServer.cast(state.pending_imports, {:notify_capability, cap.id})

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:store_revocation, %Commonplace.Trust.Revocation{} = rev}, _from, state) do
    existing = CubDB.get(state.db, {:revocation, rev.revoked_cid}) || []

    if Enum.any?(existing, &(&1.id == rev.id)) do
      # Content-addressed dedupe: the same revoker revoking the same cert
      # again is a no-op — no new row, no watermark bump (idempotent,
      # mirrors store_capability's re-put-of-identical-bytes behavior).
      {:reply, :ok, state}
    else
      updated = [rev | existing]
      old_hash = CubDB.get(state.db, {:revocation_meta, :set_hash}) || 0
      new_hash = :erlang.phash2({old_hash, rev.id})

      # Atomic: the row and the watermark land in the SAME put_multi, so
      # no reader can observe one without the other (§4's load-bearing
      # requirement — see moduledoc).
      CubDB.put_multi(state.db, [
        {{:revocation, rev.revoked_cid}, updated},
        {{:revocation_meta, :set_hash}, new_hash}
      ])

      :telemetry.execute(
        [:commonplace, :trust, :revocation, :stored],
        %{set_size: length(updated)},
        %{revoked_cid: rev.revoked_cid}
      )

      {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call(:flush_execute_clean, _from, state) do
    keys =
      CubDB.select(state.db)
      |> Stream.map(fn {k, _v} -> k end)
      |> Stream.filter(&match?({:execute_clean, _, _}, &1))
      |> Enum.to_list()

    Enum.each(keys, &CubDB.delete(state.db, &1))
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:get_db, _from, state) do
    {:reply, state.db, state}
  end

  @impl true
  def handle_cast({:put_execute_clean, fp, commit_id, bool}, state) do
    CubDB.put(state.db, {:execute_clean, fp, commit_id}, bool)
    {:noreply, state}
  end

  defp resolve_db(server) do
    case :persistent_term.get({__MODULE__, :db, server}, nil) do
      nil -> GenServer.call(server, :get_db)
      db -> db
    end
  end
end
