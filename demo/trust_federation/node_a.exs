# Node A — the STRICT node defending its trust boundary.
#
# Real BEAM node. Configured strict (accept_unsigned: false), pinning the
# trusted user's public key (from B's manifest) + its own node identity
# (auto-trusted). Connects to B and pulls B's commits through the REAL
# federation path — Commonplace.Sync.NodeSync.catch_up, the same function
# Cluster.EventHandler calls on :nodeup — which lands each commit through
# CommitStore.import_commit, i.e. Gate A.
#
# Captures the ACTUAL observed behavior: telemetry rejections, what ends
# up in A's store, and Gate B's verdict on executing untrusted code.
#
#   elixir --sname cpa --cookie <ck> -S mix run node_a.exs <dirA> <shared>

[data_dir, shared] = System.argv()
Application.put_env(:commonplace, :data_dir, data_dir)

alias Commonplace.Crypto.Signing
alias Commonplace.Store.{Commit, CommitStore}
alias Commonplace.Code.SourceDoc
alias Commonplace.Document.ContentType
alias Commonplace.Sync.NodeSync
alias Yelixer.{Doc, Encoding}

{:ok, _} = Application.ensure_all_started(:phoenix_pubsub)
{:ok, _} = Application.ensure_all_started(:telemetry)

{:ok, _} =
  Supervisor.start_link([{Phoenix.PubSub, name: Commonplace.PubSub}], strategy: :one_for_one)

{:ok, _} = CommitStore.start_link(data_dir: data_dir, name: CommitStore)

# Wait for B's manifest.
manifest_path = Path.join(shared, "manifest.json")

Enum.reduce_while(1..120, nil, fn _, _ ->
  if File.exists?(Path.join(shared, "b_ready")),
    do: {:halt, :ok},
    else:
      (
        Process.sleep(250)
        {:cont, nil}
      )
end)

manifest = manifest_path |> File.read!() |> Jason.decode!()
b_node = String.to_atom(manifest["node"])

# STRICT config: pin the trusted user's pubkey. (A also auto-trusts its
# own node identity via Trust.config/0 — irrelevant here, B's commits are
# either trusted-user-signed or unsigned.)
Application.put_env(:commonplace, :trust, %{
  accept_unsigned: false,
  trusted_identities: %{manifest["trusted_id"] => manifest["trusted_pub_b64"]}
})

defmodule D do
  @log System.get_env("SESSION_LOG", "/tmp/cp_fed_session.log")
  def init, do: File.write!(@log, "")

  defp emit(s),
    do:
      (
        IO.puts(s)
        File.write!(@log, s <> "\n", [:append])
      )

  def hr, do: emit(String.duplicate("-", 64))
  def say(s), do: emit(s)
  def kv(k, v), do: emit("    #{k}: #{inspect(v)}")

  def verdict(ok, s) do
    mark = if ok, do: "PASS", else: "FAIL"
    emit("  [#{mark}] #{s}")
    ok
  end

  # Render a compile/import result without dumping raw binary commit ids
  # (which turn the stream binary and break downstream grep).
  def fmt({:ok, mod}), do: "{:ok, #{inspect(mod)}}"

  def fmt({:error, {:execution_denied, {:untrusted_contributor, id, reason}}}),
    do:
      "{:error, {:execution_denied, {:untrusted_contributor, #{short(id)}, #{inspect(reason)}}}}"

  def fmt({:error, other}), do: "{:error, #{inspect(other)}}"
  def fmt(other), do: inspect(other)
  defp short(id) when is_binary(id), do: Base.encode16(id) |> binary_part(0, 12) |> Kernel.<>("…")
  defp short(id), do: inspect(id)
end

# Capture Gate A trust rejections as they actually fire.
parent = self()

:telemetry.attach(
  "a-trust-reject",
  [:commonplace, :commit, :rejected, :trust],
  fn _e, _m, meta, _c -> send(parent, {:trust_reject, meta}) end,
  nil
)

D.init()
D.say("\nNODE A (strict) — federation trust boundary live test")
D.kv("A node", Node.self())
D.kv("B node", b_node)
D.kv("accept_unsigned", false)
D.kv("pinned trusted writer", manifest["trusted_id"])

D.say("\n[A] connecting to peer B…")
connected = Node.connect(b_node)
D.kv("Node.connect", connected)

docs = manifest["docs"]

D.hr()
D.say("PART 1 — commit-level: pull B's commits via real catch-up sync (Gate A)")
D.hr()

# Pull each doc from B through the real sync path. catch_up fetches the
# commits A is missing and lands them via import_commit (Gate A).
Enum.each(docs, fn d -> {:ok, _} = NodeSync.catch_up(d["uuid"], b_node, CommitStore) end)
Process.sleep(300)

# Drain captured trust-rejection telemetry.
rejections =
  Stream.repeatedly(fn ->
    receive do
      {:trust_reject, meta} -> meta
    after
      0 -> nil
    end
  end)
  |> Enum.take_while(&(&1 != nil))

D.say("\n  Gate A rejections actually emitted during sync:")
Enum.each(rejections, fn m -> D.kv("rejected", {m.doc_uuid, m.reason}) end)

results =
  Enum.map(docs, fn d ->
    {:ok, id} = Base.decode16(d["commit"])
    stored = CommitStore.get_commit(CommitStore, id)
    {d, stored}
  end)

D.say("\n  Did each commit land in A's store?")
[signed_r, unsigned_r, code_r] = results

p1a =
  D.verdict(
    match?({:ok, _}, elem(signed_r, 1)),
    "signed-by-trusted DATA commit → ACCEPTED + persisted"
  )

D.kv(
  "get_commit",
  elem(signed_r, 1)
  |> case do
    {:ok, _} -> :present
    o -> o
  end
)

p1b =
  D.verdict(
    elem(unsigned_r, 1) == :none,
    "unsigned DATA commit → REJECTED at Gate A, NOT persisted"
  )

D.kv("get_commit", elem(unsigned_r, 1))

# Prove the signed commit's content is actually readable on A (applied).
applied =
  case Commonplace.Tree.DocBuilder.reconstruct_snapshot(CommitStore, "doc-signed") do
    {:ok, doc} -> ContentType.get_content(doc)
    other -> other
  end

p1c =
  D.verdict(applied == "hello from a trusted writer", "accepted commit's content is live on A")

D.kv("content", applied)

D.hr()
D.say("PART 2 — RCE: an unsigned CODE doc from the peer must never execute (Gate A + Gate B)")
D.hr()

# First line of defense: the unsigned code commit was rejected at Gate A
# on import, so it never even reached A's store.
code_present = match?({:ok, _}, elem(code_r, 1))

p2a =
  D.verdict(
    not code_present,
    "peer's unsigned code doc was REJECTED at import — never stored on A"
  )

D.kv("get_commit(code-evil)", elem(code_r, 1))

compiled_attack = SourceDoc.compile("code-evil", CommitStore)

p2b =
  D.verdict(
    match?({:error, _}, compiled_attack),
    "SourceDoc.compile(code-evil) fails — the RCE never runs"
  )

D.kv("compile result", D.fmt(compiled_attack))

# Defense in depth: even if an unsigned code doc were already PRESENT on A
# (e.g. authored locally before strict mode), Gate B refuses to run it.
# Local creates are not import-gated, so we can place one and point Gate B
# at it — proving the execute gate itself, not just the import gate.
local_evil = """
defmodule Commonplace.UserCode.LocalEvil do
  def compute(_raw, _ctx), do: System.cmd("echo", ["PWNED-LOCAL"])
end
"""

ldoc = Doc.new(client_id: 9)
ldoc = ContentType.create(ldoc, :text, "_local.ex")
ldoc = ContentType.insert_text(ldoc, 0, local_evil)

CommitStore.create_chained_commit(CommitStore, "code-local-evil", Encoding.encode_update(ldoc), %{
  kind: :regular
})

gateb = SourceDoc.compile("code-local-evil", CommitStore)

p2c =
  D.verdict(
    match?({:error, {:execution_denied, _}}, gateb),
    "Gate B refuses an unsigned code doc even when present: {:execution_denied, …}"
  )

D.kv("compile result", D.fmt(gateb))

D.hr()
checks = [p1a, p1b, p1c, p2a, p2b, p2c]
passed = Enum.count(checks, & &1)
D.say("\n#{passed}/#{length(checks)} live federation checks passed")

D.say("""

Honest scope: this proves an untrusted commit/code arriving over the
sync/import path is REJECTED by the strict node — the federation defense.
It does NOT claim a cookie-holding cluster member is contained: a BEAM
cluster shares the distribution cookie and is ONE trust domain by design
(see trust-and-attenuation.md §1). The gate defends the import seam; a
distinct federation transport is future work.
""")

File.write!(Path.join(shared, "a_done"), "#{passed}/#{length(checks)}\n")
if passed == length(checks), do: System.halt(0), else: System.halt(1)
