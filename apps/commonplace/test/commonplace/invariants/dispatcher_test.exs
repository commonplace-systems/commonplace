defmodule Commonplace.Invariants.DispatcherTest do
  @moduledoc """
  CX-jfok: the alarm path's own pins. Every test here injects a fake
  engine and a fake context so what is under test is the DISPATCH
  behaviour — coalescing, min-interval spacing, the disabled and
  no-workspace-root outcomes, and the three alarm outputs (log,
  telemetry, red event) — not the bd checks, which have their own tests.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Commonplace.Invariants.Dispatcher

  defmodule FakeEngine do
    @moduledoc false
    # The dispatcher runs the engine once PER DOMAIN in Registry.all()
    # (today :bd and :commit). Return the injected `result` for exactly one
    # domain (`:result_domain`, default :bd) so a fixture's violations are
    # not double-counted across domains; other domains return empty.
    def run(context, opts) do
      send(context.reply_to, {:engine_ran, opts})

      case context do
        %{result: result} ->
          if opts[:domain] == Map.get(context, :result_domain, :bd),
            do: result,
            else: %{results: %{}}

        _ ->
          %{results: %{}}
      end
    end
  end

  # A batch runs the engine once per domain, so drain all `:engine_ran`
  # messages for the batch we just observed before asserting the next one —
  # domain-count-agnostic, so adding a domain does not leave a straggler
  # that trips a later refute.
  defp assert_batch_ran(timeout \\ 1000) do
    assert_receive {:engine_ran, _}, timeout
    drain_engine_ran()
  end

  defp drain_engine_ran do
    receive do
      {:engine_ran, _} -> drain_engine_ran()
    after
      60 -> :ok
    end
  end

  defp start_dispatcher(opts) do
    name = :"invariant_dispatcher_#{System.unique_integer([:positive])}"

    defaults = [
      name: name,
      enabled: true,
      engine: FakeEngine,
      task_supervisor: start_task_supervisor(),
      debounce_ms: 30,
      min_interval_ms: 0,
      context_fn: fn -> {:ok, %{reply_to: self()}} end
    ]

    start_supervised!(
      Supervisor.child_spec({Dispatcher, Keyword.merge(defaults, opts)}, id: name)
    )

    name
  end

  defp start_task_supervisor do
    name = :"invariant_task_sup_#{System.unique_integer([:positive])}"
    start_supervised!(Supervisor.child_spec({Task.Supervisor, name: name}, id: name))
    name
  end

  defp advance(dispatcher, uuid \\ "doc-1") do
    GenServer.cast(
      dispatcher,
      {:advance, %{doc_uuid: uuid, commit_id: <<1>>, source: :write_commit}}
    )
  end

  describe "coalescing" do
    test "many rapid advances produce exactly one engine run" do
      # `context_fn` is evaluated in the TASK, so `self()` there is the
      # task; capture the test pid explicitly.
      me = self()
      d = start_dispatcher(context_fn: fn -> {:ok, %{reply_to: me}} end)

      for i <- 1..50, do: advance(d, "doc-#{i}")

      assert_batch_ran()
      refute_receive {:engine_ran, _}, 300

      assert %{runs: 1, pending_count: 0} = Dispatcher.status(d)
    end

    test "advances arriving during a run trigger a follow-up run" do
      me = self()

      d =
        start_dispatcher(
          context_fn: fn ->
            send(me, :context_built)
            {:ok, %{reply_to: me}}
          end
        )

      advance(d)
      assert_receive :context_built, 1000
      assert_batch_ran()

      advance(d)
      assert_batch_ran()

      assert %{runs: 2} = Dispatcher.status(d)
    end
  end

  describe "min_interval_ms" do
    test "a second burst inside the interval waits for it to elapse" do
      me = self()

      d =
        start_dispatcher(
          debounce_ms: 10,
          min_interval_ms: 400,
          context_fn: fn -> {:ok, %{reply_to: me}} end
        )

      advance(d)
      assert_batch_ran()

      advance(d)
      refute_receive {:engine_ran, _}, 200
      assert_batch_ran()

      assert %{runs: 2} = Dispatcher.status(d)
    end
  end

  describe "disabled" do
    test "advances are counted as dropped and nothing runs" do
      me = self()
      d = start_dispatcher(enabled: false, context_fn: fn -> {:ok, %{reply_to: me}} end)

      for _ <- 1..5, do: advance(d)

      refute_receive {:engine_ran, _}, 300

      assert %{enabled: false, dropped: 5, runs: 0, pending_count: 0} = Dispatcher.status(d)
    end
  end

  describe "context resolution" do
    test "a skipped context records the reason and runs no checks" do
      d = start_dispatcher(context_fn: fn -> {:skip, :no_workspace_root} end)

      advance(d)
      refute_receive {:engine_ran, _}, 300

      assert %{last_run_result: {:skipped, :no_workspace_root}, runs: 1} = Dispatcher.status(d)
    end

    test "a raising context_fn is caught, not a crash" do
      d = start_dispatcher(context_fn: fn -> raise "no root here" end)

      advance(d)

      assert %{last_run_result: {:skipped, {:context_raised, "no root here"}}} =
               eventually(fn ->
                 s = Dispatcher.status(d)
                 if s.last_run_result, do: s, else: nil
               end)

      assert Process.alive?(Process.whereis(d))
    end
  end

  describe "a violation alarms three ways" do
    setup do
      :ok = Commonplace.Dataflow.PubSub.subscribe_red("ticket-7")

      ref = make_ref()
      parent = self()

      :telemetry.attach(
        {:invariant_violation, ref},
        [:commonplace, :invariants, :violation],
        fn _e, meas, meta, _ -> send(parent, {:violation_telemetry, meas, meta}) end,
        nil
      )

      :telemetry.attach(
        {:invariant_run, ref},
        [:commonplace, :invariants, :run],
        fn _e, meas, meta, _ -> send(parent, {:run_telemetry, meas, meta}) end,
        nil
      )

      on_exit(fn ->
        :telemetry.detach({:invariant_violation, ref})
        :telemetry.detach({:invariant_run, ref})
      end)

      :ok
    end

    test "logs the full per-hit shape, emits telemetry, and broadcasts a red event" do
      me = self()

      result = %{
        results: %{
          bd_parses: %{
            violations: [%{subject: "ticket-7", reason: :undecodable, bytes: 41}],
            errors: []
          }
        }
      }

      d =
        start_dispatcher(context_fn: fn -> {:ok, %{reply_to: me, result: result}} end)

      log =
        capture_log(fn ->
          advance(d)
          assert_receive {:violation_telemetry, %{count: 1}, meta}, 1000
          assert meta.name == :bd_parses
          assert meta.subject == "ticket-7"
          assert meta.details == %{reason: :undecodable, bytes: 41}
          assert meta.mode == :alarm_only
        end)

      assert log =~ "bd_parses"
      assert log =~ "ticket-7"
      assert log =~ "undecodable"

      assert_receive {"red:ticket-7", {:invariant, :violation, red}}, 1000
      assert red.name == :bd_parses
      assert red.subject == "ticket-7"
      assert red.details == %{reason: :undecodable, bytes: 41}

      assert_receive {:run_telemetry, %{violations: 1, errors: 0}, _}, 1000
    end
  end

  defp eventually(fun, attempts \\ 50) do
    case fun.() do
      nil when attempts > 0 ->
        Process.sleep(20)
        eventually(fun, attempts - 1)

      other ->
        other
    end
  end
end
