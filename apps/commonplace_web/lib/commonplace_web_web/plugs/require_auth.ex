defmodule CommonplaceWebWeb.Plugs.RequireAuth do
  @moduledoc """
  CX-f89w: the HTTP dead-render half of the read-auth gate. Wiki, tree,
  chat, and outline are private-repo-mirrored content — anonymous
  visitors must not be able to view them, only the public login landing
  (`GET /`) and the auth endpoints (`/login/:token`, `/logout`) stay
  reachable logged-out.

  This plug covers the FIRST of LiveView's two connection phases (the
  HTTP GET that renders the dead view). The second phase — the
  WebSocket `mount/3` a live navigation or page reload upgrades to —
  is a SEPARATE request with its own session read, so it needs its own
  gate: `CommonplaceWebWeb.RequireAuth.on_mount(:ensure_authenticated,
  ...)` in the gated `live_session`. Neither one alone is sufficient;
  this plug stops the dead-render leak, the on_mount stops the socket
  leak.

  Reuses `SessionIdentity.resolve/1` (the qat5.2 seam) read-only — this
  module does not mint sessions, touch keys, or otherwise participate
  in the write/trust path.
  """
  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2, put_flash: 3]

  alias CommonplaceWebWeb.SessionIdentity

  def init(opts), do: opts

  def call(conn, _opts) do
    case SessionIdentity.resolve(get_session(conn)) do
      {:ok, identity} ->
        assign(conn, :identity, {:ok, identity})

      :anonymous ->
        conn
        |> put_flash(:error, "Log in to view this.")
        |> redirect(to: "/")
        |> halt()
    end
  end
end
