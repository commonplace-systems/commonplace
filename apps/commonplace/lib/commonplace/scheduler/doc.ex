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

  alias Yelixer.{Doc, Encoding}
  alias Yelixer.Types.YMap

  @entries_type "schedules"

  @doc "Create a new empty scheduler doc."
  def new do
    doc = Doc.new()
    {doc, _} = Doc.get_or_create_type(doc, @entries_type, :map)
    doc
  end

  @doc "Load the scheduler doc from the commit store, or return a fresh one."
  def load(uuid, store) do
    case Commonplace.Store.CommitStoreClient.latest_commit(store, uuid) do
      {:ok, commit} ->
        doc = new()
        {:ok, doc} = Encoding.apply_update(doc, commit.update)
        doc

      :none ->
        new()
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
