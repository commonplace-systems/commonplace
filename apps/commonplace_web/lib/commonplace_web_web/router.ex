defmodule CommonplaceWebWeb.Router do
  use CommonplaceWebWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {CommonplaceWebWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", CommonplaceWebWeb do
    pipe_through :browser

    get "/", PageController, :home

    live_session :wiki, layout: {CommonplaceWebWeb.Layouts, :bare} do
      live "/wiki", WikiLive
      live "/wiki/*path", WikiLive
    end
    live "/tree", TreeLive
    live "/tree/*path", TreeLive

    # CX-71o3 (C1 of CX-p2qp chat-room umbrella): chat-room LiveView.
    # `:room` is the human-friendly room name; ChatRoomLive walks the
    # workspace schema to resolve `/chat/{room}/_messages`.
    live "/chat/:room", ChatRoomLive
  end

  # Other scopes may use custom stacks.
  # scope "/api", CommonplaceWebWeb do
  #   pipe_through :api
  # end
end
