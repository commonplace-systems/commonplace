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
        emit_denial(conn, peers)

        conn
        |> send_resp(403, "federation: not authorized")
        |> halt()
    end
  end

  # CX-t3xv: this 403 is a deny site, and until this ticket it emitted
  # NOTHING — a peer hammering the federation endpoint with a bad or
  # absent token left no trace on any surface. It is the brief's
  # "syntactic outlier": a deny site that looks nothing like the others,
  # which is precisely why an event-name-shaped scan could never have
  # found it (see `Commonplace.Trust.DenySites`).
  #
  # HASH, NEVER PAYLOAD, applied to a credential: the presented token is
  # a secret. Recording it would put an attacker-supplied (or, on a
  # fat-fingered config, a REAL) bearer token into an append-only,
  # replicating audit doc. Only a truncated digest is recorded — enough
  # to correlate repeated attempts from one bad credential, useless for
  # replaying it.
  defp emit_denial(conn, peers) do
    :telemetry.execute(
      [:commonplace, :federation, :rejected, :auth],
      %{system_time: System.system_time()},
      %{
        reason: if(map_size(peers) == 0, do: :federation_disabled, else: :bad_bearer_token),
        principal: token_fingerprint(get_req_header(conn, "authorization")),
        path: conn.request_path,
        peers_configured: map_size(peers)
      }
    )
  rescue
    # A telemetry failure must never turn a 403 into a 500. The refusal
    # is the enforcement; the record is derived.
    _ -> :ok
  end

  defp token_fingerprint([<<"Bearer ", token::binary>>]) do
    "sha256:" <>
      (:crypto.hash(:sha256, token) |> Base.encode16(case: :lower) |> binary_part(0, 16))
  end

  defp token_fingerprint(_), do: "absent"

  # Constant-time comparison per candidate token (the peer map is small).
  defp lookup(peers, token) do
    Enum.find_value(peers, :error, fn {candidate, peer} ->
      if Plug.Crypto.secure_compare(candidate, token), do: {:ok, peer}
    end)
  end
end
