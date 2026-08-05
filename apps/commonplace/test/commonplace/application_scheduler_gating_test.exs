defmodule Commonplace.ApplicationSchedulerGatingTest do
  @moduledoc """
  CX-x073: `Commonplace.Scheduler.Agent` is a complete, tested GenServer
  that nothing ever started — no application.ex entry, no non-test
  `start_link` caller in any app. Schedule requests on `agents/scheduler`
  got silence on every standard boot.

  It is now wired, DOUBLE-GATED (explicit opt-in + resolvable workspace
  root) and defaulting to OFF behind its own env var, because it fires
  timers and writes `__system/scheduler` — world-mutating, so separately
  stageable from "deploy the code" (the CX-0t2r lesson).

  The load-bearing assertion here is the DEFAULT-OFF one: shipping this
  wiring must change no existing boot. Every current launch omits the var
  and must behave exactly as before.
  """
  use ExUnit.Case, async: false

  setup do
    on_exit(fn -> Application.delete_env(:commonplace, :scheduler_on_boot) end)
    :ok
  end

  test "flag absent → no child (default off — no existing boot changes)" do
    Application.delete_env(:commonplace, :scheduler_on_boot)
    assert Commonplace.Application.scheduler_children() == []
  end

  test "flag false → no child" do
    Application.put_env(:commonplace, :scheduler_on_boot, false)
    assert Commonplace.Application.scheduler_children() == []
  end

  test "flag true but no resolvable workspace root → no child" do
    # The second half of the double gate. A test run or a bare `mix run`
    # that somehow set the flag still must not start an agent that would
    # write into a workspace it cannot resolve.
    Application.put_env(:commonplace, :scheduler_on_boot, true)

    case Commonplace.Workspace.root_uuid() do
      {:ok, _root} ->
        # This environment DOES have a resolvable root, so this arm can't
        # assert the no-root behaviour. Assert the other half instead and
        # say so, rather than silently passing on an untested condition.
        assert [_spec] = Commonplace.Application.scheduler_children()

      _ ->
        assert Commonplace.Application.scheduler_children() == []
    end
  end

  test "flag true + resolvable root → named permanent child spec" do
    Application.put_env(:commonplace, :scheduler_on_boot, true)

    case Commonplace.Workspace.root_uuid() do
      {:ok, root_uuid} ->
        assert [spec] = Commonplace.Application.scheduler_children()
        assert spec.id == Commonplace.Scheduler.Agent
        assert spec.restart == :permanent

        assert {Commonplace.Scheduler.Agent, :start_link, [[root_uuid: ^root_uuid, name: _]]} =
                 spec.start

      _ ->
        # No root resolvable here — the gate correctly yields nothing, and
        # the spec shape is covered by the arm above when a root exists.
        assert Commonplace.Application.scheduler_children() == []
    end
  end
end
