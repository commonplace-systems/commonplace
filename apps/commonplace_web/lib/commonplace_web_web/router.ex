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

    # CX-k8tn: Workflowy-style outliner on the flat-bag-of-xml-items model.
    live "/outline/:name", OutlineLive
  end

  pipeline :federation do
    plug :accepts, ["json"]
    plug CommonplaceWebWeb.Plugs.FederationAuth
  end

  # Federation pull endpoints (phase C, CX-orfw). Bearer-token gated
  # (online layer); landing is decided by Gate A at import (offline
  # layer). No peers configured ⇒ everything 403s.
  scope "/federation", CommonplaceWebWeb do
    pipe_through :federation

    get "/docs/:uuid/cids", FederationController, :cids
    post "/docs/:uuid/commits", FederationController, :commits
    post "/import", FederationController, :import
  end
end
