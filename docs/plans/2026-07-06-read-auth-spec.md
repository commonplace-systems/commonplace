# CX-f89w spec — read-auth on the browser pipeline (require a session to VIEW)

Author: commonplace (Fable; Sonnet implements). Closes the HTTP read
exposure at the app layer: anonymous visitors can't view the
private-repo-mirrored wiki/tree/chat/outline. Pairs with the live
strict WRITE gate (CX-qat5.7). Reuses the qat5.2 session seam.

## 1. The gate

Require `CommonplaceWebWeb.SessionIdentity.resolve(session)` to return
`{:ok, _}` (a logged-in magic-link session) to reach the CONTENT read
routes. Anonymous → a public "log in to view" landing that leaks no
content. LiveView is two-phase, so BOTH phases must be gated:

- **HTTP dead-render (GET)** — a plug on the gated routes.
- **WebSocket mount** — an `on_mount` hook in the gated `live_session`.

## 2. Routes (from router.ex)

Split the current `:browser` scope into public vs gated:

- **PUBLIC** (no auth): `GET /` (PageController :home — becomes the
  login landing, §4), `GET /login/:token`, `GET /logout`. These MUST
  stay reachable or nobody can authenticate. `/federation/*` is a
  separate pipeline (bearer-token) — do NOT touch it.
- **GATED** (require `{:ok,_}` session): `live "/wiki"`, `"/wiki/*path"`,
  `"/tree"`, `"/tree/*path"`, `"/chat/:room"`, `"/outline/:name"`.
  Wrap ALL of these in ONE `live_session` (they're currently split — the
  `:wiki` live_session plus bare `live` calls; consolidate the gated
  ones under a single `live_session :authenticated` with the on_mount).

## 3. Mechanism

- `CommonplaceWebWeb.Plugs.RequireAuth` (new): reads `get_session(conn,
  ...)`, calls `SessionIdentity.resolve/1`; on `:anonymous` →
  `redirect(conn, to: "/") |> halt()` (with a flash "Log in to view
  this."). On `{:ok, _}` → assign the resolved identity to the conn and
  continue. Put it on a new `:require_auth` pipeline that the gated
  scope pipes through (after `:browser`).
- `CommonplaceWebWeb.RequireAuth.on_mount(:ensure_authenticated, _params,
  session, socket)` (new): `SessionIdentity.resolve(session)` → on
  `:anonymous` `{:halt, redirect(socket, to: "/")}`; on `{:ok, id}`
  `{:cont, assign(socket, :identity, {:ok, id})}`. The gated
  `live_session` uses `on_mount {CommonplaceWebWeb.RequireAuth,
  :ensure_authenticated}`. NOTE the LiveViews already resolve identity
  in their own `mount/3` (qat5.2/nn4y) — keep that; the on_mount is the
  GATE, the in-mount resolve stays for the write-identity threading.
  Don't double-resolve wastefully if trivial to share, but correctness
  over cleverness: the on_mount halt is what matters.

## 4. The login landing (GET /)

`PageController :home` renders a minimal page: product name + "This
workspace is private — open your invite link to log in." NO document
content, NO navigation into gated routes' data. (Boss decision: GET /
stays a public login landing, not fully dark — trivially flippable to
fully-gated later by moving `/` into the gated scope; leave a code
comment noting that.)

## 5. Blast radius (already verified — do not regress)

- GitBridge OUTBOUND mirror reads the store IN-PROCESS (CommitStoreClient
  / DocBuilder) — NO HTTP → unaffected. Do not touch git_bridge.
- Federation endpoints — separate bearer-token pipeline → unaffected.
- MCP reads — BEAM distribution, not HTTP → unaffected.
- The write path / strict gate — untouched (this is reads only).

## 6. Test pins

1. Anonymous `GET /wiki` (and /tree, /chat/x, /outline/x) → 302 redirect
   to `/`, NO content in the body.
2. Anonymous LiveView socket connect to a gated route → halted/redirected
   (use `Phoenix.LiveViewTest` — `{:error, {:redirect, %{to: "/"}}}` or
   the live/2 redirect tuple).
3. Logged-in session (resolve → {:ok,_}; reuse qat5.2 session test
   helpers / SessionController login flow) → gated route renders 200 with
   content.
4. `GET /` → 200 public landing, NO gated content, works logged-out.
5. `GET /login/:token` and `/logout` still reachable logged-out.
6. Federation route still behaves as before (403 without bearer) —
   regression guard that read-auth didn't bleed into that pipeline.
7. Full web suite + `mix compile --warnings-as-errors` clean.

## 7. Constraints

DO NOT SPAWN SUBAGENTS. NEVER use run_in_background for ANY command —
all foreground, wait for slow suites. No changes to git_bridge, the
federation pipeline, the write/trust path, SessionIdentity/AgentKeys.
No `bd`/.beads, no push. mix compile --warnings-as-errors clean. Match
house style. VERIFY: compile → mix test apps/commonplace_web/test →
(new tests). COMMIT: one commit "CX-f89w: read-auth — require an
authenticated session to view wiki/tree/chat/outline",
Co-Authored-By: Claude Sonnet <noreply@anthropic.com>. FINAL REPORT:
sha, files, per-suite counts, flags, pre-existing bugs.
