# Node B — the AGENT'S HOME WORKSPACE, serving federation over HTTP.
#
# A plain OS process: NO --sname, NO cookie, NO epmd, NO BEAM
# distribution. This workspace's only connection to the outside world
# is the federation HTTP surface (bearer-token gated).
#
# What happens here (the move-#1 lifecycle, phase B + C end to end):
#   1. A human root REGISTERS an agent through the substrate
#      (Identity.register_agent) — the agent's birth commits are
#      CREATOR-SIGNED (D9), its keypair minted into SecretStore custody
#      (CX-88mw), its pubkey bound into the identity doc.
#   2. The root DELEGATES the agent a write-scoped capability cert
#      (phase-3 cert-DAG — same mechanism that would grant a peer-root).
#   3. The agent AUTHORS commits signed with its own key, stamping
#      capability_proof — one in scope, one OUT of scope, plus a second
#      UNCERTIFIED bot's commit (Node A's gate will sort them out).
#   4. Bandit serves the federation endpoints (real router + parsers).
#
#   elixir -S mix run --no-start node_b.exs <dirB> <shared> <port>

[data_dir, shared, port_s] = System.argv()
port = String.to_integer(port_s)
Application.put_env(:commonplace, :data_dir, data_dir)

alias Commonplace.Crypto.{AgentKeys, Signing, SigningContext}
alias Commonplace.Presence.Identity
alias Commonplace.Store.{CommitStore, SecretStore}
alias Commonplace.Tree.Schema
alias Commonplace.Trust.Capability

{:ok, _} = Application.ensure_all_started(:phoenix_pubsub)
{:ok, _} = Application.ensure_all_started(:telemetry)
{:ok, _} = Application.ensure_all_started(:bandit)
{:ok, _} = Supervisor.start_link([{Phoenix.PubSub, name: Commonplace.PubSub}], strategy: :one_for_one)
{:ok, _} = CommitStore.start_link(data_dir: data_dir, name: CommitStore)
{:ok, _} = SecretStore.start_link(data_dir: data_dir, name: SecretStore)
{:ok, _} = CommonplaceWebWeb.FederationPeerBudget.start_link([])

say = fn msg -> IO.puts("[B] " <> msg) end

# --- the human root of trust ---
{root_pub, root_priv} = Signing.generate_keypair()
root_uuid = "jes-root"
root_ctx = %SigningContext{identity_uuid: root_uuid, private_key: root_priv, public_key: root_pub}

# B is itself strict and pins its root — every commit on B is accountable.
Application.put_env(:commonplace, :trust, %{
  accept_unsigned: false,
  trusted_identities: %{root_uuid => Signing.encode_key(root_pub)}
})

# Workspace root schema.
ws_root = UUID.uuid4()
_ = CommitStore.create_commit(CommitStore, ws_root, Yelixer.Encoding.encode_update(Schema.new_schema()), nil)

# --- 1. the root registers the agent (creator-signed birth, CX-88mw) ---
{:ok, agent_uuid, agent_pub} =
  Identity.register_agent("fable-demo-agent", ws_root, CommitStore, signing_context: root_ctx)

{:ok, birth} = CommitStore.latest_commit(CommitStore, agent_uuid)
say.("agent registered: #{agent_uuid}")
say.("  birth commit signer: #{birth.signer_id}  ← the CREATOR signed it (D9)")

# --- 2. the root delegates a write-scoped cert to the agent's key ---
doc_in_scope = UUID.uuid4()
doc_uncertified = UUID.uuid4()
doc_out_of_scope = UUID.uuid4()

{:ok, cert} =
  Capability.delegate(root_ctx, {agent_uuid, agent_pub}, %{
    verbs: [:write],
    scope: {:docs, [doc_in_scope]},
    caveats: %{not_before: nil, not_after: nil}
  })

:ok = CommitStore.store_capability(CommitStore, cert)
say.("root delegated {write, [#{String.slice(doc_in_scope, 0, 8)}…]} → agent  (cert #{Base.encode16(cert.id, case: :lower) |> String.slice(0, 12)}…)")
say.("  (CLI equivalent: commonplace cap delegate --audience #{String.slice(agent_uuid, 0, 8)}…)")

# --- 3. the agent authors commits with ITS OWN key ---
{:ok, agent_ctx} = AgentKeys.signing_context_for(agent_uuid)

mkdoc = fn text ->
  doc = Yelixer.Doc.new()
  doc = Commonplace.Document.ContentType.create(doc, :text, "note.md")
  doc = Commonplace.Document.ContentType.insert_text(doc, 0, text)
  Yelixer.Encoding.encode_update(doc)
end

in_scope_commit =
  CommitStore.create_commit(
    CommitStore, doc_in_scope, mkdoc.("hello from the federated agent"), nil,
    %{kind: :regular, capability_proof: cert.id},
    signing_context: agent_ctx
  )

say.("agent authored doc #{String.slice(doc_in_scope, 0, 8)}… (IN scope, proof stamped) signer=#{in_scope_commit.signer_id}")

# OUT-of-scope: same agent, same cert proof — but a doc the cert never granted.
out_of_scope_commit =
  CommitStore.create_commit(
    CommitStore, doc_out_of_scope, mkdoc.("the agent overreaches"), nil,
    %{kind: :regular, capability_proof: cert.id},
    signing_context: agent_ctx
  )

say.("agent authored doc #{String.slice(doc_out_of_scope, 0, 8)}… (OUT of scope — A's gate should refuse)")

# An UNCERTIFIED bot: validly signed, but nobody delegated it anything.
{mallory_pub, mallory_priv} = Signing.generate_keypair()
mallory_ctx = %SigningContext{identity_uuid: "mallory-bot", private_key: mallory_priv, public_key: mallory_pub}

uncertified_commit =
  CommitStore.create_commit(
    CommitStore, doc_uncertified, mkdoc.("no cert, no entry"), nil,
    %{kind: :regular},
    signing_context: mallory_ctx
  )

say.("mallory-bot authored doc #{String.slice(doc_uncertified, 0, 8)}… (signed, but NO cert)")
_ = {out_of_scope_commit, uncertified_commit, mallory_pub}

# --- 4. serve federation over HTTP ---
token = Base.url_encode64(:crypto.strong_rand_bytes(12))
Application.put_env(:commonplace_web, :federation_peers, %{token => "node-a"})

defmodule FedDemo.Pipeline do
  use Plug.Builder
  plug Plug.Parsers, parsers: [:json], pass: ["*/*"], json_decoder: Jason
  plug CommonplaceWebWeb.Router
end

{:ok, _} = Bandit.start_link(plug: FedDemo.Pipeline, scheme: :http, port: port)
say.("federation surface up on http://127.0.0.1:#{port}  (bearer-token gated; no cookie, no epmd, no distribution)")

manifest = %{
  port: port,
  token: token,
  root_pub_b64: Signing.encode_key(root_pub),
  agent_uuid: agent_uuid,
  agent_pub_b64: Signing.encode_key(agent_pub),
  doc_in_scope: doc_in_scope,
  doc_out_of_scope: doc_out_of_scope,
  doc_uncertified: doc_uncertified,
  in_scope_commit_id_b64: Base.encode64(in_scope_commit.id)
}

File.write!(Path.join(shared, "manifest.json"), Jason.encode!(manifest))
File.write!(Path.join(shared, "b_ready"), "ok")
say.("ready — waiting for Node A to pull")

Process.sleep(:infinity)
