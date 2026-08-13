defmodule Commonplace.Store.Supervisor do
  @moduledoc """
  R4c carve-out: supervises the CommitStore trio —
  `Commonplace.Store.CommitStore`, `Commonplace.Store.TrustSideStore`, and
  `Commonplace.Store.PendingImports` — as one unit.

  ## Why `:rest_for_one`, not `:one_for_one`

  `CommitStore.init/1` has a corruption-recovery path: if its CubDB probe
  fails on boot, it archives the corrupt directory and opens a FRESH CubDB
  (see `CommitStore`'s moduledoc, "CubDB crash recovery"). That produces a
  NEW db handle. `TrustSideStore` and `PendingImports` obtain their db
  handle (`TrustSideStore` does, via `CommitStore.db_handle/1`) or their
  target CommitStore reference at THEIR OWN `init/1` time — once, not on
  every call.

  Under `:one_for_one`, a CommitStore restart (whether from the corruption
  path or an ordinary crash) would leave TrustSideStore and PendingImports
  running unchanged, pointed at a stale db handle / a CommitStore pid that
  no longer serves anything (or worse, at an archived dead db). Under
  `:rest_for_one`, CommitStore restarting kills and restarts everything
  AFTER it in the child list (TrustSideStore, then PendingImports), each of
  which re-resolves its handle/reference from scratch in its own `init/1`.
  "CommitStore restarted ⇒ its dependents restart and re-resolve the
  handle" is therefore a STRUCTURAL guarantee of the supervision tree, not
  something that has to be remembered or hoped for.

  Child order matters for the same reason: CommitStore MUST start (and be
  ready to serve `db_handle/1`) before TrustSideStore's `init/1` runs.

  ## Test isolation

  Every child accepts a custom name via opts (mirroring how
  `CommitStore.start_link/1` already supports a custom `:name` for
  isolated test instances), so multiple trios can run concurrently under
  distinct names in the same test suite.
  """

  use Supervisor

  alias Commonplace.Store.{CommitStore, PendingImports, TrustSideStore}

  @doc """
  Start the trio under this supervisor.

  Options:

    * `:data_dir` (required) — passed through to `CommitStore`.
    * `:name` — this supervisor's own registered name (default `__MODULE__`).
    * `:commit_store_name`, `:trust_side_store_name`, `:pending_imports_name`
      — registered names for each child (default to the bare module names).
    * `:pending_imports_sweep_interval_ms` — overrides PendingImports'
      periodic sweep interval (see that module's moduledoc); pass
      `:infinity` to disable the sweep (useful for tests asserting on
      notification-only behavior).
    * `:invariant_dispatcher` — CX-jfok: the registered name CommitStore's
      head-advance choke casts to. Omitting it leaves CommitStore's own
      default (`Commonplace.Invariants.Dispatcher`) in place; tests inject
      a probe process name here.
    * `:local_write_gate` — optional store-local gate override. When absent,
      the CommitStore preserves the ambient application configuration.
  """
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    data_dir = Keyword.fetch!(opts, :data_dir)
    commit_store_name = Keyword.get(opts, :commit_store_name, CommitStore)
    trust_side_store_name = Keyword.get(opts, :trust_side_store_name, TrustSideStore)
    pending_imports_name = Keyword.get(opts, :pending_imports_name, PendingImports)

    pending_imports_opts =
      [name: pending_imports_name, commit_store: commit_store_name] ++
        case Keyword.fetch(opts, :pending_imports_sweep_interval_ms) do
          {:ok, ms} -> [sweep_interval_ms: ms]
          :error -> []
        end

    commit_store_opts =
      [
        data_dir: data_dir,
        name: commit_store_name,
        trust_side_store: trust_side_store_name,
        pending_imports: pending_imports_name
      ] ++
        case Keyword.fetch(opts, :local_write_gate) do
          {:ok, gate} -> [local_write_gate: gate]
          :error -> []
        end ++
        case Keyword.fetch(opts, :invariant_dispatcher) do
          {:ok, dispatcher} -> [invariant_dispatcher: dispatcher]
          :error -> []
        end

    children = [
      {CommitStore, commit_store_opts},
      {TrustSideStore,
       name: trust_side_store_name,
       commit_store: commit_store_name,
       pending_imports: pending_imports_name},
      {PendingImports, pending_imports_opts}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
