defmodule Commonplace.MUD.SessionLimitTest do
  use ExUnit.Case, async: false

  alias Commonplace.MUD.SessionLimit

  setup do
    prior = Application.get_env(:commonplace, :mud_session_limit, [])
    Application.put_env(:commonplace, :mud_session_limit, max_total: 3, max_per_principal: 2)

    on_exit(fn ->
      if prior == [] do
        Application.delete_env(:commonplace, :mud_session_limit)
      else
        Application.put_env(:commonplace, :mud_session_limit, prior)
      end
    end)

    :ok
  end

  # SessionLimit is started unconditionally by the application
  # supervisor (see application.ex), so `__MODULE__` is already a live,
  # empty-at-boot singleton. Each test below relies on it being at 0/0
  # at start — tests run async: false and each cleans up its own slots
  # via release/DOWN, so there's no cross-test leakage.

  test "admit under caps returns {:ok, ref}; attach binds; count reflects it" do
    assert {:ok, ref} = SessionLimit.admit("alice")
    pid = spawn(fn -> receive do :stop -> :ok end end)
    assert :ok = SessionLimit.attach(ref, pid)

    assert %{total: total, by_principal: %{"alice" => 1}} = SessionLimit.count()
    assert total >= 1

    send(pid, :stop)
    wait_until(fn -> SessionLimit.count().total == total - 1 end)
  end

  test "per-principal cap blocks the (max_per_principal + 1)th admit for one principal, not others" do
    assert {:ok, ref1} = SessionLimit.admit("bob")
    assert {:ok, ref2} = SessionLimit.admit("bob")
    assert {:error, :session_limit} = SessionLimit.admit("bob")

    assert {:ok, ref3} = SessionLimit.admit("carol")

    SessionLimit.release(ref1)
    SessionLimit.release(ref2)
    SessionLimit.release(ref3)
  end

  test "total cap blocks admits across principals even for a fresh principal" do
    assert {:ok, ref1} = SessionLimit.admit("p1")
    assert {:ok, ref2} = SessionLimit.admit("p2")
    assert {:ok, ref3} = SessionLimit.admit("p3")

    assert {:error, :session_limit} = SessionLimit.admit("p4")

    SessionLimit.release(ref1)
    SessionLimit.release(ref2)
    SessionLimit.release(ref3)
  end

  test "auto-release on session death frees the slot" do
    assert {:ok, ref} = SessionLimit.admit("dana")
    pid = spawn(fn -> receive do :stop -> :ok end end)
    assert :ok = SessionLimit.attach(ref, pid)

    before = SessionLimit.count().total
    assert before >= 1

    send(pid, :stop)
    wait_until(fn -> SessionLimit.count().total == before - 1 end)

    # slot freed -> a fresh admit for the same principal succeeds again
    assert {:ok, ref2} = SessionLimit.admit("dana")
    SessionLimit.release(ref2)
  end

  test "release/1 frees a reserved-but-unattached slot" do
    assert {:ok, ref} = SessionLimit.admit("erin")
    before = SessionLimit.count().total
    assert :ok = SessionLimit.release(ref)
    assert SessionLimit.count().total == before - 1

    # releasing again is a no-op, not an error
    assert :ok = SessionLimit.release(ref)
  end

  test "caller-crash safety: reservation frees if the caller dies without attaching" do
    parent = self()

    caller =
      spawn(fn ->
        {:ok, ref} = SessionLimit.admit("frank")
        send(parent, {:admitted, ref})

        receive do
          :die -> :ok
        end

        # dies here without attach/release
      end)

    assert_receive {:admitted, _ref}, 1_000
    before = SessionLimit.count().total
    assert before >= 1

    send(caller, :die)
    wait_until(fn -> SessionLimit.count().total == before - 1 end)
  end

  defp wait_until(fun, tries \\ 50) do
    if fun.() do
      :ok
    else
      if tries <= 0 do
        flunk("condition not met in time")
      else
        Process.sleep(20)
        wait_until(fun, tries - 1)
      end
    end
  end
end
