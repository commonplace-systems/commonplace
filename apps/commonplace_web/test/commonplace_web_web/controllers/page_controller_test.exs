defmodule CommonplaceWebWeb.PageControllerTest do
  @moduledoc """
  CX-f89w: `GET /` is now the public login landing (read-auth spec
  §4) — it must render 200 for anonymous visitors and leak no gated
  document content.
  """
  use CommonplaceWebWeb.ConnCase

  test "GET / renders the public login landing, not gated content", %{conn: conn} do
    conn = get(conn, ~p"/")

    assert html_response(conn, 200) =~ "This workspace is private"
  end
end
