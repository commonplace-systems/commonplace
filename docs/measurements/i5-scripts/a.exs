Code.require_file(Path.join(__DIR__, "lib.exs"))
alias Commonplace.Runner.DeploymentRecord
alias Commonplace.Document.DocRef
alias Commonplace.Identity.Root
alias Commonplace.Store.{Commit, CommitStoreClient}
alias Commonplace.Trust.Capability
alias Commonplace.Tree.Schema
alias Commonplace.WriterHand
alias Yelixer.Encoding

runner = I5.new_ctx("runner")           # the parent / issuer
child  = I5.new_ctx("child")            # the worker identity both deployments run as
store  = I5.start_store!("a", [runner])
log    = UUID.uuid4()
File.write!(Path.join(I5.base(), "log_uuid.txt"), log)
sign = [store: store, signing_context: runner]

ws_root = UUID.uuid4()
root_doc = Schema.new_schema(client_id: WriterHand.for_doc(ws_root))
%Commit{} = CommitStoreClient.create_commit(store, ws_root, Encoding.encode_update(root_doc),
              nil, %{kind: :regular}, signing_context: runner)

{:ok, root_srv} =
  Root.start_link(root_uuid: ws_root, name: "i5-worker", store: store, signing_context: runner,
    genesis: %{"created_by" => runner.identity_uuid, "birth_commit" => "i5-birth",
               "activation" => "i5-activation",
               "class_ref" => "classes/i5:00000000-0000-0000-0000-000000000001@i5-class-cid"},
    understanding: %{"state" => "fresh", "written_by" => "deployment-a"})

snap = Root.snapshot(root_srv)
u_ref = snap.records["understanding"]
File.write!(Path.join(I5.base(), "identity_root.txt"), snap.root_uuid)

# The parent→child cert. This is what revocation will later target.
{:ok, cert} =
  Capability.issue(runner, {child.identity_uuid, child.public_key},
    %{verbs: [:write], scope: {:subtree, u_ref.uuid}, caveats: %{}}, nil, store: store)
:ok = CommitStoreClient.store_capability(store, cert)
File.write!(Path.join(I5.base(), "cert_id.b64"), Base.encode64(cert.id))

{:ok, finding_ref} =
  DeploymentRecord.promote(:finding, "deployment-a",
    %{"observed" => "the artifact names three call sites", "severity" => "p1"},
    "findings/a.json", sign)

{:ok, yield_ref} =
  DeploymentRecord.promote(:yield, "deployment-a",
    %{"next_step" => "resolve the finding and record understanding", "priority" => 1},
    "yields/a.json", sign)

ref = DocRef.to_string(finding_ref)
rec = %{ask_ref: ref, budget: %{tokens: 1000, money: 2.5, wall_seconds: 300},
  capability_proofs: [String.duplicate("a", 64)], cell_manifest_ref: ref, class_ref: ref,
  context_inputs: [ref], decision_refs: [], deployment_id: "deployment-a",
  ended_at: "2026-08-15T12:05:00Z", finding_refs: [ref], identity_ref: ref, outputs: [],
  runtime_profile: %{model: "fixture-model", sandbox_profile: String.duplicate("b", 64),
                     tools_hash: String.duplicate("c", 64)},
  started_at: "2026-08-15T12:00:00Z", yields: [DocRef.to_string(yield_ref)]}

{:ok, w} = DeploymentRecord.append(log, rec, sign)

I5.say("A_OS_PID", System.pid())
I5.say("A_IDENTITY_ROOT", snap.root_uuid)
I5.say("A_UNDERSTANDING_AT_A", Root.read_record(u_ref, store) |> elem(1))
I5.say("A_RECORD_COMMIT", Base.encode16(w.commit_id, case: :lower) |> binary_part(0, 12))
I5.say("A_EXITS_NOW", true)
