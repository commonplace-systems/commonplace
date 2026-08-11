defmodule Commonplace.CertMint do
  @moduledoc """
  Server-side core for the runner-lane `cert-mint` command.

  This module is deliberately a thin ceremony: resolve the existing document
  reference grammar, resolve the audience's node-custodied public key, then
  call `Commonplace.Trust.Capability.issue/5` with the node signing context.
  The resulting certificate is stored without changing its bytes.

  CLI-minted grants use `{:subtree, root_uuid}` scope. Subtree grants are
  leaf-only until a safe subtree attenuation rule exists; `Capability.issue/5`
  enforces that limit for every attempted child.
  """

  alias Commonplace.Crypto.{AgentKeys, NodeIdentity, SigningContext}
  alias Commonplace.Store.{CommitStoreClient, SecretStore}
  alias Commonplace.Tree.{DocBuilder, Walk}
  alias Commonplace.Trust.Capability

  @leaf_only_refusal "cert-mint refused: CLI-minted certificates are leaf-only because subtree delegation narrowing is not defined"

  @doc "Mint, node-sign, and store one leaf-only subtree capability."
  @spec mint(String.t(), [atom()], String.t(), DateTime.t() | nil, keyword()) ::
          {:ok, Capability.t()} | {:error, term()}
  def mint(scope_ref, verbs, audience_uuid, expiry, opts \\ []) do
    store = Keyword.get(opts, :store, CommitStoreClient)

    with :ok <- validate_audience_uuid(audience_uuid),
         {:ok, root_uuid} <- resolve_root_uuid(opts),
         {:ok, scope_uuid} <- resolve_scope_ref(scope_ref, root_uuid, store),
         {:ok, audience_pubkey} <- resolve_audience(audience_uuid, opts),
         {:ok, issuer_ctx} <- resolve_issuer_context(opts),
         claim = claim(scope_uuid, verbs, expiry),
         {:ok, cap} <-
           Capability.issue(
             issuer_ctx,
             {audience_uuid, audience_pubkey},
             claim,
             nil,
             store: store
           ),
         :ok <- CommitStoreClient.store_capability(store, cap) do
      {:ok, cap}
    end
  end

  @doc "Resolve bare path, `:uuid`, or `@cid` using a fixture-compatible store."
  @spec resolve_scope_ref(String.t(), String.t(), GenServer.server()) ::
          {:ok, String.t()} | {:error, term()}
  def resolve_scope_ref("", _root_uuid, _store), do: {:error, :missing_scope}

  def resolve_scope_ref(":" <> uuid, _root_uuid, _store) do
    if uuid?(uuid), do: {:ok, uuid}, else: {:error, :invalid_scope_uuid}
  end

  def resolve_scope_ref("@" <> cid_hex, _root_uuid, store) do
    with {:ok, cid} <- decode_cid(cid_hex),
         {:ok, commit} <- fetch_commit(store, cid) do
      {:ok, commit.doc_uuid}
    end
  end

  def resolve_scope_ref(path, root_uuid, store) when is_binary(path) do
    Walk.resolve_path(root_uuid, path, fn uuid -> load_schema(store, uuid) end)
  end

  @doc "The named refusal shown when chaining is attempted."
  def refusal_text(:subtree_scope_not_delegable), do: @leaf_only_refusal
  def refusal_text(reason), do: "cert-mint refused: #{inspect(reason)}"

  defp claim(scope_uuid, verbs, expiry) do
    %{
      verbs: verbs,
      scope: {:subtree, scope_uuid},
      caveats: %{not_before: nil, not_after: expiry}
    }
  end

  defp resolve_root_uuid(opts) do
    case Keyword.fetch(opts, :root_uuid) do
      {:ok, root_uuid} when is_binary(root_uuid) -> {:ok, root_uuid}
      {:ok, _invalid} -> {:error, :invalid_root_uuid}
      :error -> Commonplace.Workspace.root_uuid()
    end
  end

  defp resolve_audience(audience_uuid, opts) do
    resolver = Keyword.get(opts, :audience_resolver, &default_audience_resolver/1)
    resolver.(audience_uuid)
  end

  defp validate_audience_uuid(audience_uuid) do
    if is_binary(audience_uuid) and uuid?(audience_uuid),
      do: :ok,
      else: {:error, :invalid_audience_uuid}
  end

  defp default_audience_resolver(audience_uuid) do
    AgentKeys.public_key(audience_uuid, SecretStore)
  end

  defp resolve_issuer_context(opts) do
    case Keyword.get(opts, :issuer_context) do
      %SigningContext{} = ctx -> {:ok, ctx}
      nil -> NodeIdentity.signing_context()
      other -> {:error, {:invalid_issuer_context, other}}
    end
  end

  defp load_schema(store, uuid) do
    case DocBuilder.reconstruct_snapshot(store, uuid) do
      {:ok, doc} -> doc
      :none -> Commonplace.Tree.Schema.new_schema()
    end
  end

  defp fetch_commit(store, cid) do
    case CommitStoreClient.get_commit(store, cid) do
      {:ok, commit} -> {:ok, commit}
      :none -> {:error, :scope_cid_not_found}
    end
  end

  defp decode_cid(hex) when byte_size(hex) == 64 do
    case Base.decode16(hex, case: :mixed) do
      {:ok, cid} -> {:ok, cid}
      :error -> {:error, :invalid_scope_cid}
    end
  end

  defp decode_cid(_hex), do: {:error, :invalid_scope_cid}

  defp uuid?(str) do
    Regex.match?(~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i, str)
  end
end
