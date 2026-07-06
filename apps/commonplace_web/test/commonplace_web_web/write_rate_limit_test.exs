defmodule CommonplaceWebWeb.WriteRateLimitTest do
  @moduledoc """
  CX-qat5.6 (M1 safe subset): unit tests for the per-connection browser
  write rate limiter. Covers the sliding-window allow/reject/recover
  cycle, independence across connection keys, and memory eviction of
  idle keys.
  """
  use ExUnit.Case, async: false

  alias CommonplaceWebWeb.WriteRateLimit

  setup do
    sup = CommonplaceWeb.Supervisor
    _ = Supervisor.terminate_child(sup, WriteRateLimit)
    _ = Supervisor.delete_child(sup, WriteRateLimit)
    {:ok, _pid} = Supervisor.start_child(sup, WriteRateLimit)

    on_exit(fn ->
      _ = Supervisor.terminate_child(sup, WriteRateLimit)
      _ = Supervisor.delete_child(sup, WriteRateLimit)
      {:ok, _pid} = Supervisor.start_child(sup, WriteRateLimit)
    end)

    :ok
  end

  test "allows N writes in the window, rejects the N+1th" do
    :ok = WriteRateLimit.config(max_writes: 3, window_ms: 60_000)
    key = make_ref()

    assert :ok = WriteRateLimit.check_and_record(key)
    assert :ok = WriteRateLimit.check_and_record(key)
    assert :ok = WriteRateLimit.check_and_record(key)
    assert {:error, :rate_limited, retry_after_ms} = WriteRateLimit.check_and_record(key)
    assert is_integer(retry_after_ms) and retry_after_ms > 0
  end

  test "allows again after the window passes" do
    :ok = WriteRateLimit.config(max_writes: 1, window_ms: 50)
    key = make_ref()

    assert :ok = WriteRateLimit.check_and_record(key)
    assert {:error, :rate_limited, _} = WriteRateLimit.check_and_record(key)

    Process.sleep(60)

    assert :ok = WriteRateLimit.check_and_record(key)
  end

  test "two different connection keys are independent" do
    :ok = WriteRateLimit.config(max_writes: 1, window_ms: 60_000)
    key_a = make_ref()
    key_b = make_ref()

    assert :ok = WriteRateLimit.check_and_record(key_a)
    assert {:error, :rate_limited, _} = WriteRateLimit.check_and_record(key_a)

    # key_b's budget is untouched by key_a hitting its limit.
    assert :ok = WriteRateLimit.check_and_record(key_b)
  end

  test "idle keys are pruned from memory (eviction)" do
    :ok = WriteRateLimit.config(max_writes: 1, window_ms: 30)
    key = make_ref()

    assert :ok = WriteRateLimit.check_and_record(key)
    assert {:error, :rate_limited, _} = WriteRateLimit.check_and_record(key)
    assert WriteRateLimit.key_count() >= 1

    # Let the window lapse and the sweep run so the idle key is dropped.
    Process.sleep(40)
    :ok = WriteRateLimit.sweep()
    assert WriteRateLimit.key_count() == 0

    # Since the key was fully evicted (not just pruned-to-empty-in-place),
    # it gets a fresh full allowance rather than inheriting old state.
    assert :ok = WriteRateLimit.check_and_record(key)
  end
end
