defmodule CommonplaceWebWeb.Plugs.FederationAuth do
  @moduledoc """
  Bearer-token gate for the federation endpoints (phase C, CX-orfw).

  Two-auth-layers rule (federation.md): this plug is the ONLINE layer —
  "may you talk to this endpoint at all." It is transport hygiene, not
  authorization: whether a commit LANDS is decided offline by Gate A
  (`import_commit` → `Trust.authorized?`), which this plug never touches.

  Peers are configured as `token => peer_name`:

      config :commonplace_web, :federation_peers, %{"s3cret" => "peer-a"}

  No configured peers ⇒ federation is OFF and every request 403s — the
  secure default for workspaces that never opted in.
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    peers = Application.get_env(:commonplace_web, :federation_peers, %{})

    with [<<"Bearer ", token::binary>>] <- get_req_header(conn, "authorization"),
         {:ok, peer} <- lookup(peers, token) do
      assign(conn, :federation_peer, peer)
    else
      _ ->
        conn
        |> send_resp(403, "federation: not authorized")
        |> halt()
    end
  end

  # Constant-time comparison per candidate token (the peer map is small).
  defp lookup(peers, token) do
    Enum.find_value(peers, :error, fn {candidate, peer} ->
      if Plug.Crypto.secure_compare(candidate, token), do: {:ok, peer}
    end)
  end
end
