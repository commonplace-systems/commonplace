# Node B — the PEER, in a live attenuation demo.
#
# Real BEAM node. Holds the capability certs (store_capability is ungated,
# so B can hold even the malformed ones a hostile peer would craft) and
# the ONE valid commit that strict Node A pulls over the real catch-up
# sync path. The four ATTACK commits are constructed + delivered to A's
# import gate by node_a (representing a hostile peer's push) — same Gate A.
#
# B writes a manifest: the root anchor pubkey, every cert CID (A fetches
# them over distribution), the demo identities' keys (so A can craft the
# attack commits), and the per-scenario specs.
#
#   elixir --sname cpb --cookie <ck> -S mix run --no-start node_b.exs <dirB> <shared>

[data_dir, shared] = System.argv()
Application.put_env(:commonplace, :data_dir, data_dir)

alias Commonplace.Crypto.{Signing, SigningContext}
alias Commonplace.Store.{Commit, CommitStore}
alias Commonplace.Document.ContentType
alias Commonplace.Trust.Capability
alias Yelixer.{Doc, Encoding}

{:ok, _} = Application.ensure_all_started(:phoenix_pubsub)
{:ok, _} = Application.ensure_all_started(:telemetry)

{:ok, _} =
  Supervisor.start_link([{Phoenix.PubSub, name: Commonplace.PubSub}], strategy: :one_for_one)

{:ok, _} = CommitStore.start_link(data_dir: data_dir, name: CommitStore)

mkident = fn id ->
  {pub, priv} = Signing.generate_keypair()

  %{
    id: id,
    pub: pub,
    priv: priv,
    ctx: %SigningContext{identity_uuid: id, private_key: priv, public_key: pub},
    keyed: {id, pub},
    signer: Signing.signer_id(id, pub)
  }
end

root = mkident.("root")
alice = mkident.("alice")
bob = mkident.("bob")
mallory = mkident.("mallory")

# B trusts the same root anchor (it's a legit federation peer holding
# bob's cert chain) so it can hold bob's valid commit.
Application.put_env(:commonplace, :trust, %{
  accept_unsigned: false,
  trusted_identities: %{"root" => Signing.encode_key(root.pub)}
})

unbounded = %{not_before: nil, not_after: nil}
claim = fn verbs, docs, caveats -> %{verbs: verbs, scope: {:docs, docs}, caveats: caveats} end

store = fn cap ->
  :ok = CommitStore.store_capability(CommitStore, cap)
  cap
end

hexid = fn cid -> Base.encode16(cid, case: :lower) end

# --- certs for each scenario (all stored on B; store_capability is ungated) ---

# 1. VALID happy chain over d1: root→alice{write,delegate}, alice→bob{write}.
{:ok, h_root_alice} =
  Capability.delegate(root.ctx, alice.keyed, claim.([:write, :delegate], ["d1"], unbounded))

store.(h_root_alice)

{:ok, h_alice_bob} =
  Capability.delegate(alice.ctx, bob.keyed, claim.([:write], ["d1"], unbounded), h_root_alice.id,
    parent: h_root_alice
  )

store.(h_alice_bob)

# 2. FORGED-sig leaf over d2.
{:ok, f_root_alice} =
  Capability.delegate(root.ctx, alice.keyed, claim.([:write, :delegate], ["d2"], unbounded))

store.(f_root_alice)

{:ok, f_alice_bob} =
  Capability.delegate(alice.ctx, bob.keyed, claim.([:write], ["d2"], unbounded), f_root_alice.id,
    parent: f_root_alice
  )

forged = %{f_alice_bob | sig: :crypto.strong_rand_bytes(64)}
store.(forged)

# 3. OVER-BROAD leaf over d3: alice grants bob :execute she never held.
#    Built via new+sign to bypass the mint-time ⊆ guard — exactly what a
#    hostile delegator would do; verify_chain must catch it.
{:ok, o_root_alice} =
  Capability.delegate(root.ctx, alice.keyed, claim.([:write, :delegate], ["d3"], unbounded))

store.(o_root_alice)

overbroad =
  Capability.new(
    alice.keyed,
    bob.keyed,
    claim.([:write, :execute], ["d3"], unbounded),
    o_root_alice.id
  )
  |> Capability.sign(alice.priv)

store.(overbroad)

# 4. STOLEN-CHAIN over d4: a fully VALID chain to bob — the attack is that
#    the COMMIT is signed by mallory, not bob.
{:ok, s_root_alice} =
  Capability.delegate(root.ctx, alice.keyed, claim.([:write, :delegate], ["d4"], unbounded))

store.(s_root_alice)

{:ok, s_alice_bob} =
  Capability.delegate(alice.ctx, bob.keyed, claim.([:write], ["d4"], unbounded), s_root_alice.id,
    parent: s_root_alice
  )

store.(s_alice_bob)

# 5. EXPIRED leaf over d5: valid narrowing at mint, but not_after in the past.
past = DateTime.add(DateTime.utc_now(), -3600, :second)

{:ok, e_root_alice} =
  Capability.delegate(root.ctx, alice.keyed, claim.([:write, :delegate], ["d5"], unbounded))

store.(e_root_alice)

{:ok, e_alice_bob} =
  Capability.delegate(
    alice.ctx,
    bob.keyed,
    claim.([:write], ["d5"], %{not_before: nil, not_after: past}),
    e_root_alice.id,
    parent: e_root_alice
  )

store.(e_alice_bob)

# --- the one VALID commit B holds and A pulls via catch_up (doc d1) ---
{:ok, _genesis} = CommitStore.ensure_genesis(CommitStore, "d1")
{:ok, gen} = CommitStore.get_commit(CommitStore, Commit.genesis("d1").id)

doc = Doc.new(client_id: 11)
doc = ContentType.create(doc, :text, "note.txt")
doc = ContentType.insert_text(doc, 0, "bob writes within his grant")
update = Encoding.encode_update(doc)

bob_commit =
  Commit.new("d1", update, gen.id, %{
    kind: :regular,
    snapshot_parent: gen.id,
    capability_proof: h_alice_bob.id
  })
  |> Signing.sign_commit(bob.priv, bob.signer)

:ok = CommitStore.import_commit(CommitStore, bob_commit)

all_cert_cids =
  [
    h_root_alice,
    h_alice_bob,
    f_root_alice,
    forged,
    o_root_alice,
    overbroad,
    s_root_alice,
    s_alice_bob,
    e_root_alice,
    e_alice_bob
  ]
  |> Enum.map(&hexid.(&1.id))

manifest = %{
  "node" => to_string(Node.self()),
  "root_pub_b64" => Signing.encode_key(root.pub),
  "all_cert_cids" => all_cert_cids,
  # keys so A can craft the hostile commits (demo-local; never real)
  "bob" => %{"priv" => Base.encode64(bob.priv), "pub" => Base.encode64(bob.pub)},
  "mallory" => %{"priv" => Base.encode64(mallory.priv), "pub" => Base.encode64(mallory.pub)},
  "happy" => %{"doc" => "d1", "leaf" => hexid.(h_alice_bob.id), "commit" => hexid.(bob_commit.id)},
  "attacks" => [
    %{
      "label" => "forged-sig cert",
      "doc" => "d2",
      "leaf" => hexid.(forged.id),
      "signer" => "bob",
      "expect" => "invalid_signature"
    },
    %{
      "label" => "over-broad cert (narrowing violation)",
      "doc" => "d3",
      "leaf" => hexid.(overbroad.id),
      "signer" => "bob",
      "expect" => "not_attenuation"
    },
    %{
      "label" => "stolen chain (commit-author binding)",
      "doc" => "d4",
      "leaf" => hexid.(s_alice_bob.id),
      "signer" => "mallory",
      "expect" => "capability_author_mismatch"
    },
    %{
      "label" => "expired cert",
      "doc" => "d5",
      "leaf" => hexid.(e_alice_bob.id),
      "signer" => "bob",
      "expect" => "expired"
    }
  ]
}

File.write!(Path.join(shared, "manifest.json"), Jason.encode!(manifest))
File.write!(Path.join(shared, "b_ready"), "ready\n")
IO.puts("[B] #{Node.self()} ready — certs stored, valid commit held, manifest written.")

# CP_AUTHOR_ONLY=1 exits immediately (for debugging the authoring logic
# without distribution / the hold). Normally B stays alive so A can pull.
unless System.get_env("CP_AUTHOR_ONLY") do
  receive do
    :never -> :ok
  after
    120_000 -> IO.puts("[B] timeout")
  end
end
