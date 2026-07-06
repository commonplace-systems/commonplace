defmodule Commonplace.Scheduler.Doc do
  @moduledoc """
  CRDT state for `Commonplace.Scheduler.Agent` (CX-6av).

  The scheduler doc is a Yelixer doc with one top-level YMap named
  `schedules`. Each key is a schedule_id (UUID); each value is a
  JSON-encoded record `%{fire_at, target_topic, payload, status}` with
  `status ∈ "pending" | "fired" | "cancelled"`.

  Values are JSON-encoded (not native CRDT sub-docs) because only
  primitive values round-trip through the Yelixer snapshot path today
  — sub-types nested inside maps are not yet replayed structurally
  (see `Yelixer.Doc.snapshot_update/1`'s docstring). JSON strings
  are primitives, so an entry survives snapshot compaction cleanly.

  Status transitions are append-only (pending → fired, pending →
  cancelled). CRDT merges of concurrent terminal writes converge by
  last-write-wins on the scalar string — for the scheduler's
  semantics, any terminal status is fine: subscribers have already
  received at least one magenta broadcast (magenta = the ephemeral
  fire-and-forget notification channel; see `Commonplace.Dataflow.Channel`),
  so whichever terminal status wins the merge, the notification already
  happened.
  """

  alias Commonplace.WriterHand
  alias Yelixer.{Doc, Encoding}
  alias Yelixer.Types.YMap

  @entries_type "schedules"

  @doc "Create a new empty scheduler doc. Accepts Doc.new/1 opts (e.g. `client_id:`)."
  def new(opts \\ []) do
    doc = Doc.new(opts)
    {doc, _} = Doc.get_or_create_type(doc, @entries_type, :map)
    doc
  end

  @doc """
  Load the scheduler doc from the commit store, or return a fresh one.

  CX-41qg.3: keys the replica's client_id off `WriterHand.for_doc(uuid)`
  — one scheduler doc per workspace, mutated by exactly one
  `Scheduler.Agent` GenServer (see that module's "multi-peer caveat"),
  so per-doc sharing is safe. Without this, `schedule`/`cancel`/`fire`
  each reconstructed via `new/0`'s bare `Doc.new()` and minted a fresh
  random client_id, bloating the scheduler doc's state vector by one
  slot per request forever.
  """
  def load(uuid, store) do
    client_id = WriterHand.for_doc(uuid)

    case Commonplace.Store.CommitStoreClient.latest_commit(store, uuid) do
      {:ok, commit} ->
        doc = new(client_id: client_id)
        {:ok, doc} = Encoding.apply_update(doc, commit.update)
        doc

      :none ->
        new(client_id: client_id)
    end
  end

  @doc "Set (or overwrite) the schedule entry for `id`."
  def put(doc, id, %{} = entry) when is_binary(id) do
    YMap.set(doc, @entries_type, id, Jason.encode!(entry))
  end

  @doc "Fetch the entry for `id`. Returns {:ok, map} or :error."
  def get(doc, id) when is_binary(id) do
    case YMap.get(doc, @entries_type, id) do
      nil ->
        :error

      json when is_binary(json) ->
        case Jason.decode(json) do
          {:ok, entry} -> {:ok, entry}
          _ -> :error
        end
    end
  end

  @doc "Return a map of every id → entry currently in the doc."
  def all(doc) do
    doc
    |> YMap.to_map(@entries_type)
    |> Enum.flat_map(fn {id, json} ->
      case Jason.decode(json) do
        {:ok, entry} -> [{id, entry}]
        _ -> []
      end
    end)
    |> Map.new()
  end

  @doc "Return a list of `{id, entry}` pairs where status is \"pending\"."
  def pending(doc) do
    doc
    |> all()
    |> Enum.filter(fn {_id, entry} -> entry["status"] == "pending" end)
  end
end
