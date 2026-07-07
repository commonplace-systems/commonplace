defmodule CommonplaceWebWeb.MudLiveTest do
  @moduledoc """
  CX-gjpi: `MudLive` mounted anonymously (no session — `SessionIdentity.
  resolve/1` collapses to `:anonymous`) must show the login-required
  message and never start a `PlayerSession`. The router's own
  `:authenticated` `live_session` gate (`RequireAuth`) already blocks an
  anonymous request from ever reaching this LiveView in production;
  `live_isolated/3` here mounts the LiveView directly, bypassing that
  router gate, so this test exercises `MudLive.mount/3`'s own
  defense-in-depth `:anonymous` branch in isolation.
  """
  use CommonplaceWebWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias CommonplaceWebWeb.MudLive

  test "anonymous mount shows the login-required message, no session started", %{conn: conn} do
    {:ok, view, html} = live_isolated(conn, MudLive, session: %{})

    assert html =~ "You must be logged in to play"
    assert render(view) =~ "You must be logged in to play"
    refute has_element?(view, "form[phx-submit=command]")
  end
end
