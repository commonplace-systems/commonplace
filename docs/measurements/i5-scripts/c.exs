Code.require_file(Path.join(__DIR__, "lib.exs"))
alias Commonplace.Runner.DeploymentRecord
alias Commonplace.Document.DocRef
alias Commonplace.Identity.Root
alias Commonplace.Store.CommitStoreClient
alias Commonplace.Trust.Capability

runner = I5.load_ctx("runner")
child  = I5.load_ctx("child")
log    = File.read!(Path.join(I5.base(), "log_uuid.txt"))
store  = I5.start_store!("c", [runner])
cert_id = File.read!(Path.join(I5.base(), "cert_id.b64")) |> Base.decode64!()
identity_root = File.read!(Path.join(I5.base(), "identity_root.txt"))

{:ok, root} = Root.read(identity_root, store)
{:ok, u_ref} = DocRef.parse(root["records"]["understanding"])

I5.say("C_OS_PID", System.pid())

# DISCRIMINATOR: was the revocation NEVER CONSULTED, or CONSULTED AND IGNORED?
# Those are different defects. The tree already instruments the second.
:telemetry.attach_many("i5-rev", [
  [:commonplace, :trust, :revocation, :ignored],
  [:commonplace, :trust, :revocation, :honored]
], fn name, _m, meta, _ -> IO.puts("C_TELEMETRY=#{inspect(name)} #{inspect(Map.take(meta, [:reason, :revoked_cid, :gate]))}") end, nil)

# Control FIRST: the write path works BEFORE revocation, so a post-revocation
# refusal cannot be "it never worked".
pre =
  Root.write_record(u_ref, I5.merged(u_ref, store, %{"state" => "pre-revocation probe"}),
    store, signing_context: child, capability_proof: cert_id)
I5.say("C_WRITE_BEFORE_REVOCATION", (match?({:ok, _}, pre) && :ok) || pre)

{:ok, rev} = Capability.revoke(runner, cert_id)
:ok = CommitStoreClient.store_revocation(store, rev)
I5.say("C_REVOCATION_STORED", CommitStoreClient.get_revocations(store, cert_id) |> length())

post =
  Root.write_record(u_ref, I5.merged(u_ref, store, %{"state" => "post-revocation attempt"}),
    store, signing_context: child, capability_proof: cert_id)
I5.say("C_WRITE_AFTER_REVOCATION", (match?({:ok, _}, post) && :ok) || :REFUSED)
I5.say("C_WRITE_OUTCOMES_DIFFER", match?({:ok, _}, pre) and not match?({:ok, _}, post))

# After revocation: identity, findings and history must remain READABLE and
# ATTRIBUTABLE — demonstrated, not asserted.
{:ok, root_after} = Root.read(identity_root, store)
I5.say("C_IDENTITY_READABLE_AFTER", root_after["genesis"]["created_by"] == runner.identity_uuid)
I5.say("C_UNDERSTANDING_READABLE_AFTER", Root.read_record(u_ref, store) |> elem(1))

{:ok, recs} = DeploymentRecord.read(log, store)
I5.say("C_HISTORY_READABLE_AFTER", Enum.map(recs, & &1["deployment_id"]))

a_rec = Enum.find(recs, &(&1["deployment_id"] == "deployment-a"))
{:ok, finding} = DeploymentRecord.read_promoted(hd(a_rec["finding_refs"]), store)
I5.say("C_FINDING_READABLE_AFTER", finding["value"])
I5.say("C_FINDING_ATTRIBUTABLE_TO", finding["deployment_id"])
