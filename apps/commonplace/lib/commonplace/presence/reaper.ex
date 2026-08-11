defmodule Commonplace.Presence.Reaper do
  @moduledoc """
  Detects and executes owner-consented presence lease expiry.

  This is the lease family's first janitor. Presence owners sign an explicit
  TTL into each v1 presence record. The detector compares the signed heartbeat
  with those per-entry terms; the node then signs a scoped removal carrying
  `last_heartbeat`, `ttl_ms`, and `now`. `Commonplace.Trust` replays that commit
  and verifies both the evidence and the exact one-entry removal, so the node is
  an executor of pre-agreed authority rather than an ambient presence owner.

  ## Lease-family extension seam

  The named next member is **progress-witness lease expiry**. It plugs in at the
  lease-record inspection/evidence boundary represented by `inspect_entry/4`:
  provide its own signed terms and progress witness, then reuse the scoped
  janitor outcome discipline. It must not weaken the presence gate or introduce
  a generic node cleanup verb.

  The heartbeat is the liveness assertion. This process's scan interval is the
  detector cadence; it is not a TTL and never substitutes for owner terms.
  """

  use GenServer
  require Logger

  alias Commonplace.Crypto.NodeIdentity
  alias Commonplace.Presence
  alias Commonplace.Store.Commit
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.Schema
  alias Commonplace.Workspace

  @default_interval 15_000

  defstruct [:root_uuid, :store, :interval]

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Return expired entries with the evidence a scoped janitor commit will carry."
  def find_stale(root_uuid, store \\ CommitStoreClient, opts \\ []) do
    root_uuid
    |> inspect_entries(store, opts)
    |> Enum.flat_map(fn
      {:expired, candidate} -> [candidate]
      _ -> []
    end)
  end

  @doc """
  Reap expired entries and return verify-by-effect outcomes.

  Each result is `%{outcome: :landed | :denied | :skipped, name: ..., reason: ...}`.
  A name appears as `:landed` only when the commit store returned the commit that
  actually advanced the schema head.
  """
  def reap(root_uuid, store \\ CommitStoreClient, opts \\ []) do
    signing_context =
      Keyword.get_lazy(opts, :signing_context, fn ->
        case NodeIdentity.signing_context() do
          {:ok, ctx} -> ctx
          {:error, reason} -> {:unavailable, reason}
        end
      end)

    root_uuid
    |> inspect_entries(store, opts)
    |> Enum.flat_map(fn
      {:fresh, _entry} ->
        []

      {:skipped, entry, reason} ->
        [%{outcome: :skipped, name: entry.name, reason: reason}]

      {:expired, candidate} ->
        [execute_candidate(candidate, root_uuid, store, signing_context)]
    end)
  end

  @doc false
  def report_outcomes(outcomes), do: log_outcomes(outcomes)

  @impl true
  def init(opts) do
    state = %__MODULE__{
      root_uuid: Keyword.get(opts, :root_uuid),
      store: Keyword.get(opts, :store, CommitStoreClient),
      interval: Keyword.get(opts, :interval, @default_interval)
    }

    schedule_scan(state)
    {:ok, state}
  end

  @impl true
  def handle_info(:scan, state) do
    case current_root_uuid(state) do
      {:ok, root_uuid} ->
        root_uuid
        |> reap(state.store)
        |> log_outcomes()

      {:error, _reason} ->
        :ok
    end

    schedule_scan(state)
    {:noreply, state}
  end

  defp inspect_entries(root_uuid, store, opts) do
    root_doc = load_schema(root_uuid, store)
    now = Keyword.get(opts, :now, DateTime.utc_now())

    root_doc
    |> Presence.discover(:all)
    |> Enum.map(&inspect_entry(&1, root_uuid, store, now))
  end

  defp inspect_entry(entry, root_uuid, store, now) do
    case Presence.read(entry.node_id, store) do
      %{} = content -> inspect_presence(entry, root_uuid, content, now)
      _ -> {:skipped, entry, :presence_document_missing}
    end
  end

  defp inspect_presence(entry, root_uuid, content, now) do
    with {:ok, terms} <- Presence.lease_terms(content),
         heartbeat when is_binary(heartbeat) <- Map.get(content, "heartbeat"),
         {:ok, heartbeat_at, _offset} <- DateTime.from_iso8601(heartbeat) do
      age_ms = DateTime.diff(now, heartbeat_at, :millisecond)

      if age_ms > terms.ttl_ms do
        evidence = %{
          entry_name: entry.name,
          presence_uuid: entry.node_id,
          root_uuid: root_uuid,
          last_heartbeat: heartbeat,
          ttl_ms: terms.ttl_ms,
          now: DateTime.to_iso8601(now)
        }

        {:expired, %{entry: entry, evidence: evidence, lease: terms}}
      else
        {:fresh, entry}
      end
    else
      {:error, reason} -> {:skipped, entry, reason}
      _ -> {:skipped, entry, :presence_heartbeat_invalid}
    end
  end

  defp execute_candidate(candidate, _root_uuid, _store, {:unavailable, reason}) do
    %{outcome: :skipped, name: candidate.entry.name, reason: {:node_signer_unavailable, reason}}
  end

  defp execute_candidate(candidate, root_uuid, store, signing_context) do
    opts = [signing_context: signing_context, janitor_evidence: candidate.evidence]

    case Presence.remove(candidate.entry.name, root_uuid, store, opts) do
      %Commit{} = commit ->
        %{outcome: :landed, name: candidate.entry.name, commit_id: commit.id}

      {:error, reason} ->
        %{outcome: :denied, name: candidate.entry.name, reason: reason}

      other ->
        %{outcome: :denied, name: candidate.entry.name, reason: {:unexpected_write_result, other}}
    end
  end

  defp log_outcomes(outcomes) do
    landed = Enum.filter(outcomes, &(&1.outcome == :landed))

    if landed != [] do
      Logger.info(
        "Presence reaper landed #{length(landed)} expired entries: " <>
          Enum.map_join(landed, ", ", & &1.name)
      )
    end

    outcomes
    |> Enum.filter(&(&1.outcome == :denied))
    |> Enum.each(fn outcome ->
      Logger.error("Presence reaper DENIED #{outcome.name}: #{inspect(outcome.reason)}")
    end)

    outcomes
    |> Enum.filter(&(&1.outcome == :skipped))
    |> Enum.each(fn outcome ->
      Logger.warning("Presence reaper skipped #{outcome.name}: #{inspect(outcome.reason)}")
    end)

    outcomes
  end

  defp current_root_uuid(%{root_uuid: uuid}) when is_binary(uuid), do: {:ok, uuid}
  defp current_root_uuid(_state), do: Workspace.root_uuid()

  defp schedule_scan(state), do: Process.send_after(self(), :scan, state.interval)

  defp load_schema(uuid, store) do
    case CommitStoreClient.latest_commit(store, uuid) do
      {:ok, commit} ->
        doc = Schema.new_schema()
        {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)
        doc

      :none ->
        Schema.new_schema()
    end
  end
end
