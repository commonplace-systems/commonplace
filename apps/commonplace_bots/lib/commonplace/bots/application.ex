defmodule Commonplace.Bots.Application do
  @moduledoc """
  Top-level supervisor for the bot subsystem.

  Boots three things, one_for_one:

    * `Task.Supervisor` (`Commonplace.Bots.WorkerSupervisor`) —
      crash-isolation umbrella for ephemeral cave-diver worker tasks.
      Workers terminate cleanly when they exit; the supervisor's only
      job is to keep one crashing worker from taking down siblings.
    * `Commonplace.Bots.Dispatcher` — singleton GenServer that
      subscribes to magenta `chat:*:events` and spawns workers when
      bot triggers fire. (Started disabled by default at phase 1 —
      enabled in a later phase once the rest of the pieces are wired.)

  This is *not* an orchestrator-managed process (those compile from
  source-docs in the CRDT tree); bot-dispatcher is umbrella infra,
  sibling to `Commonplace.Sync.Agent`.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Task.Supervisor, name: Commonplace.Bots.WorkerSupervisor}
      # Dispatcher added in phase 3 once subscription + trigger wiring lands.
    ]

    opts = [strategy: :one_for_one, name: Commonplace.Bots.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
