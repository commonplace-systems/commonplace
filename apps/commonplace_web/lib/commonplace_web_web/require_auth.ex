defmodule CommonplaceWebWeb.RequireAuth do
  @moduledoc """
  CX-f89w: the WebSocket half of the read-auth gate (see
  `CommonplaceWebWeb.Plugs.RequireAuth` for the HTTP dead-render half —
  both are required, LiveView is two-phase).

  A live navigation or a page reload of an already-connected client
  upgrades to a websocket `mount/3` that never goes through the Plug
  pipeline — it re-reads the Phoenix session directly. Without this
  `on_mount` hook, an anonymous socket could reach a gated LiveView
  even though the dead-render plug blocked the initial GET.

  This ONLY gates; it does not thread identity for write paths. The
  gated LiveViews (WikiLive, TreeLive, ChatRoomLive, OutlineLive)
  already call `SessionIdentity.resolve/1` themselves in their own
  `mount/3` (CX-qat5.2 / CX-nn4y) to get the `signing_context` for
  commit-producing paths — that resolve stays as-is; this hook is a
  second, independent resolve whose only job is the halt-or-continue
  gate decision.
  """
  import Phoenix.LiveView
  import Phoenix.Component, only: [assign: 3]

  alias CommonplaceWebWeb.SessionIdentity

  def on_mount(:ensure_authenticated, _params, session, socket) do
    case SessionIdentity.resolve(session) do
      {:ok, identity} ->
        {:cont, assign(socket, :identity, {:ok, identity})}

      :anonymous ->
        {:halt, redirect(socket, to: "/")}
    end
  end
end
