# Node A — the STRICT node, in a live attenuation demo.
#
# Real BEAM node. Pins ONLY the root anchor (root.pubkey). Demonstrates,
# over the REAL import path (CommitStore.import_commit, Gate A → the
# phase-3 capability path):
#   1. ACCEPTED — bob's commit, pulled cross-node from B via the real
#      NodeSync.catch_up, authorized by a root→alice→bob chain that
#      verifies to the pinned root, within bob's granted {write, d1}.
#   2-5. REJECTED — hostile commits delivered to A's import gate:
#      forged-sig cert, over-broad cert (narrowing violation), stolen
#      chain (commit-author binding), expired cert.
#
# Honest scope: this proves the strict node's import/sync gate enforces
# the capability chain. It is not a claim about cookie-holding cluster
# members — a BEAM cluster is one trust domain by design (§1). The certs
# A needs are fetched from B by CID over distribution (the federation
# envelope delivering cert bytes); the gate then verifies offline.
#
#   elixir --sname cpa --cookie <ck> -S mix run --no-start node_a.exs <dirA> <shared>

[data_dir, shared] = System.argv()
Application.put_env(:commonplace, :data_dir, data_dir)

alias Commonplace.Crypto.Signing
alias Commonplace.Store.{Commit, CommitStore}
alias Commonplace.Sync.NodeSync

{:ok, _} = Application.ensure_all_started(:phoenix_pubsub)
{:ok, _} = Application.ensure_all_started(:telemetry)

{:ok, _} =
  Supervisor.start_link([{Phoenix.PubSub, name: Commonplace.PubSub}], strategy: :one_for_one)

{:ok, _} = CommitStore.start_link(data_dir: data_dir, name: CommitStore)

# Wait for B's manifest.
Enum.reduce_while(1..240, nil, fn _, _ ->
  if File.exists?(Path.join(shared, "b_ready")),
    do: {:halt, :ok},
    else:
      (
        Process.sleep(250)
        {:cont, nil}
      )
end)

manifest = Path.join(shared, "manifest.json") |> File.read!() |> Jason.decode!()
b_node = String.to_atom(manifest["node"])

# STRICT: pin ONLY the root anchor.
Application.put_env(:commonplace, :trust, %{
  accept_unsigned: false,
  trusted_identities: %{"root" => manifest["root_pub_b64"]}
})

# Write the transcript to a STABLE path (survives the temp-dir cleanup
# and any wrapper signal), not under the reaped $SHARED.
log = System.get_env("SESSION_LOG", "/tmp/cp_att_session.log")
File.write!(log, "")

emit = fn s ->
  IO.puts(s)
  File.write!(log, s <> "\n", [:append])
end

hr = fn -> emit.(String.duplicate("-", 70)) end
kv = fn k, v -> emit.("    #{k}: #{inspect(v)}") end

verdict = fn ok, s ->
  emit.("  [#{if ok, do: "PASS", else: "FAIL"}] #{s}")
  ok
end

decode = fn hex ->
  {:ok, b} = Base.decode16(hex, case: :mixed)
  b
end

keypair = fn m ->
  {:ok, pub} = Base.decode64(m["pub"])
  {:ok, priv} = Base.decode64(m["priv"])
  {pub, priv}
end

# Capture trust rejections (the cert-path verdict surfaces here).
parent = self()

:telemetry.attach(
  "att-reject",
  [:commonplace, :commit, :rejected, :trust],
  fn _e, _m, meta, _c -> send(parent, {:reject, meta.doc_uuid, meta.reason}) end,
  nil
)

reason_for = fn doc ->
  receive do
    {:reject, ^doc, reason} -> reason
  after
    0 -> :no_rejection
  end
end

emit.("\nNODE A (strict) — live capability ATTENUATION demo")
kv.("A node", Node.self())
kv.("B node", b_node)
kv.("pinned anchor", "root (only)")
emit.("\n[A] connecting to peer B…")
kv.("Node.connect", Node.connect(b_node))

# Deliver the cert bytes: fetch every cert from B by CID and store locally
# (the federation envelope shipping the chain alongside the batch).
Enum.each(manifest["all_cert_cids"], fn hex ->
  cid = decode.(hex)
  {:ok, cap} = GenServer.call({CommitStore, b_node}, {:get_capability, cid})
  :ok = CommitStore.store_capability(CommitStore, cap)
end)

emit.("[A] fetched #{length(manifest["all_cert_cids"])} certs from B and stored them locally.")

hr.()
emit.("SCENARIO 1 — ACCEPTED: bob writes within his grant (pulled cross-node via catch_up)")
hr.()
happy = manifest["happy"]
# A ensures the doc's genesis locally so catch_up pulls only bob's commit
# (not the unsigned synthetic genesis).
{:ok, _} = CommitStore.ensure_genesis(CommitStore, happy["doc"])
{:ok, _} = NodeSync.catch_up(happy["doc"], b_node, CommitStore)
Process.sleep(200)

commit_id = decode.(happy["commit"])
accepted = match?({:ok, _}, CommitStore.get_commit(CommitStore, commit_id))
verdict.(accepted, "bob's in-scope commit ACCEPTED + persisted on A")

content =
  case Commonplace.Tree.DocBuilder.reconstruct_snapshot(CommitStore, happy["doc"]) do
    {:ok, d} -> Commonplace.Document.ContentType.get_content(d)
    other -> other
  end

kv.("doc content on A", content)

# The four attacks — hostile commits delivered to A's import gate.
{bob_pub, bob_priv} = keypair.(manifest["bob"])
{mal_pub, mal_priv} = keypair.(manifest["mallory"])
signer_keys = %{"bob" => {bob_pub, bob_priv}, "mallory" => {mal_pub, mal_priv}}

attack_results =
  Enum.map(manifest["attacks"], fn a ->
    hr.()
    emit.("SCENARIO — REJECTED: #{a["label"]}")
    hr.()
    {pub, priv} = signer_keys[a["signer"]]
    signer_id = Signing.signer_id(a["signer"], pub)

    commit =
      Commit.new(a["doc"], "hostile payload", nil, %{
        kind: :regular,
        capability_proof: decode.(a["leaf"])
      })
      |> Signing.sign_commit(priv, signer_id)

    ret = CommitStore.import_commit(CommitStore, commit)
    Process.sleep(50)
    reason = reason_for.(a["doc"])

    rejected =
      match?({:error, {:trust_rejected, _}}, ret) and
        :none == CommitStore.get_commit(CommitStore, commit.id)

    expected = String.to_atom(a["expect"])

    ok = rejected and reason == expected
    verdict.(ok, "#{a["label"]} → REJECTED with :#{a["expect"]}")
    kv.("import returned", ret)
    kv.("gate reason (telemetry)", reason)
    kv.("signed by", a["signer"])
    ok
  end)

hr.()
checks = [accepted | attack_results]
passed = Enum.count(checks, & &1)
emit.("\n#{passed}/#{length(checks)} live attenuation checks passed")

emit.("""

Honest scope: this proves the strict node's import/sync gate enforces the
capability chain — accepts a commit whose root→alice→bob delegation verifies
to the locally-pinned root and grants {write, d1}, and rejects forged,
over-broad (narrowing-violating), stolen-chain (author-binding), and expired
certs. It does NOT claim a cookie-holding cluster member is contained: a BEAM
cluster is one trust domain by design (trust-and-attenuation.md §1). The gate
defends the import seam; the certs travel by CID over that same seam.
""")

if passed == length(checks), do: System.halt(0), else: System.halt(1)
