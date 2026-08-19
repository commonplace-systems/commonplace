# Node A — the STRICT PULLING WORKSPACE, a separate trust domain.
#
# A plain OS process: NO --sname, NO cookie, NO epmd, NO BEAM
# distribution — Node B is just an HTTPS-shaped URL to us. A pins ONE
# thing: the root's public key. Everything else is proven on arrival:
#
#   ACCEPT — the agent's in-scope commit: signature verifies, its cert
#            chain (inlined in the envelope) verifies to the pinned
#            root, the commit-author binding holds, the scope grants
#            {write, doc}. Lands through the UNCHANGED strict Gate A.
#   REJECT — the same agent's OUT-of-scope commit (cert never granted
#            that doc): capability_insufficient.
#   REJECT — mallory-bot's commit (validly signed, no cert):
#            untrusted_signer.
#   403    — a wrong bearer token never even gets to talk.
#
#   elixir -S mix run --no-start node_a.exs <dirA> <shared>

[data_dir, shared] = System.argv()
Application.put_env(:commonplace, :data_dir, data_dir)

alias Commonplace.Federation.PullClient
alias Commonplace.Store.CommitStore

{:ok, _} = Application.ensure_all_started(:phoenix_pubsub)
{:ok, _} = Application.ensure_all_started(:telemetry)
{:ok, _} = Application.ensure_all_started(:req)

{:ok, _} =
  Supervisor.start_link([{Phoenix.PubSub, name: Commonplace.PubSub}], strategy: :one_for_one)

{:ok, _} = CommitStore.start_link(data_dir: data_dir, name: CommitStore)

log_path = System.get_env("SESSION_LOG", "/tmp/cp_fed_real_session.log")
File.write!(log_path, "")

say = fn msg ->
  line = "[A] " <> msg
  IO.puts(line)
  File.write!(log_path, line <> "\n", [:append])
end

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

# STRICT: pin ONLY the root anchor. No agent keys, no node keys of B —
# the cert chain must do all the work.
Application.put_env(:commonplace, :trust, %{
  accept_unsigned: false,
  trusted_identities: %{"jes-root" => manifest["root_pub_b64"]}
})

say.("strict workspace up — pinned ONLY jes-root's pubkey; B is just a URL")

peer = %{
  name: "node-b",
  base_url: "http://127.0.0.1:#{manifest["port"]}",
  token: manifest["token"],
  docs: [manifest["doc_in_scope"], manifest["doc_out_of_scope"], manifest["doc_uncertified"]]
}

say.("pulling 3 docs from #{peer.base_url} over plain HTTP (no cookie, no distribution)…")
report = PullClient.pull_once([peer], store: CommitStore)

say.(
  "pull report: imported=#{report.imported} rejected=#{report.rejected} deferred=#{report.deferred} errors=#{length(report.errors)}"
)

Enum.each(report.errors, fn e -> say.("  error: #{inspect(e, limit: 6)}") end)

# --- verdicts ---
{:ok, in_scope_id} = Base.decode64(manifest["in_scope_commit_id_b64"])

ok1 =
  case CommitStore.get_commit(CommitStore, in_scope_id) do
    {:ok, landed} ->
      say.("ACCEPT ✅ in-scope agent commit LANDED — signer #{landed.signer_id}")
      say.("         its cert chain traveled in the envelope and verified to the pinned root")
      true

    :none ->
      say.("FAIL ❌ in-scope commit did not land")
      false
  end

reject = fn doc, label ->
  ids = CommitStore.commit_ids_for_doc(CommitStore, doc)

  if MapSet.size(ids) == 0 do
    say.("REJECT ✅ #{label} — nothing landed (strict Gate A refused it)")
    true
  else
    say.("FAIL ❌ #{label} — #{MapSet.size(ids)} commit(s) landed but should have been refused")
    false
  end
end

ok2 =
  reject.(manifest["doc_out_of_scope"], "agent's OUT-of-scope commit (capability_insufficient)")

ok3 = reject.(manifest["doc_uncertified"], "mallory-bot's uncertified commit (untrusted_signer)")

# --- wrong token: turned away at the transport door ---
bad_report = PullClient.pull_once([%{peer | token: "wrong-token"}], store: CommitStore)

ok4 =
  case bad_report.errors do
    [{_, _, {:http_status, 403}} | _] ->
      say.("403   ✅ wrong bearer token never got to talk (online layer ≠ import gate)")
      true

    other ->
      say.("FAIL ❌ wrong-token pull returned #{inspect(other)}")
      false
  end

say.("")

if ok1 and ok2 and ok3 and ok4 do
  say.("DEMO PASSED — federation for real: two OS processes, two trust domains,")
  say.("one pinned root, and a dumb HTTP pipe. Authorization lives at the gate.")
else
  say.("DEMO FAILED — see above")
  System.halt(1)
end
