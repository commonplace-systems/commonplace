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
  """

  alias Commonplace.Store.CommitStore
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Trust.Capability

  @max_depth 64

  @type effective :: %{verbs: [atom()], scope: {:docs, [String.t()]}, caveats: map()}

  @spec verify_chain(binary(), MapSet.t(), GenServer.server()) ::
          {:ok, effective()} | {:error, atom()}
  def verify_chain(leaf_cid, anchor_keys, store \\ CommitStore) do
    with {:ok, chain} <- build_chain(leaf_cid, store),
         :ok <- check_each_cert(chain),
         :ok <- check_links(chain),
         :ok <- check_root(List.last(chain), anchor_keys) do
      {:ok, effective(chain)}
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

    docs =
      claims
      |> Enum.map(fn %{scope: {:docs, d}} -> MapSet.new(d) end)
      |> Enum.reduce(&MapSet.intersection/2)
      |> Enum.sort()

    %{verbs: verbs, scope: {:docs, docs}, caveats: tightest_window(claims)}
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
