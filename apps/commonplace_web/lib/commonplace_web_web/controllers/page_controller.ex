defmodule CommonplaceWebWeb.PageController do
  use CommonplaceWebWeb, :controller

  def home(conn, _params) do
    redirect(conn, to: "/wiki")
  end
end
