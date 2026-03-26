defmodule CommonplaceWebWeb.PageControllerTest do
  use CommonplaceWebWeb.ConnCase

  test "GET / redirects to wiki", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert redirected_to(conn, 302) == "/wiki"
  end
end
