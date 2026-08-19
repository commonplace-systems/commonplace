defmodule Commonplace.MUD.SafeVerb.Bounds do
  @moduledoc """
  CX-ndvi §3 — resource bounds for one safe-verb invocation: a
  supervised `Task` with a wall-clock timeout and a `max_heap_size` kill
  switch. Defense-in-depth, NOT containment (see
  `Commonplace.MUD.SafeVerb.Lint`'s honesty boundary — the same one
  applies here: reductions can't be capped natively on the BEAM, so
  timeout is the honest proxy for "this verb is stuck," not a hard
  CPU-time guarantee).

  Defaults (jes's locked values, build spec §3): `3_000`ms timeout,
  `50 * 1024 * 1024` bytes heap — both tunable per-world via
  `Application.get_env(:commonplace, :safe_verb_bounds, ...)`.

  A verb that runs past the timeout, or that grows its heap past the
  cap, is killed — the caller gets `{:error, :timeout}` or
  `{:error, {:heap_killed, reason}}` respectively. The session/caller
  process is never affected: the bounded work runs in a separate Task
  process, killed independently of the caller.
  """

  @default_timeout_ms 3_000
  @default_max_heap_bytes 50 * 1024 * 1024

  @doc """
  Run `fun.()` (a zero-arity function) inside a bounded, UNLINKED child
  process. Returns `{:ok, result}`, `{:error, :timeout}` (wall-clock
  budget exceeded — the child is killed), or
  `{:error, {:runtime_error, reason}}` (the child crashed, including a
  `max_heap_size` kill, whose exit reason is `:killed`).

  Deliberately `spawn_monitor/1`, NOT `Task.async/1`: `Task.async` LINKS
  the task to the caller, so a `max_heap_size` kill (or any crash) would
  propagate an `:EXIT` signal into the CALLER — exactly the "session
  survives" guarantee this module exists to provide would be violated
  by the very mechanism meant to provide it. `spawn_monitor` gives a
  `:DOWN` message instead of a linked crash, so the bounded work's death
  is fully contained to this function.
  """
  @spec run((-> term())) :: {:ok, term()} | {:error, term()}
  def run(fun) when is_function(fun, 0) do
    timeout_ms = Application.get_env(:commonplace, :safe_verb_timeout_ms, @default_timeout_ms)

    max_heap_bytes =
      Application.get_env(:commonplace, :safe_verb_max_heap_bytes, @default_max_heap_bytes)

    max_heap_words = div(max_heap_bytes, :erlang.system_info(:wordsize))

    parent = self()
    ref = make_ref()

    {pid, mon_ref} =
      spawn_monitor(fn ->
        Process.flag(:max_heap_size, %{size: max_heap_words, kill: true, error_logger: false})
        send(parent, {ref, :result, fun.()})
      end)

    receive do
      {^ref, :result, result} ->
        Process.demonitor(mon_ref, [:flush])
        {:ok, result}

      {:DOWN, ^mon_ref, :process, ^pid, reason} ->
        {:error, {:runtime_error, format_exit(reason)}}
    after
      timeout_ms ->
        Process.exit(pid, :kill)
        Process.demonitor(mon_ref, [:flush])
        # CX-cj3t.5 §1e (bounds mailbox-flush hygiene): `demonitor(:flush)`
        # only discards a PENDING `:DOWN` for `mon_ref` — it does nothing
        # about the child's OWN `{ref, :result, result}` message. Since
        # neither clause matched before the timeout fired, the child could
        # still deliver that message in the narrow window between the
        # `after` clause selecting and `Process.exit/2` landing (the child
        # finishes and `send/2`s right as the caller times out). Without
        # this flush that stray tuple sits in the CALLER's mailbox
        # forever — `ref` is a fresh `make_ref()` every call, so no later
        # `receive` in this process (including a subsequent verb's own
        # `Bounds.run/1`) will ever pattern-match it away on its own.
        # Harmless to future `receive`s (unique ref never re-matches) but
        # still a real per-timeout mailbox leak — drained here so a
        # session's mailbox stays clean across repeated timeouts.
        receive do
          {^ref, :result, _late_result} -> :ok
        after
          0 -> :ok
        end

        {:error, :timeout}
    end
  end

  defp format_exit(:killed), do: "process killed (likely max_heap_size bound exceeded)"
  defp format_exit(reason), do: inspect(reason)
end
