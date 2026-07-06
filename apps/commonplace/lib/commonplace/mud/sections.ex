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
  """

  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Trust.Capability

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
    * `:ttl_seconds` — sets `claim.caveats.not_after` (nil = unbounded).
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

  # --- private ---

  defp reject_execute(verbs) do
    if :execute in verbs,
      do: {:error, :execute_forbidden_in_section_cert},
      else: :ok
  end

  defp build_claim(verbs, uuids, opts) do
    not_after =
      case Keyword.get(opts, :ttl_seconds) do
        nil -> nil
        ttl when is_integer(ttl) -> DateTime.add(DateTime.utc_now(), ttl, :second)
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
