defmodule CommonplaceWebWeb.PageController do
  use CommonplaceWebWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
