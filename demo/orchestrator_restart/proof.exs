# CX-tdkq.12 Task 5 — LIVE crash-restart proof.
#
# Boots the REAL :commonplace application supervision tree with
# :orchestrator_on_boot enabled in a scratch workspace, declares a
# managed process, then KILLS the orchestrator and shows: supervisor
# restart → prior-generation sweep → re-reconcile → exactly ONE
# generation running.
#
#   elixir -S mix run --no-start demo/orchestrator_restart/proof.exs

dir = Path.join(System.tmp_dir!(), "cp_orch_proof_#{:rand.uniform(1_000_000)}")
File.mkdir_p!(dir)

say = fn msg -> IO.puts("[proof] " <> msg) end

Application.put_env(:commonplace, :data_dir, dir)
Application.put_env(:commonplace, :orchestrator_on_boot, true)
Application.put_env(:commonplace, :snapshot_sweeper_enabled, false)

# Workspace root must exist BEFORE boot (the gating reads it).
root_uuid = UUID.uuid4()
File.write!(Path.join(dir, "root"), root_uuid)

say.("booting the :commonplace application (orchestrator_on_boot: true, scratch workspace #{dir})")
{:ok, _} = Application.ensure_all_started(:commonplace)

alias Commonplace.Document.ContentType
alias Commonplace.Process.Orchestrator
alias Commonplace.Store.CommitStore
alias Commonplace.Tree.Schema

orch1 = Process.whereis(Orchestrator)
say.("orchestrator supervised on boot: #{inspect(orch1)}")
if orch1 == nil, do: (say.("FAIL — orchestrator not started"); System.halt(1))

# Seed the root schema + a declared :elixir process.
CommitStore.create_commit(CommitStore, root_uuid, Yelixer.Encoding.encode_update(Schema.new_schema()), nil)

put_doc = fn filename, content ->
  uuid = UUID.uuid4()
  doc = Yelixer.Doc.new()
  doc = ContentType.create(doc, :text, filename)
  doc = ContentType.insert_text(doc, 0, content)
  CommitStore.create_chained_commit(CommitStore, uuid, Yelixer.Encoding.encode_update(doc), %{kind: :regular})

  {:ok, latest} = CommitStore.latest_commit(CommitStore, root_uuid)
  root_doc = Schema.new_schema()
  {:ok, root_doc} = Yelixer.Encoding.apply_update(root_doc, latest.update)
  root_doc = Schema.add_file(root_doc, filename, uuid)
  CommitStore.create_chained_commit(CommitStore, root_uuid, Yelixer.Encoding.encode_update(root_doc))
end

put_doc.("proof.exs", """
defmodule Commonplace.UserProcess.ProofSleeper do
  use GenServer
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def init(opts), do: {:ok, opts}
end
""")

put_doc.("__processes.json", Jason.encode!(%{"proof_sleeper" => %{"mode" => "elixir", "source" => "proof.exs"}}))
say.("declared managed process 'proof_sleeper' in __processes.json")

await = fn orch ->
  Enum.reduce_while(1..120, nil, fn _, _ ->
    case Map.get(Orchestrator.running_processes(orch), "proof_sleeper") do
      pid when is_pid(pid) -> {:halt, pid}
      _ -> Process.sleep(250) && {:cont, nil}
    end
  end)
end

p1 = await.(orch1)
if p1 == nil, do: (say.("FAIL — proof_sleeper never started"); System.halt(1))
say.("generation 1: proof_sleeper running at #{inspect(p1)} (managed by #{inspect(orch1)})")

say.("")
say.(">>> KILLING the orchestrator (Process.exit(_, :kill)) — pre-move-#2 this was unrecoverable <<<")
Process.exit(orch1, :kill)
say.("")

orch2 =
  Enum.reduce_while(1..120, nil, fn _, _ ->
    case Process.whereis(Orchestrator) do
      nil -> Process.sleep(250) && {:cont, nil}
      pid when pid != orch1 -> {:halt, pid}
      _ -> Process.sleep(250) && {:cont, nil}
    end
  end)

if orch2 == nil, do: (say.("FAIL — supervisor did not restart the orchestrator"); System.halt(1))
say.("supervisor restarted the orchestrator: #{inspect(orch2)}")

p2 = await.(orch2)
if p2 == nil, do: (say.("FAIL — proof_sleeper not re-reconciled"); System.halt(1))

p1_dead = not Process.alive?(p1)
say.("generation 2: proof_sleeper running at #{inspect(p2)}")
say.("prior generation swept: p1 (#{inspect(p1)}) alive? #{Process.alive?(p1)}")
say.("exactly one generation: p2 != p1? #{p2 != p1}")

if p1_dead and p2 != p1 do
  say.("")
  say.("PROOF PASSED — crash → supervisor restart → sweep (no duplicate generation) → re-reconcile.")
  say.("The malleable-software engine now survives its own death.")
  System.halt(0)
else
  say.("PROOF FAILED")
  System.halt(1)
end
