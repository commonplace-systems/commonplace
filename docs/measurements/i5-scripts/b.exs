Code.require_file(Path.join(__DIR__, "lib.exs"))
alias Commonplace.Runner.DeploymentRecord
alias Commonplace.Document.DocRef
alias Commonplace.Identity.Root

# B's ONLY inputs: key custody, the log's ADDRESS, the identity root's ADDRESS,
# and the cert id. All CONTENT must come from the store.
runner = I5.load_ctx("runner")
child  = I5.load_ctx("child")
log    = File.read!(Path.join(I5.base(), "log_uuid.txt"))
store  = I5.start_store!("b", [runner])
cert_id = File.read!(Path.join(I5.base(), "cert_id.b64")) |> Base.decode64!()
sign = [store: store, signing_context: runner]

I5.say("B_OS_PID", System.pid())

records = case DeploymentRecord.read(log, store) do
  {:ok, r} -> r
  other -> I5.say("B_READ_RESULT", other); []
end
I5.say("B_RECORDS_FOUND", length(records))

a_rec = Enum.find(records, &(&1["deployment_id"] == "deployment-a"))

if is_nil(a_rec) do
  I5.say("B_RECONSTRUCTION", :impossible_no_record_of_a)
  I5.say("B_RESULT", :FAILED)
  System.halt(3)
end

[yield_ref | _] = a_rec["yields"]
{:ok, yield} = DeploymentRecord.read_promoted(yield_ref, store)
I5.say("B_RESOLVED_YIELD_FROM_STORE", yield["value"])

identity_root = File.read!(Path.join(I5.base(), "identity_root.txt"))
{:ok, root} = Root.read(identity_root, store)
{:ok, u_ref} = DocRef.parse(root["records"]["understanding"])
I5.say("B_UNDERSTANDING_BEFORE", Root.read_record(u_ref, store) |> elem(1))

write_outcome =
  Root.write_record(u_ref,
    I5.merged(u_ref, store, %{"state" => "resolved", "written_by" => "deployment-b",
      "resolved_from_yield" => yield["value"]["next_step"]}),
    store, signing_context: child, capability_proof: cert_id)

I5.say("B_UNDERSTANDING_WRITE", (match?({:ok, _}, write_outcome) && :ok) || write_outcome)
I5.say("B_UNDERSTANDING_AFTER", Root.read_record(u_ref, store) |> elem(1))

{:ok, decision_ref} =
  DeploymentRecord.promote(:decision, "deployment-b",
    %{"resolved" => yield["value"]["next_step"], "by" => "deployment-b"}, "decisions/b.json", sign)

ref = DocRef.to_string(decision_ref)
rec = %{ask_ref: yield_ref, budget: %{tokens: 1000, money: 2.5, wall_seconds: 300},
  capability_proofs: [String.duplicate("a", 64)], cell_manifest_ref: ref, class_ref: ref,
  context_inputs: [yield_ref], decision_refs: [ref], deployment_id: "deployment-b",
  ended_at: "2026-08-15T13:05:00Z", finding_refs: [], identity_ref: ref, outputs: [ref],
  runtime_profile: %{model: "fixture-model", sandbox_profile: String.duplicate("b", 64),
                     tools_hash: String.duplicate("c", 64)},
  started_at: "2026-08-15T13:00:00Z", yields: []}

{:ok, w} = DeploymentRecord.append(log, rec, sign)
I5.say("B_RECORD_COMMIT", Base.encode16(w.commit_id, case: :lower) |> binary_part(0, 12))
I5.say("B_RESULT", :SUCCEEDED)
