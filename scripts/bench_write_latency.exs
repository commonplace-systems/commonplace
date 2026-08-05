# CX-jfok acceptance datum (design §7 R2: "end-to-end write latency
# p50/p99 through the choke, against a real baseline"). Measures
# `create_chained_commit/5` wall latency against a throwaway CommitStore
# trio in a tmp data_dir.
#
# Run ONLY as `mix run --no-start scripts/bench_write_latency.exs` from
# the umbrella root. Plain `mix run` boots the application and, on a box
# with a live clustered serve, would let this throwaway node contend for
# :global singletons; `--no-start` keeps it purely local.
#
# Env knobs (all optional):
#   BENCH_N          — measured iterations (default 2000)
#   BENCH_WARMUP     — warmup iterations (default 100)
#   BENCH_DISPATCH   — "on" to run with the invariant dispatcher wired
#                      to a real Dispatcher; anything else leaves
#                      `:invariant_dispatcher` unset (choke dispatches to
#                      an unregistered name — the no-op path).
#   BENCH_DEBOUNCE_MS / BENCH_MIN_INTERVAL_MS — Dispatcher tuning, so a
#                      real validation run can be made to overlap the
#                      measurement window.
#   BENCH_LABEL      — printed alongside the numbers.

Application.ensure_all_started(:cubdb)
Application.ensure_all_started(:telemetry)
Application.ensure_all_started(:phoenix_pubsub)

# The write path broadcasts on `commits:`/`blue:`; under --no-start
# nothing has started the app's PubSub, so start a local one under the
# same name rather than teaching the store to tolerate its absence.
{:ok, _} = Phoenix.PubSub.Supervisor.start_link(name: Commonplace.PubSub)

n = String.to_integer(System.get_env("BENCH_N") || "2000")
warmup = String.to_integer(System.get_env("BENCH_WARMUP") || "100")
dispatch? = System.get_env("BENCH_DISPATCH") == "on"
label = System.get_env("BENCH_LABEL") || if(dispatch?, do: "dispatch-on", else: "dispatch-off")

dir = Path.join(System.tmp_dir!(), "cx_jfok_bench_#{System.unique_integer([:positive])}")
File.mkdir_p!(dir)

sup_name = :"bench_store_sup_#{System.unique_integer([:positive])}"
store = :"bench_commit_store_#{System.unique_integer([:positive])}"

dispatcher_name = :"bench_invariant_dispatcher_#{System.unique_integer([:positive])}"

{:ok, task_sup} = Task.Supervisor.start_link([])

bd_root = UUID.uuid4()

dispatcher_pid =
  if dispatch? do
    {:ok, pid} =
      Commonplace.Invariants.Dispatcher.start_link(
        name: dispatcher_name,
        enabled: true,
        task_supervisor: task_sup,
        debounce_ms: String.to_integer(System.get_env("BENCH_DEBOUNCE_MS") || "5"),
        min_interval_ms: String.to_integer(System.get_env("BENCH_MIN_INTERVAL_MS") || "10"),
        context_fn: fn -> {:ok, %{root_uuid: bd_root, store: store}} end
      )

    pid
  else
    nil
  end

store_opts =
  [
    data_dir: dir,
    name: sup_name,
    commit_store_name: store,
    trust_side_store_name: :"bench_tss_#{System.unique_integer([:positive])}",
    pending_imports_name: :"bench_pi_#{System.unique_integer([:positive])}",
    pending_imports_sweep_interval_ms: :infinity
  ] ++ if dispatch?, do: [invariant_dispatcher: dispatcher_name], else: []

{:ok, _sup} = Commonplace.Store.Supervisor.start_link(store_opts)

:rand.seed(:exsss, {42, 42, 42})
payload = :rand.bytes(100)

# Seed a REAL bd corpus so `dispatch=on` measures the store under a
# validation run that actually reads and decodes tickets. Without it the
# engine would enumerate an empty corpus and the "enabled" column would
# measure the dispatch plumbing only — a comparison that cannot go red.
if dispatch? do
  tickets = String.to_integer(System.get_env("BENCH_TICKETS") || "60")

  Commonplace.Store.CommitStore.create_commit(
    store,
    bd_root,
    Yelixer.Encoding.encode_update(Commonplace.Tree.Schema.new_schema()),
    nil
  )

  for i <- 1..tickets do
    {:ok, _issue, _} =
      Commonplace.Bd.Issue.create(bd_root, %{title: "bench ticket #{i}"}, store)
  end

  IO.puts("seeded #{tickets} bd tickets under #{bd_root}")
end

report = fn mode, samples ->
  sorted = Enum.sort(samples)

  pct = fn p ->
    idx = min(length(sorted) - 1, trunc(p * length(sorted)))
    Enum.at(sorted, idx)
  end

  IO.puts("""
  label=#{label} mode=#{mode} n=#{n} warmup=#{warmup} dispatch=#{dispatch?}
    p50 = #{pct.(0.50)} us
    p95 = #{pct.(0.95)} us
    p99 = #{pct.(0.99)} us
    max = #{Enum.max(sorted)} us
  """)
end

measure = fn doc_for ->
  for i <- 1..n do
    t0 = System.monotonic_time()
    Commonplace.Store.CommitStore.create_chained_commit(store, doc_for.(i), payload, %{})
    t1 = System.monotonic_time()
    System.convert_time_unit(t1 - t0, :native, :microsecond)
  end
end

# Mode "spread": each call lands on one of `@docs` docs round-robin, so
# every chain stays short and per-call latency is STABLE. This is the
# mode in which a per-write cost of the choke would be visible at all.
docs = 200

for i <- 1..warmup do
  Commonplace.Store.CommitStore.create_chained_commit(store, "bench-spread-#{rem(i, docs)}", payload, %{})
end

report.("spread-#{docs}-docs", measure.(fn i -> "bench-spread-#{rem(i, docs)}" end))

# Mode "single-doc": 2000 commits chained onto ONE doc, as specified in
# the CX-jfok brief. Per-call latency here grows with chain length
# (reconstruction cost inside the GenServer dominates), so its
# percentiles measure the chain, not the choke — recorded because the
# brief asks for it, read alongside "spread" rather than instead of it.
for _ <- 1..warmup do
  Commonplace.Store.CommitStore.create_chained_commit(store, "bench-doc-0000", payload, %{})
end

report.("single-doc", measure.(fn _ -> "bench-doc-0000" end))

if dispatcher_pid do
  IO.inspect(Commonplace.Invariants.Dispatcher.status(dispatcher_name), label: "dispatcher status")
end

File.rm_rf!(dir)
