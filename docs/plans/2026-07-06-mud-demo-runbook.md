# MUD section-ownership demo runbook (CX-qat5.4 Part A)

Walks the M2 demo bar live: X owns a "forest-path" section (two room
docs) via a capability cert and edits it; Y (a registered, signed
player with no cert) is DENIED at the same verifier that gates
federation imports; X delegates an attenuated cert to Z and Z edits
within the narrowed scope. Localhost only — no exposure/TLS work is in
scope here (that stays hard-gated under CX-qat5.7).

## 0. Known limitation — read this first

`Commonplace.Trust.config/0` and the local-write-gate knob
(`Application.get_env(:commonplace, :trust)` /
`Application.get_env(:commonplace, :local_write_gate)`) are **node-
global application env**, not per-workspace. There is no way today to
run one strict/enforced workspace and one permissive workspace on the
same BEAM node. That is exactly why this demo gets its own **dedicated
node** with its own data dir and port, rather than running inside your
regular dev server. Per-workspace strictness is future work — it is
noted here, not built.

## 1. Start the dedicated demo node

Pick a data dir and a port that don't collide with anything else
you're running (the ordinary dev server defaults to port 4000; the
wiki demo historically uses 5199 — pick something else, e.g. 5299).

```bash
mkdir -p /tmp/mud-demo-data
export COMMONPLACE_DATA_DIR=/tmp/mud-demo-data
export PORT=5299
iex -S mix phx.server
```

This boots the full `commonplace_web` app (Endpoint, PubSub, the
`Commonplace.Store.Supervisor` default trio) against a fresh data dir.
Leave this IEx session open — every step below runs inside it.

## 2. Flip the node into strict + enforce

In the SAME IEx session (this is what "node-global" means in practice
— it now applies to every workspace this node serves):

```elixir
Application.put_env(:commonplace, :trust, %{
  accept_unsigned: false,
  trusted_identities: %{}   # filled in step 3 once the node identity exists
})
Application.put_env(:commonplace, :local_write_gate, :enforce)
```

## 3. Establish the workspace root + trust anchor

```elixir
alias Commonplace.Store.CommitStoreClient
alias Commonplace.Tree.Schema
alias Commonplace.Crypto.NodeIdentity

root_uuid = UUID.uuid4()
root_update = Yelixer.Encoding.encode_update(Schema.new_schema())
CommitStoreClient.create_commit(CommitStoreClient, root_uuid, root_update, nil)

# The demo's trust anchor is this node's own identity — already
# auto-trusted by Trust.config/0's with_local_node_trust/1 (phase 2.5),
# so nothing further to pin here. If you'd rather mint a dedicated
# human "root" signer instead of relying on the node identity, generate
# an Ed25519 keypair with Commonplace.Crypto.Signing.generate_keypair/0
# and add {"root" => encoded_pubkey} to the trusted_identities map from
# step 2 — then use that SigningContext (not the node's) everywhere
# "root_ctx" appears below.
{:ok, node_identity} = NodeIdentity.identity()
{:ok, node_pub} = NodeIdentity.public_key()
{:ok, root_ctx} = NodeIdentity.signing_context()
```

## 4. Mint X, Y, Z as players (`Invites.mint`)

```elixir
alias Commonplace.Invites
alias Commonplace.Crypto.AgentKeys

{:ok, %{identity_uuid: x_uuid, token: x_token}} = Invites.mint("x", root_uuid)
{:ok, %{identity_uuid: y_uuid, token: y_token}} = Invites.mint("y", root_uuid)
{:ok, %{identity_uuid: z_uuid, token: z_token}} = Invites.mint("z", root_uuid)

{:ok, x_pub} = AgentKeys.ensure(x_uuid)
{:ok, y_pub} = AgentKeys.ensure(y_uuid)
{:ok, z_pub} = AgentKeys.ensure(z_uuid)

IO.puts("X login: http://localhost:#{System.get_env("PORT", "4000")}/login/#{x_token}")
IO.puts("Y login: http://localhost:#{System.get_env("PORT", "4000")}/login/#{y_token}")
IO.puts("Z login: http://localhost:#{System.get_env("PORT", "4000")}/login/#{z_token}")
```

Hand each URL to a separate browser (three private/incognito windows
on localhost is simplest) and load it once — `SessionController.login/2`
redeems the one-time token and sets the session cookie. Don't reload;
tokens are single-use.

## 5. Create the "forest-path" section (two room docs)

```elixir
alias Commonplace.Document.ContentType

room_update = fn body ->
  Yelixer.Doc.new()
  |> ContentType.create(:text, "__room.json")
  |> ContentType.insert_text(0, body)
  |> Yelixer.Encoding.encode_update()
end

room1 = UUID.uuid4()
room2 = UUID.uuid4()
CommitStoreClient.create_commit(CommitStoreClient, room1, room_update.("{\"name\":\"forest-path-1\"}"), nil, %{}, signing_context: root_ctx)
CommitStoreClient.create_commit(CommitStoreClient, room2, room_update.("{\"name\":\"forest-path-2\"}"), nil, %{}, signing_context: root_ctx)
```

## 6. Root issues X the section cert (`MUD.Sections.issue_section/4`)

```elixir
alias Commonplace.MUD.Sections

{:ok, x_cap} =
  Sections.issue_section(root_ctx, {x_uuid, x_pub}, [room1, room2],
    verbs: [:write, :delegate]  # :delegate so X can attenuate onward to Z in step 8
  )
```

## 7. Beat: X owns/edits, Y is denied

X's browser session (the logged-in tab from step 4) performs whatever
in-app room-edit action your UI wires to `capability_proof: x_cap.id`
+ X's session signing context — that LiveView wiring is out of scope
for this runbook (it's the UI layer on top of the capability plumbing
this bead ships); to walk the beat directly from IEx instead:

```elixir
{:ok, x_ctx} = AgentKeys.signing_context_for(x_uuid)
CommitStoreClient.create_chained_commit(
  CommitStoreClient, room1, room_update.("{\"name\":\"forest-path-1\",\"desc\":\"decorated by X\"}"),
  %{kind: :regular, capability_proof: x_cap.id}, signing_context: x_ctx
)
# => %Commonplace.Store.Commit{} — lands.

{:ok, y_ctx} = AgentKeys.signing_context_for(y_uuid)
CommitStoreClient.create_chained_commit(
  CommitStoreClient, room1, room_update.("{\"name\":\"forest-path-1\",\"desc\":\"defaced by Y\"}"),
  %{}, signing_context: y_ctx
)
# => {:error, {:trust_rejected, {:untrusted_signer, y_uuid}}} — denied.
# Watch the "red:" PubSub topic for room1 (Commonplace.Dataflow.PubSub.subscribe_red/1)
# to see the same denial event a live UI would render as a permission flash.
```

## 8. Beat: X delegates to Z, attenuated to room1 only

```elixir
{:ok, z_cap} =
  Sections.delegate_section(x_ctx, {z_uuid, z_pub}, [room1], parent: x_cap, verbs: [:write])

{:ok, z_ctx} = AgentKeys.signing_context_for(z_uuid)

CommitStoreClient.create_chained_commit(
  CommitStoreClient, room1, room_update.("{\"name\":\"forest-path-1\",\"desc\":\"tidied by Z\"}"),
  %{kind: :regular, capability_proof: z_cap.id}, signing_context: z_ctx
)
# => lands.

CommitStoreClient.create_chained_commit(
  CommitStoreClient, room2, room_update.("{\"name\":\"forest-path-2\",\"desc\":\"overreached by Z\"}"),
  %{kind: :regular, capability_proof: z_cap.id}, signing_context: z_ctx
)
# => {:error, {:trust_rejected, :capability_insufficient}} — Z's cert never covered room2.
```

## 9. Beat: short-lived delegation "expires" (the interim revocation story)

There is no true revocation mechanism yet (CX-qat5.4 Part B, design-
first, not built here). The operationally-real interim mitigation is a
short `not_after` caveat:

```elixir
{:ok, short_cap} =
  Sections.delegate_section(x_ctx, {z_uuid, z_pub}, [room1],
    parent: x_cap, verbs: [:write], ttl_seconds: 5
  )

# Within 5s, Z's write with short_cap.id lands as usual. Wait past the
# window and the SAME cert now denies:
Process.sleep(6_000)

CommitStoreClient.create_chained_commit(
  CommitStoreClient, room1, room_update.("{\"name\":\"forest-path-1\",\"desc\":\"late edit\"}"),
  %{kind: :regular, capability_proof: short_cap.id}, signing_context: z_ctx
)
# => {:error, {:trust_rejected, :expired}}
```

## 10. Shut down

`Ctrl+C` twice in the IEx session. The demo data dir
(`/tmp/mud-demo-data` above) is disposable — delete it between runs if
you want a clean slate.
