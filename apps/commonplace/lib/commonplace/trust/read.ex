defmodule Commonplace.Trust.Read do
  @moduledoc """
  CX-sqb6 (read-scoping P1) — the principal-boundary READ verifier: the single
  gate every principal-facing view-doc read consults before serving. The
  `:read` sibling of the write gate (`Commonplace.Trust.authorized?/5` at the
  commit path) and the execute gate (`authorized_to_execute?` at the compile
  path) — three verbs, one cert-DAG backbone, three enforcement points.

  ## Decision (self-contained — never live mutable state)

      authorized?(principal, target_uuid, opts):
        visibility == :public   -> :ok         (short-circuit — NO read-regression)
        visibility == :capability_gated ->
          principal == owner     -> :ok         (self-read: your own view-doc)
          reader holds a valid,
          unrevoked :read cap
          over target             -> :ok
          else                    -> {:error, :read_denied}
        visibility absent/unknown -> :ok         (default public — no-regression)

  Judged ONLY from the target's CARRIED protected fields (`visibility` +
  `owner`, passed in by the caller) and the reader's PRESENTED credentials
  (`reader_pub` + `cert_cids`) — NEVER from live occupancy/presence or any
  other mutable world state (the `take.ex` presence-oracle lesson: a security
  gate that consults live state is race-/inference-exploitable).

  ## No-read-regression is the load-bearing safety

  `:public` is the default and the short-circuit. Every doc that does NOT opt
  into `:capability_gated` — the wiki, the curated world, shared rooms, every
  non-view-doc — reads exactly as it does today. Only view-docs
  (`Commonplace.MUD.SessionView`) are minted `:capability_gated` in P1.

  ## The audience-binding (anti-capability-theft) lives in `Trust.reader_authorized?`

  A read has no commit to sign, so instead of the write path's commit-author
  binding, the cap's audience is bound to the READER's authenticated key:
  `Trust.reader_authorized?` accepts a cap only when its audience pubkey ==
  the reader's `reader_pub`. 🔒 The caller MUST pass the reader's
  SERVER-RESOLVED identity key (session `SigningContext`), never a
  client-claimed value — otherwise the binding is meaningless.

  ## Two load-bearing CALLER contracts (self-containment holds only if honored)

  1. **`reader_pub` = the reader's SERVER-RESOLVED key** (above). Inc-5's
     cap-path caller must honor it; P1's live self-vs-owner path doesn't
     exercise the cap path yet.
  2. **`visibility`/`owner` = the TARGET's ACTUAL protected fields**, read from
     the doc's node-signed meta (`SessionView.read_meta/2` / `meta/1`), NEVER
     a client-influenced value. The verifier is only as self-contained as its
     inputs: feeding it a client-claimed `visibility: :public` would forge an
     allow. Every caller (MudLive today; Inc-5 + the P3 surfaces — MCP `cat`,
     GitBridge, wiki — later) MUST source these from the target's node-signed
     state.
  """

  alias Commonplace.Crypto.SigningContext
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Trust
  alias Commonplace.Trust.Capability

  @type scope :: {:docs, [String.t()]} | {:subtree, String.t()}

  @doc """
  Decide whether `principal_identity` (an identity_uuid, or `nil` for an
  unauthenticated principal) may READ `target_uuid`.

  `opts` (all CARRIED — self-contained):
    * `:visibility` — the target's protected visibility field
      (`:public | :capability_gated`); defaults `:public` (no-regression).
    * `:owner` — the target's protected owner identity_uuid (self-read check).
    * `:reader_pub` — the reader's SERVER-RESOLVED authenticated public key
      (for the audience binding). Never a client-claimed value.
    * `:cert_cids` — the read-caps the reader presents.
    * `:cfg` — trust config (defaults `Commonplace.Trust.config/0`).
    * `:store` — defaults `CommitStoreClient`.

  Returns `:ok` (allow) or `{:error, :read_denied}`.
  """
  @spec authorized?(String.t() | nil, String.t(), keyword()) :: :ok | {:error, term()}
  def authorized?(principal_identity, target_uuid, opts \\ []) when is_binary(target_uuid) do
    case Keyword.get(opts, :visibility, :public) do
      :capability_gated -> gated(principal_identity, target_uuid, opts)
      # :public, nil, or any unrecognized value → default public (no-regression).
      _public_or_absent -> :ok
    end
  end

  defp gated(principal_identity, target_uuid, opts) do
    owner = Keyword.get(opts, :owner)
    cfg = Keyword.get(opts, :cfg) || Trust.config()
    store = Keyword.get(opts, :store, CommitStoreClient)

    cond do
      is_binary(principal_identity) and principal_identity == owner ->
        :ok

      Trust.reader_authorized?(
        principal_identity,
        Keyword.get(opts, :reader_pub),
        Keyword.get(opts, :cert_cids, []),
        target_uuid,
        cfg,
        store
      ) ->
        :ok

      true ->
        {:error, :read_denied}
    end
  end

  @doc """
  Grant a `:read` capability over `scope` from `issuer_ctx` (the view-doc
  OWNER) to a spectator `audience` (`{identity_uuid, public_key}`), and persist
  it so the verifier can resolve it. Passing a target UUID retains the original
  shorthand for `{:docs, [target_uuid]}`. The read-side analog of a `:write`
  delegation; revocable via `Commonplace.Trust.Revocation`
  (CX-bepn), enforced verify-time by `verify_chain`.

  `opts`: `:store` (default `CommitStoreClient`), `:parent_cid` + `:parent`
  (for a delegated, not root, grant — passes attenuation checks).

  Returns `{:ok, capability}` (whose `.id` is the cid to present as a
  `cert_cid`) or `{:error, reason}`.
  """
  @spec grant(
          SigningContext.t(),
          String.t() | scope(),
          {String.t(), binary()},
          keyword()
        ) ::
          {:ok, Capability.t()} | {:error, term()}
  def grant(issuer_ctx, target_or_scope, audience, opts \\ [])

  def grant(%SigningContext{} = issuer_ctx, target_uuid, {_aud_id, _aud_pub} = audience, opts)
      when is_binary(target_uuid) do
    grant(issuer_ctx, {:docs, [target_uuid]}, audience, opts)
  end

  def grant(
        %SigningContext{} = issuer_ctx,
        {kind, value} = scope,
        {_aud_id, _aud_pub} = audience,
        opts
      )
      when (kind == :docs and is_list(value)) or (kind == :subtree and is_binary(value)) do
    store = Keyword.get(opts, :store, CommitStoreClient)
    claim = %{verbs: [:read], scope: scope}

    with {:ok, cap} <-
           Capability.issue(issuer_ctx, audience, claim, Keyword.get(opts, :parent_cid), opts) do
      CommitStoreClient.store_capability(store, cap)
      {:ok, cap}
    end
  end

  @doc """
  CX-73a3 (read-scoping P3) — the STANCE-AWARE read gate for the P3
  read-surface cohort (TreeLive/WikiLive content + sidebar enumeration,
  `@dump`, MCP `tail_red` / `invoke_view_action` / `tree://`, the `fork`
  source-check). Honors the `:local_read_gate` app-env — a SEPARATE knob
  from `:local_write_gate`, so read enforcement stages INDEPENDENTLY of the
  already-enforcing writes:

    * `:permissive` (default) — always `:ok`. Today's behavior; no-regression
      until the operator opts in (the P3 surfaces read exactly as before).
    * `:dry_run` — compute `authorized?/3`; on a would-deny, emit
      `[:commonplace, :trust, :read, :would_refuse]` telemetry (`surface`,
      `target`, `reader`, `visibility`) and RETURN `:ok` (still serve). The
      observe mode that proves the multi-surface wiring catches NO
      legitimate public read before the enforce flip.
    * `:enforce` — return `authorized?/3`'s verdict.

  ⚠️ This knob governs ONLY the P3 cohort. The live-proven P1/P2 gates
  (MudLive, `World.room_snapshot`, MCP `cat`, GitBridge) call
  `authorized?/3` DIRECTLY and are PINNED `:enforce` — the knob NEVER softens
  them (a global dry_run would re-open P2's private homes = a regression).
  Per-call-site stance, mirroring the write gate's `classify_verb_source`
  pin.

  `opts`: `:surface` (an atom naming the call-site, for the telemetry) plus
  all of `authorized?/3`'s (`visibility`/`owner`/`reader_pub`/`cert_cids`/
  `store`). The reader identity/pub MUST be SERVER-RESOLVED, never
  client-claimed (the P1 audience-binding).
  """
  @spec gate(String.t() | nil, String.t(), keyword()) :: :ok | {:error, term()}
  def gate(principal_identity, target_uuid, opts \\ []) when is_binary(target_uuid) do
    case Commonplace.Trust.local_read_gate() do
      :permissive ->
        :ok

      mode when mode in [:dry_run, :enforce] ->
        case authorized?(principal_identity, target_uuid, opts) do
          :ok ->
            :ok

          {:error, _} = denied ->
            if mode == :dry_run do
              emit_would_refuse(principal_identity, target_uuid, opts)
              :ok
            else
              denied
            end
        end
    end
  end

  defp emit_would_refuse(principal, target, opts) do
    :telemetry.execute(
      [:commonplace, :trust, :read, :would_refuse],
      %{count: 1},
      %{
        surface: Keyword.get(opts, :surface, :unknown),
        target: target,
        reader: principal,
        visibility: Keyword.get(opts, :visibility, :public)
      }
    )
  end
end
