defmodule Commonplace.MergeCommand.Handler do
  @moduledoc """
  Singleton GenServer handling magenta merge commands (CX-8qzi).

  Subscribes to the "merge" verb sentinel so one process sees every
  `commands/{path}/merge` command sent on the node — no per-path
  supervisor tree (β topology, per plan-bot msg 2315). Per-path
  addressability is preserved at the topic namespace: callers still
  publish to `magenta:commands/{path}/merge`, and replies fan back to
  that same per-path topic so subscribers (clients, red-log onramps)
  stay anchored to what they asked about.

  Incoming request shape:
  - type: `"merge"`
  - payload: `%{"l_id" => <hex>, "other_ref" => <hex>,
                "strategy" => "translate" | "merge_snapshot"}`

  Outgoing reply shape (published back on the same per-path topic):
  - type: `"merge_completed"` | `"merge_failed"` (literal types per
    jes answer B — not generic `Events.run` verb envelopes)
  - payload success: `%{"commit_id" => id, "path" => path}`
  - payload failure: `%{"reason" => inspected, "path" => path}`

  Under the hood: `Commonplace.Store.MergePolicy.merge/4`. Strategy
  resolution (explicit / doc_type / sv_threshold / default) lives
  there — this handler just forwards `strategy:` from the payload.
  """

  use GenServer

  alias Commonplace.Dataflow.Magenta
  alias Commonplace.Store.{CommitStore, CommitStoreClient, MergePolicy}

  @source "merge_command_handler"

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    Magenta.subscribe_to_verb("merge")
    {:ok, %{store: Keyword.get(opts, :store, CommitStoreClient)}}
  end

  @impl true
  def handle_info({:magenta, topic, %Magenta{type: "merge"} = msg}, state) do
    doc_path = extract_doc_path(topic)
    reply = handle_merge(doc_path, msg.payload, state.store)
    Magenta.send(topic, reply)
    {:noreply, state}
  end

  def handle_info({:magenta, _path, %Magenta{}}, state) do
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp handle_merge(path, payload, store) do
    with {:ok, l_id} <- fetch_ref(payload, "l_id"),
         {:ok, other_ref} <- fetch_ref(payload, "other_ref"),
         strategy <- parse_strategy(payload["strategy"]),
         {:ok, commit} <- MergePolicy.merge(store, l_id, other_ref, strategy: strategy),
         {:ok, persisted} <- persist_commit(store, commit) do
      Magenta.message("merge_completed", @source, %{
        "commit_id" => persisted.id,
        "path" => path
      })
    else
      {:error, reason} ->
        Magenta.message("merge_failed", @source, %{
          "reason" => inspect(reason),
          "path" => path
        })
    end
  end

  defp persist_commit(store, commit) do
    case CommitStore.write_prebuilt_commit_cas(store, commit) do
      :ok -> {:ok, commit}
      {:ok, _} -> {:ok, commit}
      {:error, :parent_moved} -> {:ok, commit}
      other -> other
    end
  end

  defp extract_doc_path(topic) do
    parts = String.split(topic, "/")

    parts
    |> strip_prefix("commands")
    |> strip_suffix("merge")
    |> Enum.join("/")
  end

  defp strip_prefix(["commands" | rest], "commands"), do: rest
  defp strip_prefix(parts, _), do: parts

  defp strip_suffix(parts, suffix) do
    case List.last(parts) do
      ^suffix -> Enum.drop(parts, -1)
      _ -> parts
    end
  end

  defp fetch_ref(payload, key) do
    case Map.get(payload, key) do
      ref when is_binary(ref) and byte_size(ref) > 0 -> {:ok, ref}
      _ -> {:error, {:missing_ref, key}}
    end
  end

  defp parse_strategy("translate"), do: :translate
  defp parse_strategy("merge_snapshot"), do: :merge_snapshot
  defp parse_strategy(:translate), do: :translate
  defp parse_strategy(:merge_snapshot), do: :merge_snapshot
  defp parse_strategy(_), do: :translate
end
