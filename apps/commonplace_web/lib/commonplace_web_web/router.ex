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

  # CX-f89w: the HTTP dead-render half of the read-auth gate. Piped
  # AFTER :browser (needs the fetched session) and only on the gated
  # scope below — the public scope (/, /login/:token, /logout) must
  # NOT pipe through this, or nobody could ever authenticate.
  pipeline :require_auth do
    plug CommonplaceWebWeb.Plugs.RequireAuth
  end

  # PUBLIC scope: reachable logged-out. GET / is a minimal login
  # landing that leaks no document content (see PageController.home).
  # Boss decision: / stays public rather than fully dark; trivially
  # flippable later by moving this `get "/"` into the gated scope
  # below, which would make the whole app dark to anonymous visitors.
  scope "/", CommonplaceWebWeb do
    pipe_through :browser

    get "/", PageController, :home

    # CX-qat5.2 §2.2: invite-redemption login + logout. Binds the
    # session to a player identity ({identity_uuid, session_nonce} only
    # — never key material); SessionIdentity.resolve/1 re-derives the
    # SigningContext + hand from that pair on every LiveView mount.
    get "/login/:token", SessionController, :login
    get "/logout", SessionController, :logout
  end

  # GATED scope (CX-f89w): wiki/tree/chat/outline are private-repo-
  # mirrored content — require an authenticated session
  # (`SessionIdentity.resolve/1` → `{:ok, _}`) to view. LiveView is
  # two-phase, so BOTH the dead-render (`:require_auth` plug, above)
  # AND the websocket mount (`on_mount` below) must gate; either one
  # alone lets the other phase leak content.
  scope "/", CommonplaceWebWeb do
    pipe_through [:browser, :require_auth]

    live_session :authenticated,
      layout: {CommonplaceWebWeb.Layouts, :bare},
      on_mount: {CommonplaceWebWeb.RequireAuth, :ensure_authenticated} do
      live "/wiki", WikiLive
      live "/wiki/*path", WikiLive
      live "/tree", TreeLive
      live "/tree/*path", TreeLive

      # CX-71o3 (C1 of CX-p2qp chat-room umbrella): chat-room LiveView.
      # `:room` is the human-friendly room name; ChatRoomLive walks the
      # workspace schema to resolve `/chat/{room}/_messages`.
      live "/chat/:room", ChatRoomLive

      # CX-k8tn: Workflowy-style outliner on the flat-bag-of-xml-items model.
      live "/outline/:name", OutlineLive

      # CX-gjpi: browser MUD client — the curated MUD world, played
      # under strict+enforce trust via a per-session PlayerSession.
      live "/mud", MudLive
      live "/play", MudLive
    end
  end

  # Runner-lane mint transport. The controller additionally refuses every
  # non-loopback peer before the node signing authority is consulted.
  scope "/api", CommonplaceWebWeb do
    pipe_through :api

    post "/cert-mint", CertMintController, :create
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
