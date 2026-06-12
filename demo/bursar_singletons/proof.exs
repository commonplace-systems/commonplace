# Move #4 (CX-tdkq.7) — LIVE proof: the :global singleton hazard is retired.
#
# Reproduces THE incident that motivated this move: a bare extra BEAM node
# booting :commonplace and joining the cluster. Under the old world, that
# node started its own {:global, MoveServer}/{:global, TickBot}; :global
# name-conflict resolution killed one of each pair arbitrarily — orphaning
# the singleton onto a node about to exit, or (netsplit) running two.
#
# Under green tokens:
#   1. serve node A boots with :bursar_on_boot — Bursar is the lock
#      authority, riding the store owner's designation. No :global names.
#   2. temp node B boots the app — NO bursar starts there (gate default
#      off), no :global registration happens, nothing is killed.
#   3. B fail-closed: before attaching, B's TickBot can't acquire
#      (:bursar_unavailable) → :not_leader, and moves deny.
#   4. B attaches like a CLI (set_remote_node) → its moves take green
#      tokens on A's Bursar THROUGH THE SEAM (GenServer.call over
#      distribution), audited in __bursar.log with B's holder id.
#   5. failover: A's TickBot leader is terminated; B's TickBot takes the
#      lease within TTL + sweep and becomes the cluster's ticker.
#
#   bash demo/bursar_singletons/run_proof.sh

say = fn msg -> IO.puts("[proof] " <> msg) end

fail = fn msg ->
  say.("FAIL — " <> msg)
  System.halt(1)
end

assert! = fn
  true, _msg -> :ok
  _, msg -> fail.(msg)
end

alias Commonplace.Green.Bursar
alias Commonplace.MUD.{Move, TickBot}
alias Commonplace.Store.CommitStore
alias Commonplace.Tree.Schema

unless Node.alive?(), do: fail.("run via run_proof.sh (needs distribution)")

tick_ttl = 3_000
sweep = 500

# ---- Node A: the serve node (lock authority) ----

dir_a = Path.join(System.tmp_dir!(), "cp_bursar_proof_a_#{:rand.uniform(1_000_000)}")
File.mkdir_p!(dir_a)

Application.put_env(:commonplace, :data_dir, dir_a)
Application.put_env(:commonplace, :bursar_on_boot, true)
Application.put_env(:commonplace, :tick_lease_ttl_ms, tick_ttl)
Application.put_env(:commonplace, :bursar_sweep_interval_ms, sweep)
Application.put_env(:commonplace, :snapshot_sweeper_enabled, false)

root_uuid = UUID.uuid4()
File.write!(Path.join(dir_a, "root"), root_uuid)

say.("A (#{node()}): booting :commonplace with :bursar_on_boot (scratch #{dir_a})")
{:ok, _} = Application.ensure_all_started(:commonplace)
CommitStore.create_commit(CommitStore, root_uuid, Yelixer.Encoding.encode_update(Schema.new_schema()), nil)

assert!.(Process.whereis(Bursar) != nil, "Bursar not supervised on A")
assert!.(Process.whereis(TickBot) != nil, "TickBot not supervised on A")
say.("A: Bursar #{inspect(Process.whereis(Bursar))} + TickBot #{inspect(Process.whereis(TickBot))} supervised, locally named")

globals = :global.registered_names()
assert!.(globals == [], ":global names registered: #{inspect(globals)}")
say.("A: :global.registered_names() == [] — no singleton registration to race")

# ---- A's TickBot takes the lease ----

assert!.(TickBot.tick_now() == :ok, "A's TickBot did not become leader")
{:held, %{holder: holder_a}} = Bursar.query(Bursar, "__singletons/tick_bot")
say.("A: tick lease held by #{inspect(holder_a)}")

# ---- A-side move under green tokens ----

mkdir = fn ->
  uuid = UUID.uuid4()
  CommitStore.create_commit(CommitStore, uuid, Yelixer.Encoding.encode_update(Schema.new_schema()), nil)
  uuid
end

thing = mkdir.()
room1 = mkdir.()
room2 = mkdir.()

add_entry = fn dir, name, child ->
  {:ok, commit} = CommitStore.latest_commit(CommitStore, dir)
  doc = Schema.new_schema()
  {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)
  doc = Schema.add_directory(doc, name, child)
  CommitStore.create_chained_commit(CommitStore, dir, Yelixer.Encoding.encode_update(doc))
end

add_entry.(room1, "relic.obj", thing)

assert!.(Move.move(thing, "relic.obj", room1, room2) == :ok, "A-side move failed")
say.("A: Move.move room1→room2 :ok under green tokens (no MoveServer anywhere)")

# ---- Node B: the bare temp node (THE incident) ----

dir_b = Path.join(System.tmp_dir!(), "cp_bursar_proof_b_#{:rand.uniform(1_000_000)}")
File.mkdir_p!(dir_b)
# B sees the same workspace root name; its store routes to A after attach.
File.write!(Path.join(dir_b, "root"), root_uuid)

say.("B: starting peer node (the bare-mix-run temp node that used to orphan the singletons)…")

{:ok, peer, node_b} =
  :peer.start_link(%{
    name: :bursar_proof_b,
    args: Enum.flat_map(:code.get_path(), fn p -> [~c"-pa", p] end)
  })

rpc = fn m, f, a -> :erpc.call(node_b, m, f, a) end

rpc.(Application, :put_env, [:commonplace, :data_dir, dir_b])
rpc.(Application, :put_env, [:commonplace, :tick_lease_ttl_ms, tick_ttl])
rpc.(Application, :put_env, [:commonplace, :snapshot_sweeper_enabled, false])
{:ok, _} = rpc.(Application, :ensure_all_started, [:commonplace])

say.("B (#{node_b}): :commonplace booted; connected nodes on A: #{inspect(Node.list(:connected))}")

assert!.(rpc.(Process, :whereis, [Bursar]) == nil, "temp node started its own Bursar")
say.("B: no Bursar started (gate default-off) — the lock authority stays unique")

globals_a = :global.registered_names()
globals_b = rpc.(:global, :registered_names, [])
assert!.(globals_a == [] and globals_b == [], "node join produced :global names: #{inspect({globals_a, globals_b})}")
say.("A+B: :global.registered_names() == [] on BOTH after join — nothing raced, nothing killed, nothing orphaned")

# ---- B before attach: fail-closed ----

assert!.(rpc.(TickBot, :tick_now, []) == :not_leader, "unattached temp node ticked!")
say.("B: TickBot :not_leader (no bursar route — fail-closed idle)")

deny = rpc.(Move, :move, [thing, "relic.obj", room2, room1])
assert!.(deny == {:error, :bursar_unavailable}, "unattached move was not denied: #{inspect(deny)}")
say.("B: Move.move → {:error, :bursar_unavailable} — never moves unlocked")

# ---- B attaches like a CLI and works through the seam ----

:ok = rpc.(Commonplace.Store.CommitStoreClient, :set_remote_node, [node()])
say.("B: attached (set_remote_node #{node()}) — store AND bursar now route to A")

assert!.(rpc.(Move, :move, [thing, "relic.obj", room2, room1]) == :ok, "B-side move through the seam failed")
say.("B: Move.move room2→room1 :ok — green tokens acquired on A's Bursar over distribution")

# ---- Failover: A's leader goes away; B takes over within TTL ----

say.("A: terminating the TickBot leader permanently (simulating the leader's demise)…")
:ok = Supervisor.terminate_child(Commonplace.Supervisor, TickBot)
:ok = Supervisor.delete_child(Commonplace.Supervisor, TickBot)

assert!.(rpc.(TickBot, :tick_now, []) == :not_leader, "B led while A's lease was still live (double-hold!)")
say.("B: still :not_leader — the dead leader's lease is honored until TTL (no double-hold, only latency)")

started = System.monotonic_time(:millisecond)

result =
  Enum.reduce_while(1..200, :timeout, fn _, _ ->
    case rpc.(TickBot, :tick_now, []) do
      :ok -> {:halt, :leader}
      :not_leader -> Process.sleep(100) && {:cont, :timeout}
    end
  end)

elapsed = System.monotonic_time(:millisecond) - started
assert!.(result == :leader, "B never took over the tick lease")
assert!.(elapsed <= tick_ttl + sweep + 2_000, "failover took #{elapsed}ms (> TTL+sweep+slack)")

{:held, %{holder: holder_b}} = Bursar.query(Bursar, "__singletons/tick_bot")
say.("B: TOOK OVER the tick lease in #{elapsed}ms (TTL #{tick_ttl} + sweep #{sweep}) — holder #{inspect(holder_b)}")
assert!.(holder_b =~ "bursar_proof_b", "lease holder is not B: #{inspect(holder_b)}")

:peer.stop(peer)

say.("")
say.("PROOF COMPLETE:")
say.("  • zero :global registrations before/after a temp node joined — the split-brain surface is gone")
say.("  • temp node booted the app with no Bursar, idled fail-closed, denied unlocked moves")
say.("  • after CLI-style attach, its moves took green tokens on A through the BursarClient seam")
say.("  • leader death → failover bounded by lease TTL + sweep (#{elapsed}ms), never two leaders")
