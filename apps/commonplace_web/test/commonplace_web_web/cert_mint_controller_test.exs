defmodule CommonplaceWebWeb.CertMintControllerTest do
  use CommonplaceWebWeb.ConnCase

  test "local malformed request reaches the serve route without consulting keys", %{conn: conn} do
    conn = post(conn, ~p"/api/cert-mint", %{})

    assert json_response(conn, 422) == %{"error" => "cert-mint refused: malformed request"}
  end

  test "non-loopback request refuses before consulting node signing authority", %{conn: conn} do
    conn = %{conn | remote_ip: {192, 0, 2, 10}}
    conn = post(conn, ~p"/api/cert-mint", %{})

    assert json_response(conn, 403) == %{"error" => "cert-mint refused: endpoint is local-only"}
  end
end
