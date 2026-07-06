defmodule CommonplaceWebWeb.SessionController do
  @moduledoc """
  CX-qat5.2 §2.2: the login/logout endpoints that bind a Phoenix session
  to a player identity. `GET /login/:token` redeems a one-time invite
  token (`Commonplace.Invites.redeem/2`) and, on success, writes the
  session cookie's ONLY two identity fields —
  `"player_identity_uuid"` and `"session_nonce"` — never key material.
  `CommonplaceWebWeb.SessionIdentity.resolve/1` re-derives the
  `SigningContext` from node-local `SecretStore` custody on every
  mount; this controller never touches the private key.

  `session_nonce` is minted fresh at login and then PERSISTS for the
  life of the session (in the session cookie) — that's what makes the
  W4 session hand (`WriterHand.for_session/2`) stable across LiveView
  remounts and reconnects, per the design doc's "persisted in session
  state" requirement.
  """

  use CommonplaceWebWeb, :controller

  alias Commonplace.Invites

  def login(conn, %{"token" => token}) do
    case Invites.redeem(token) do
      {:ok, identity_uuid} ->
        nonce = Base.encode64(:crypto.strong_rand_bytes(16))
        name = player_name(identity_uuid)

        conn
        # Session-fixation hygiene: rotate the session at the privilege
        # change so a pre-login cookie value can't be pinned across the
        # login boundary.
        |> configure_session(renew: true)
        |> put_session(:player_identity_uuid, identity_uuid)
        |> put_session(:session_nonce, nonce)
        |> put_flash(:info, "Logged in as #{name}")
        |> redirect(to: "/wiki")

      {:error, reason} ->
        conn
        |> put_status(:forbidden)
        |> text(login_error_message(reason))
    end
  end

  def logout(conn, _params) do
    conn
    |> delete_session(:player_identity_uuid)
    |> delete_session(:session_nonce)
    |> redirect(to: "/wiki")
  end

  defp login_error_message(:expired), do: "This invite link has expired."
  defp login_error_message(_invalid), do: "This invite link is invalid or has already been used."

  defp player_name(identity_uuid) do
    case Commonplace.Presence.Identity.read(identity_uuid) do
      %{"name" => name} when is_binary(name) -> name
      _ -> "player"
    end
  end
end
