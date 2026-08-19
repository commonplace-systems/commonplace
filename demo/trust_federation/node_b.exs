# Node B — the PEER (a potentially-malicious federation partner).
#
# Runs as a real BEAM node. Holds, in its own CommitStore, the commits
# that strict Node A will pull via the real catch-up sync path:
#   1. doc-signed   — a data commit SIGNED by a user A trusts
#   2. doc-unsigned — an UNSIGNED data commit (the forgery/no-signer case)
#   3. code-evil    — an UNSIGNED code doc whose compute/2 shells out
#
# B is permissive, so it stores all three. The trust decision happens on
# A's side, on import. B writes a manifest A reads to know what to pull
# and which signer key to pin.
#
# Launched by run_demo.sh as:
#   elixir --sname cpb --cookie <ck> -S mix run node_b.exs <dirB> <shared>

[data_dir, shared] = System.argv()
Application.put_env(:commonplace, :data_dir, data_dir)

alias Commonplace.Crypto.Signing
alias Commonplace.Store.{Commit, CommitStore}
alias Commonplace.Document.ContentType
alias Yelixer.{Doc, Encoding}

{:ok, _} = Application.ensure_all_started(:phoenix_pubsub)
{:ok, _} = Application.ensure_all_started(:telemetry)

{:ok, _} =
  Supervisor.start_link([{Phoenix.PubSub, name: Commonplace.PubSub}], strategy: :one_for_one)

{:ok, _} = CommitStore.start_link(data_dir: data_dir, name: CommitStore)

# The user identity A will trust. B holds the private key only to author
# the signed commit; A pins only the PUBLIC key.
{trusted_pub, trusted_priv} = Signing.generate_keypair()
trusted_id = "alice-trusted-writer"
trusted_signer = Signing.signer_id(trusted_id, trusted_pub)

text_update = fn s ->
  doc = Doc.new(client_id: 7)
  doc = ContentType.create(doc, :text, "note.txt")
  doc = ContentType.insert_text(doc, 0, s)
  Encoding.encode_update(doc)
end

code_update = fn src ->
  doc = Doc.new(client_id: 7)
  doc = ContentType.create(doc, :text, "_evil.ex")
  doc = ContentType.insert_text(doc, 0, src)
  Encoding.encode_update(doc)
end

# 1. SIGNED by the trusted user.
u_signed = "doc-signed"

c_signed =
  Commit.new(u_signed, text_update.("hello from a trusted writer"), nil)
  |> Signing.sign_commit(trusted_priv, trusted_signer)

:ok = CommitStore.import_commit(CommitStore, c_signed)

# 2. UNSIGNED data commit (no accountable signer).
u_unsigned = "doc-unsigned"
c_unsigned = Commit.new(u_unsigned, text_update.("forged: no signature"), nil)
:ok = CommitStore.import_commit(CommitStore, c_unsigned)

# 3. UNSIGNED code doc that, if executed, would run an OS command.
evil_src = """
defmodule Commonplace.UserCode.Pwned do
  def compute(_raw, _ctx), do: System.cmd("echo", ["PWNED-BY-PEER"])
end
"""

u_code = "code-evil"
c_code = Commit.new(u_code, code_update.(evil_src), nil)
:ok = CommitStore.import_commit(CommitStore, c_code)

manifest = %{
  "node" => to_string(Node.self()),
  "trusted_id" => trusted_id,
  "trusted_pub_b64" => Signing.encode_key(trusted_pub),
  "docs" => [
    %{
      "uuid" => u_signed,
      "commit" => Base.encode16(c_signed.id),
      "label" => "signed-by-trusted (data)"
    },
    %{
      "uuid" => u_unsigned,
      "commit" => Base.encode16(c_unsigned.id),
      "label" => "unsigned (data)"
    },
    %{
      "uuid" => u_code,
      "commit" => Base.encode16(c_code.id),
      "label" => "unsigned CODE (RCE attempt)"
    }
  ]
}

File.write!(Path.join(shared, "manifest.json"), Jason.encode!(manifest))
File.write!(Path.join(shared, "b_ready"), "ready\n")

IO.puts("[B] #{Node.self()} ready — authored 3 commits, manifest written. Holding for A to pull.")

# Stay alive so A can GenServer.call our CommitStore over distribution.
receive do
  :never -> :ok
after
  120_000 -> IO.puts("[B] timeout, exiting")
end
