defmodule CommonplaceWebWeb.PageController do
  @moduledoc """
  CX-f89w: `GET /` is the ONE route that must render for anonymous
  visitors AND must leak no document content — it's the public login
  landing for a workspace whose wiki/tree/chat/outline are all gated
  behind `CommonplaceWebWeb.Plugs.RequireAuth` /
  `CommonplaceWebWeb.RequireAuth.on_mount/4`.

  Boss decision (read-auth spec §4): stays a public landing rather than
  fully dark, on purpose — trivially flippable later by moving
  `get "/", PageController, :home` into the gated scope in router.ex,
  which would make the whole app dark to anonymous visitors instead of
  showing this prompt.
  """
  use CommonplaceWebWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
