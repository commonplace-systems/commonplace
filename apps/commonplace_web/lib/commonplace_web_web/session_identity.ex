defmodule CommonplaceWebWeb.SessionIdentity do
  @moduledoc """
  CX-qat5.2 + CX-41qg.4: the ONE resolution seam where a Phoenix
  session map becomes the pair `{SigningContext, hand}` the
  writer-identity plan (W4, commonplace-plan
  `2026-07-06-writer-identity-plan.md` §3) says gets assigned together,
  at one moment, for a browser session — never re-derived downstream.

  `resolve/1` is meant to be called EXACTLY ONCE per LiveView, in
  `mount/3`'s session (third) argument, and the result threaded through
  socket assigns. No downstream call site should re-run this or look up
  the session again mid-lifecycle (CX-tdkq.32/CX-hoj identity-from-
  ingress discipline: resolve once at the door, thread by argument).

  ## Session cookie shape

  The Phoenix session carries only `"player_identity_uuid"` and
  `"session_nonce"` — never key material. The private key stays in
  node-local `SecretStore` custody; this module re-resolves the
  `SigningContext` from there on every mount (cheap: SecretStore is a
  local CubDB read, not a network call).

  ## Failure is `:anonymous`, never a crash

  A wiped SecretStore, a corrupt key, an unregistered identity_uuid, or
  simply no session at all (never logged in) all collapse to the same
  `:anonymous` result. The mount must keep working logged-out — chat
  and wiki are permissive workspaces by default (spec §2.4) — so this
  function is written to never raise out of `resolve/1`.
  """

  alias Commonplace.Crypto.{AgentKeys, Signing, SigningContext}
  alias Commonplace.Presence.Identity

  @type resolved :: %{
          signing_context: SigningContext.t(),
          hand: non_neg_integer(),
          signer_id: String.t(),
          presence_path: String.t(),
          identity_uuid: String.t()
        }

  @doc """
  Resolve a Phoenix session map to `{:ok, resolved()}` | `:anonymous`.
  """
  @spec resolve(map()) :: {:ok, resolved()} | :anonymous
  def resolve(session) when is_map(session) do
    do_resolve(session)
  rescue
    _ -> :anonymous
  end

  def resolve(_), do: :anonymous

  defp do_resolve(%{"player_identity_uuid" => identity_uuid, "session_nonce" => nonce})
       when is_binary(identity_uuid) and is_binary(nonce) do
    with {:ok, %SigningContext{public_key: pub} = ctx} <-
           AgentKeys.signing_context(identity_uuid),
         name when is_binary(name) <- player_name(identity_uuid) do
      {:ok,
       %{
         signing_context: ctx,
         hand: Commonplace.WriterHand.for_session(pub, nonce),
         signer_id: Signing.signer_id(identity_uuid, pub),
         presence_path: "#{name}.usr",
         identity_uuid: identity_uuid
       }}
    else
      _ -> :anonymous
    end
  end

  defp do_resolve(_session), do: :anonymous

  defp player_name(identity_uuid) do
    case Identity.read(identity_uuid) do
      %{"name" => name} when is_binary(name) -> name
      _ -> nil
    end
  end
end
