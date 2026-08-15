Code.require_file(Path.join(__DIR__, "lib.exs"))
alias Commonplace.Document.DocRef
alias Commonplace.Identity.Root

runner = I5.load_ctx("runner")
child  = I5.load_ctx("child")
store  = I5.start_store!("d", [runner])
cert_id = File.read!(Path.join(I5.base(), "cert_id.b64")) |> Base.decode64!()
identity_root = File.read!(Path.join(I5.base(), "identity_root.txt"))
{:ok, root} = Root.read(identity_root, store)
{:ok, u_ref} = DocRef.parse(root["records"]["understanding"])

w = fn label, ctx, proof ->
  r = Root.write_record(u_ref, I5.merged(u_ref, store, %{"probe" => label}), store,
        signing_context: ctx, capability_proof: proof)
  I5.say(label, (match?({:ok, _}, r) && :WROTE) || r)
  match?({:ok, _}, r)
end

# Is the capability_proof checked AT ALL? A random 32 bytes is not a cert.
real   = w.("D_REAL_CERT", child, cert_id)
bogus  = w.("D_BOGUS_PROOF_RANDOM32", child, :crypto.strong_rand_bytes(32))
# And is the SCOPE checked? A cert scoped elsewhere would be the I1 arm.
I5.say("D_PROOF_IS_CHECKED", real != bogus)
