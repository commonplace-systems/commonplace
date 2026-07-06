defmodule Commonplace.MUD.Sections do
  @moduledoc """
  Section ownership via capability certs (CX-qat5.4 Part A, the M2 demo
  bar). A "section" is just a set of room/object docs — this module is
  pure COMPOSITION over `Commonplace.Trust.Capability`: it mints and
  persists `[:write]`-scoped certs (never `:execute`) over a section's
  doc UUIDs, using the exact storage seam `Commonplace.CLI.Cap` uses
  (`CommitStoreClient.store_capability/2`) so a cert minted here and one
  minted via the `cap` CLI land in the same place and are interchangeable.

  ## Why never `:execute`

  The epic's security rider: a section owner gets editorial authority
  over a set of documents, never execute authority. `Capability.issue/5`
  already refuses to mint a `:write`-without-`:execute` cert scoped to a
  doc that content-sniffs as code (`check_no_code_doc_in_scope`) — this
  module adds a second, unconditional layer in front of that: any verb
  list containing `:execute` is refused outright, regardless of scope,
  because section ownership is never the seam that grants execute
  authority (that stays on the dedicated execute-capability path).

  ## Explicit store argument (the CX-ziye lesson)

  Every function takes an explicit `store` (default
  `Commonplace.Store.CommitStoreClient`) and threads it through to both
  the cert-store write (`CommitStoreClient.store_capability/2`) and the
  mint-time code-doc heuristic (`opts[:store]` on `Capability.issue/5`).
  CX-ziye found that a dropped store argument silently falls back to the
  default alias, which crashes (or silently misbehaves) on a named
  non-default store — never repeat that here.

  ## New-room cert coverage (CX-qat5.5)

  Digging/creating a room mints a fresh uuid no existing section cert
  lists in its scope — `auto_extend_for_new_room/3` is issuance
  automation that reissues a wider node-issued cert to close that gap
  on room-creation. It is a stopgap, not a scope mechanism: see its own
  doc for the security rules, and see Wrinkle-H subtree scopes
  (CX-tdkq.23) for the proper long-term fix (a section cert covering
  "everything under this dir" without ever reissuing).
  """

  alias Commonplace.Crypto.NodeIdentity
  alias Commonplace.Dataflow.PubSub, as: CPPubSub
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Trust.Capability

  require Logger

  @doc """
  Root/owner `issuer_ctx` issues `audience` a `[:write]`-scoped cert
  (unless `opts[:verbs]` overrides — e.g. `[:write, :delegate]` so the
  audience can itself delegate a subset of the section onward) over
  `section_uuids`. Mints, signs, and PERSISTS the cert via the same
  store path `Commonplace.CLI.Cap` uses. Returns `{:ok, cap}` or
  `{:error, reason}`.

  `opts`:
    * `:verbs` — default `[:write]`. MUST NOT contain `:execute` — hard
      rejected before any cert is minted.
    * `:ttl_seconds` — sets `claim.caveats.not_after` relative to now
      (nil = unbounded).
    * `:not_after` — explicit ABSOLUTE `caveats.not_after`; wins over
      `:ttl_seconds` if both are given (CX-qat5.5 — lets a reissue copy
      an existing cert's exact expiry instead of computing a new one).
    * `:not_before` — explicit `caveats.not_before` (default nil).
    * `:store` — default `CommitStoreClient`.
    * `:allow_write_without_execute` — forwarded to `Capability.issue/5`
      (the CX-tdkq.28 override; not needed for ordinary room docs).
  """
  @spec issue_section(
          Commonplace.Crypto.SigningContext.t(),
          Capability.keyed_identity(),
          [String.t()],
          keyword()
        ) :: {:ok, Capability.t()} | {:error, term()}
  def issue_section(issuer_ctx, audience, section_uuids, opts \\ [])
      when is_list(section_uuids) do
    store = Keyword.get(opts, :store, CommitStoreClient)
    verbs = Keyword.get(opts, :verbs, [:write])

    with :ok <- reject_execute(verbs),
         claim <- build_claim(verbs, section_uuids, opts),
         {:ok, cap} <- Capability.issue(issuer_ctx, audience, claim, nil, mint_opts(store, opts)),
         :ok <- CommitStoreClient.store_capability(store, cap) do
      {:ok, cap}
    end
  end

  @doc """
  `owner_ctx` (the audience of `parent_cap`, or a root issuer) delegates
  an ATTENUATED cert over `subset_uuids` to `audience`, chained off
  `opts[:parent]` (the parent `%Capability{}` struct — required).
  `Capability.attenuates?/2` must hold (subset verbs, subset scope,
  tighter-or-equal caveat window) — enforced at mint time by
  `Capability.delegate/5` via `opts[:parent]`; `verify_chain` re-checks
  it at every authorization walk.

  Same `opts` as `issue_section/4`, plus:
    * `:parent` — REQUIRED, the parent `%Capability{}` struct being
      attenuated.
  """
  @spec delegate_section(
          Commonplace.Crypto.SigningContext.t(),
          Capability.keyed_identity(),
          [String.t()],
          keyword()
        ) :: {:ok, Capability.t()} | {:error, term()}
  def delegate_section(owner_ctx, audience, subset_uuids, opts \\ [])
      when is_list(subset_uuids) do
    store = Keyword.get(opts, :store, CommitStoreClient)
    verbs = Keyword.get(opts, :verbs, [:write])

    with {:ok, parent} <- fetch_parent_opt(opts),
         :ok <- reject_execute(verbs),
         claim <- build_claim(verbs, subset_uuids, opts),
         mint_opts <- [parent: parent] ++ mint_opts(store, opts),
         {:ok, cap} <- Capability.delegate(owner_ctx, audience, claim, parent.id, mint_opts),
         :ok <- CommitStoreClient.store_capability(store, cap) do
      {:ok, cap}
    end
  end

  @doc """
  CX-qat5.5 — new-room cert coverage (auto-extend-on-create). Digging or
  creating a room mints a fresh `new_room_uuid` that NO existing section
  cert's scope lists yet (a cert's scope is a frozen uuid list captured
  at mint time) — without this, a section owner who just carved a room
  can't write to the room they own. This is issuance AUTOMATION, not a
  scope mechanism; the proper fix is Wrinkle-H subtree scopes
  (CX-tdkq.23), which would make a section cert cover "everything under
  this dir" without ever reissuing. Until that lands, this composes over
  `issue_section/4` to mint a fresh, wider, superset cert.

  Call with `context_room_uuid` = the room the player was standing in /
  digging from. Pass `nil` (or omit — see 3rd clause) for a disconnected
  room with no section context: this is a no-op, `{:ok, :no_context}`.

  ## Security-relevant rules (do not loosen without a design review)

  1. **Node-issued only.** Only certs whose ISSUER is this node's own
     identity (`Commonplace.Crypto.NodeIdentity`, matched on the FULL
     issuer tuple — uuid AND pubkey, matching `Capability`'s own
     full-pubkey-binding discipline) are candidates — the node may
     reissue a grant it minted itself. A section cert issued by any
     other principal is NEVER auto-extended (that would be the node
     escalating someone else's grant): instead this emits
     `{:trust, :section_extend_skipped, %{cap_id: cid, new_uuid: new_room_uuid, reason: :non_node_issuer}}`
     on the new room's red topic and logs a warning, so the owner knows
     to extend manually.
  2. **Root certs only — never delegations.** A cert with `proof != nil`
     is an attenuated delegation; its scope stays exactly what its
     issuer granted. This module never widens a delegation, even one
     chained from a node-issued root.
  3. **Context anchors the inference.** `context_room_uuid` must be in
     the candidate cert's scope — the caller is only auto-extended for
     the section they were demonstrably standing in when they dug/built.
     A `nil` context short-circuits to `{:ok, :no_context}` before any
     lookup.

  ## Reissue mechanics

  A match mints a fresh node-issued ROOT cert (`issue_section/4`) with
  the SAME audience and verbs, the SAME `not_before`/`not_after` caveat
  window copied VERBATIM from the old cert (never extended — a reissue
  preserves the original grant's lifetime, it does not renew it), and
  `scope = old_scope ++ [new_room_uuid]`. The old (narrower) cert is
  left untouched — there is no revocation mechanism yet (CX-bepn), so it
  stays valid; the new cert is a pure superset, so the redundancy is
  harmless.

  ## Candidate discovery (the enumeration gap — read before extending)

  The capability store only exposes **get-by-CID**
  (`CommitStoreClient.get_capability/2`); there is no "certs whose scope
  contains uuid X" index, and building one would be a substrate change
  (out of scope here — flagged in the CX-qat5.5 completion report,
  recommend folding into the Wrinkle-H (CX-tdkq.23) subtree-scope work).
  Instead this walks `context_room_uuid`'s own commit log
  (`CommitStoreClient.commit_log/3`) for `metadata.capability_proof`
  CIDs — i.e. certs that have ALREADY been used to author at least one
  commit on the context room — and resolves each via `get_capability/2`.
  **Blind spot:** a section cert that covers `context_room_uuid` but has
  never yet authored a commit there is invisible to this discovery and
  will silently not be auto-extended (no event fires — this is a
  discovery miss, not a policy skip). In practice the owner's own
  section-founding commit (or any subsequent edit) already exercises the
  cert on every room in the section, so this covers the steady-state
  case; it is not a substitute for a real scope index.

  `opts`:
    * `:store` — default `CommitStoreClient`.

  Returns `{:ok, :no_context}` (no context room), or `{:ok, results}`
  where `results` is a list of one tagged tuple per candidate cert found:
  `{:reissued, old_cap_id, new_cap}`, `{:skipped, old_cap_id, :delegation | :non_node_issuer | :already_covered}`,
  or `{:error, old_cap_id, reason}`. `{:error, reason}` (untagged) only
  when the node's own identity/signing context is unavailable.
  """
  @spec auto_extend_for_new_room(String.t(), String.t() | nil, keyword()) ::
          {:ok, :no_context | [tuple()]} | {:error, term()}
  def auto_extend_for_new_room(new_room_uuid, context_room_uuid, opts \\ [])

  def auto_extend_for_new_room(_new_room_uuid, nil, _opts), do: {:ok, :no_context}

  def auto_extend_for_new_room(new_room_uuid, context_room_uuid, opts)
      when is_binary(new_room_uuid) and is_binary(context_room_uuid) do
    store = Keyword.get(opts, :store, CommitStoreClient)

    with {:ok, node_identity} <- NodeIdentity.identity(),
         {:ok, node_pub} <- NodeIdentity.public_key() do
      results =
        context_room_uuid
        |> candidate_certs(store)
        |> Enum.map(
          &handle_candidate(&1, new_room_uuid, context_room_uuid, {node_identity, node_pub}, store)
        )

      {:ok, results}
    else
      {:error, reason} -> {:error, {:node_identity_unavailable, reason}}
    end
  end

  # --- private (auto-extend) ---

  defp candidate_certs(context_room_uuid, store) do
    store
    |> CommitStoreClient.commit_log(context_room_uuid, limit: 10_000)
    |> Enum.map(&get_in(&1.metadata, [:capability_proof]))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.flat_map(fn cid ->
      case CommitStoreClient.get_capability(store, cid) do
        {:ok, cap} -> [cap]
        :none -> []
      end
    end)
  end

  defp handle_candidate(cap, new_room_uuid, context_room_uuid, node_issuer, store) do
    cond do
      cap.proof != nil ->
        {:skipped, cap.id, :delegation}

      cap.issuer != node_issuer ->
        emit_extend_skipped(context_room_uuid, cap, new_room_uuid)
        {:skipped, cap.id, :non_node_issuer}

      new_room_uuid in scope_uuids(cap) ->
        {:skipped, cap.id, :already_covered}

      true ->
        reissue(cap, new_room_uuid, store)
    end
  end

  defp scope_uuids(%Capability{claim: %{scope: {:docs, uuids}}}), do: uuids

  defp reissue(cap, new_room_uuid, store) do
    new_scope = scope_uuids(cap) ++ [new_room_uuid]
    caveats = cap.claim.caveats

    case NodeIdentity.signing_context() do
      {:ok, node_ctx} ->
        case issue_section(node_ctx, cap.audience, new_scope,
               store: store,
               verbs: cap.claim.verbs,
               not_before: caveats.not_before,
               not_after: caveats.not_after
             ) do
          {:ok, new_cap} -> {:reissued, cap.id, new_cap}
          {:error, reason} -> {:error, cap.id, reason}
        end

      {:error, reason} ->
        {:error, cap.id, {:node_signing_context_unavailable, reason}}
    end
  end

  defp emit_extend_skipped(context_room_uuid, cap, new_room_uuid) do
    meta = %{cap_id: cap.id, new_uuid: new_room_uuid, reason: :non_node_issuer}

    Logger.warning(
      "Commonplace.MUD.Sections: section cert #{inspect(cap.id)} covering room " <>
        "#{context_room_uuid} was NOT auto-extended to new room #{new_room_uuid} — " <>
        "issuer is not this node's identity; extend manually."
    )

    CPPubSub.broadcast_red(new_room_uuid, {:trust, :section_extend_skipped, meta})
  end

  # --- private ---

  defp reject_execute(verbs) do
    if :execute in verbs,
      do: {:error, :execute_forbidden_in_section_cert},
      else: :ok
  end

  defp build_claim(verbs, uuids, opts) do
    not_after =
      case Keyword.fetch(opts, :not_after) do
        # CX-qat5.5: an explicit absolute `:not_after` (e.g. copied
        # verbatim from a cert being reissued with a wider scope) wins
        # over `:ttl_seconds`'s relative-to-now computation — reissue
        # must preserve the ORIGINAL window, never grant a fresh one.
        {:ok, explicit} ->
          explicit

        :error ->
          case Keyword.get(opts, :ttl_seconds) do
            nil -> nil
            ttl when is_integer(ttl) -> DateTime.add(DateTime.utc_now(), ttl, :second)
          end
      end

    %{
      verbs: verbs,
      scope: {:docs, uuids},
      caveats: %{not_before: Keyword.get(opts, :not_before), not_after: not_after}
    }
  end

  defp mint_opts(store, opts) do
    [store: store, allow_write_without_execute: !!opts[:allow_write_without_execute]]
  end

  defp fetch_parent_opt(opts) do
    case Keyword.get(opts, :parent) do
      %Capability{} = parent -> {:ok, parent}
      _ -> {:error, :missing_parent_capability}
    end
  end
end
