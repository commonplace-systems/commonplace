defmodule Commonplace.Trust.VerifyChain do
  @moduledoc """
  The capability chain verifier (CX-tdkq.22c, phase 3).

  `verify_chain(leaf_cid, anchor_keys, store)` walks a delegation chain
  from the leaf cert back to a root, returning the **effective**
  (intersected) capability, or `{:error, reason}`. It mirrors the shape
  of `Commonplace.Trust.authorized_to_execute?`'s reduce: a sequence of
  independent checks that short-circuit on the first failure.

  Per cert: content address matches the CID (`verify_id`), signature
  verifies against the cert's own issuer pubkey (`verify_sig`), and the
  caveat window contains `now`.

  Per delegation link (`child` → `parent`):
    * **full-pubkey key-link** — `child.issuer.pubkey == parent.audience.pubkey`
      (exact 32 bytes; the 8-char fingerprint is second-preimage forgeable);
    * **`:delegate` on the parent** — a cert that authorized a child must
      itself grant `:delegate` (the leaf need not);
    * **monotonic narrowing** — `child.claim` attenuates `parent.claim`
      (`Capability.attenuates?`, the same predicate enforced at mint).

  Root: the root cert (`proof == nil`) must be issued by a key in
  `anchor_keys` (full pubkey — the locally-pinned trust anchors).

  Effective capability = intersection down the chain (∩verbs, ∩scope,
  tightest caveat window). Because narrowing is enforced this equals the
  leaf's claim, but it is computed explicitly so the returned capability
  is honest regardless.

  ## Revocation (CX-bepn, design §1/§3/§7.6)

  Per chain link, `check_revocations/2` consults every revocation record
  filed against that link's cert CID — a per-link CubDB get against the
  THREADED `store`, never a global in-memory set (design §1: the CX-ziye
  bug shape reborn, cross-store spurious-grant/deny). ANY link revoked
  by an AUTHORIZED revoker is a terminal `{:error, :revoked}` —
  transitivity is free-by-construction (a chain THROUGH a revoked link
  denies without any extra code).

  Revoker AUTHORITY (§2) is validated HERE, at verify time, per link —
  never at revocation import/arrival (`Commonplace.Trust.Revocation`'s
  moduledoc has the full rationale: federation makes no ordering
  promise, and an early-arriving revocation's authority can't be checked
  before its target cert's chain is known). A revoker is authorized for
  cert `chain[k]` iff its pubkey is either (a) the issuer of `chain[k]`
  itself or any of its ancestors (`chain[k..-1]`'s issuers — "root or any
  ancestor delegator"), or (b) `chain[k]`'s own audience (self-
  renunciation). An unauthorized (stranger) revocation record is
  naturally inert — it simply never matches — but is counted via a
  `[:commonplace, :trust, :revocation, :ignored]` telemetry event so a
  stranger-record flood is visible.
  """

  alias Commonplace.Store.CommitStore
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Trust.Capability

  @max_depth 64

  @type effective :: %{verbs: [atom()], scope: Capability.scope(), caveats: map()}

  @spec verify_chain(binary(), MapSet.t(), GenServer.server()) ::
          {:ok, effective()} | {:error, atom()}
  def verify_chain(leaf_cid, anchor_keys, store \\ CommitStore) do
    with {:ok, chain} <- build_chain(leaf_cid, store),
         :ok <- check_each_cert(chain),
         :ok <- check_links(chain),
         :ok <- check_root(List.last(chain), anchor_keys),
         :ok <- check_revocations(chain, store),
         {:ok, eff} <- effective(chain) do
      {:ok, eff}
    end
  end

  # --- chain assembly (leaf → root) ---

  defp build_chain(cid, store), do: build_chain(cid, store, [], 0)

  defp build_chain(_cid, _store, _acc, depth) when depth >= @max_depth,
    do: {:error, :chain_too_deep}

  defp build_chain(cid, store, acc, depth) do
    case CommitStoreClient.get_capability(store, cid) do
      :none ->
        {:error, :awaiting_capability}

      {:ok, cap} ->
        acc = [cap | acc]

        case cap.proof do
          nil -> {:ok, Enum.reverse(acc)}
          parent_cid -> build_chain(parent_cid, store, acc, depth + 1)
        end
    end
  end

  # --- per-cert checks ---

  defp check_each_cert(chain) do
    now = DateTime.utc_now()

    Enum.reduce_while(chain, :ok, fn cap, :ok ->
      with :ok <- Capability.verify_id(cap) |> tag(:id_mismatch),
           :ok <- Capability.verify_sig(cap),
           :ok <- within_window(cap.claim.caveats, now) do
        {:cont, :ok}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp tag(:ok, _), do: :ok
  defp tag({:error, {:id_mismatch, _, _}}, atom), do: {:error, atom}
  defp tag({:error, _} = e, _), do: e

  defp within_window(%{not_before: nb, not_after: na}, now) do
    cond do
      nb && DateTime.compare(now, nb) == :lt -> {:error, :not_yet_valid}
      na && DateTime.compare(now, na) == :gt -> {:error, :expired}
      true -> :ok
    end
  end

  # --- per-link checks (child → parent) ---

  defp check_links([_root]), do: :ok
  defp check_links([]), do: :ok

  defp check_links(chain) do
    chain
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.reduce_while(:ok, fn [child, parent], :ok ->
      with :ok <- key_link(child, parent),
           :ok <- delegation_allowed(parent),
           :ok <- narrowing(child, parent) do
        {:cont, :ok}
      else
        {:error, _} = e -> {:halt, e}
      end
    end)
  end

  defp key_link(%{issuer: {_, child_pub}}, %{audience: {_, parent_pub}}) do
    if child_pub == parent_pub, do: :ok, else: {:error, :broken_key_link}
  end

  defp delegation_allowed(%{claim: %{verbs: verbs}}) do
    if :delegate in verbs, do: :ok, else: {:error, :delegation_not_permitted}
  end

  defp narrowing(child, parent) do
    if Capability.attenuates?(child.claim, parent.claim),
      do: :ok,
      else: {:error, :not_attenuation}
  end

  # --- revocation (CX-bepn, design §1/§3/§7.6) ---
  #
  # Per link, terminal `:revoked` if ANY revocation record filed against
  # that cert's CID is signed by a pubkey authorized over that cert (§2).
  # Store-threaded (CommitStoreClient.get_revocations/2, never a bare
  # default-store read) — design §1's no-in-memory-set, per-store rule.

  defp check_revocations(chain, store) do
    Enum.reduce_while(chain, :ok, fn cap, :ok ->
      case CommitStoreClient.get_revocations(store, cap.id) do
        [] ->
          {:cont, :ok}

        revocations ->
          authorized_keys = revocation_authority_keys(cap, chain)

          if Enum.any?(revocations, &authorized_revoker?(&1, authorized_keys, cap)) do
            {:halt, {:error, :revoked}}
          else
            {:cont, :ok}
          end
      end
    end)
  end

  defp authorized_revoker?(rev, authorized_keys, cap) do
    # Defense in depth (Fable review): re-verify the record's OWN
    # integrity here, not just path-membership of its DECLARED
    # revoker_pubkey. Every current ingress (envelope import, cap CLI)
    # verifies id+sig before storing, but on a mechanism where a record
    # IS authority the verifier must be self-contained — a forged
    # record reaching the store through any future unverified path
    # would otherwise revoke arbitrary certs without holding the
    # revoker's key. Cost: one Ed25519 verify per record, only on a
    # revoked-cid hit (rare by design).
    with true <- MapSet.member?(authorized_keys, rev.revoker_pubkey),
         :ok <- Commonplace.Trust.Revocation.verify_id(rev),
         :ok <- Commonplace.Trust.Revocation.verify_sig(rev) do
      true
    else
      _ ->
        :telemetry.execute(
          [:commonplace, :trust, :revocation, :ignored],
          %{system_time: System.system_time()},
          %{cap_id: cap.id, revoker_pubkey: rev.revoker_pubkey}
        )

        false
    end
  end

  # §2: authorized revokers for `cap` are (a) the issuer of `cap` itself
  # or any of its ancestors in `chain` (the suffix from `cap` to root —
  # "root or any ancestor delegator"), or (b) `cap`'s own audience
  # (self-renunciation, e.g. a compromised-key holder revoking their own
  # cert). Computed offline from the already-built chain — no new
  # lookups, per the moduledoc.
  defp revocation_authority_keys(cap, chain) do
    {_before, [^cap | ancestors]} = Enum.split_while(chain, &(&1.id != cap.id))

    issuer_keys =
      [cap | ancestors]
      |> Enum.map(fn %{issuer: {_uuid, pubkey}} -> pubkey end)
      |> MapSet.new()

    {_uuid, audience_pubkey} = cap.audience
    MapSet.put(issuer_keys, audience_pubkey)
  end

  # --- root anchor ---

  defp check_root(%{issuer: {_, root_pub}}, anchor_keys) do
    if MapSet.member?(anchor_keys, root_pub), do: :ok, else: {:error, :untrusted_root}
  end

  # --- effective capability ---

  defp effective(chain) do
    claims = Enum.map(chain, & &1.claim)

    verbs =
      claims
      |> Enum.map(&MapSet.new(&1.verbs))
      |> Enum.reduce(&MapSet.intersection/2)
      |> Enum.sort()

    case combine_scope(claims) do
      {:ok, scope} -> {:ok, %{verbs: verbs, scope: scope, caveats: tightest_window(claims)}}
      {:error, _} = err -> err
    end
  end

  # CX-0a9a (presence-carve, W2): combine by scope TYPE, not by treating
  # every scope as {:docs}. All-{:docs} keeps the exact prior
  # intersection behavior (byte-identical for every existing {:docs}
  # caller). All-{:presence, id} with a SINGLE shared id collapses to
  # that scope unchanged — presence certs are leaf-only in M1 (admin-root
  # -> bot direct, one link, never delegated further), so there is no
  # narrowing to compute.
  #
  # FORWARD-FLAG (M2): mixed-type chain combine undefined — presence is
  # leaf-only in M1. A chain mixing {:docs} and {:presence} links, or
  # {:presence} links with differing identity_uuids, has no defined
  # combination rule yet and is rejected rather than silently guessing.
  defp combine_scope(claims) do
    scopes = Enum.map(claims, & &1.scope)

    cond do
      Enum.all?(scopes, &match?({:docs, _}, &1)) ->
        docs =
          scopes
          |> Enum.map(fn {:docs, d} -> MapSet.new(d) end)
          |> Enum.reduce(&MapSet.intersection/2)
          |> Enum.sort()

        {:ok, {:docs, docs}}

      Enum.all?(scopes, &match?({:presence, _}, &1)) ->
        case scopes |> Enum.map(fn {:presence, id} -> id end) |> Enum.uniq() do
          [single_id] -> {:ok, {:presence, single_id}}
          _multiple -> {:error, :presence_scope_id_mismatch}
        end

      # CX-4u03 / A1 + D1 (subtree-scope): same-root subtree delegation has no
      # scope narrowing to compute. An all-{:subtree} chain with a SINGLE shared
      # root collapses to that scope unchanged. Differing roots would be a
      # delegated re-scoping rule we do not support and are rejected rather than
      # silently guessed.
      Enum.all?(scopes, &match?({:subtree, _}, &1)) ->
        case scopes |> Enum.map(fn {:subtree, root} -> root end) |> Enum.uniq() do
          [single_root] -> {:ok, {:subtree, single_root}}
          _multiple -> {:error, :subtree_scope_root_mismatch}
        end

      true ->
        {:error, :mixed_scope_type_chain}
    end
  end

  defp tightest_window(claims) do
    Enum.reduce(claims, %{not_before: nil, not_after: nil}, fn %{caveats: c}, acc ->
      %{
        not_before: later(acc.not_before, c.not_before),
        not_after: earlier(acc.not_after, c.not_after)
      }
    end)
  end

  defp later(nil, b), do: b
  defp later(a, nil), do: a
  defp later(a, b), do: if(DateTime.compare(a, b) == :gt, do: a, else: b)

  defp earlier(nil, b), do: b
  defp earlier(a, nil), do: a
  defp earlier(a, b), do: if(DateTime.compare(a, b) == :lt, do: a, else: b)
end
