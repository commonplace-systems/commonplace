defmodule Commonplace.Bots.Worker.Tools.UpdateAgenda do
  @moduledoc """
  `update_agenda` tool (Camillo C3b) — append an item to the bot's
  `agenda.jsonl` (its "desk"), bot-signed.

  This is the heartbeat turn's *write-back*: after doing (or deferring)
  one agenda item, the bot records what it still means to get to. The
  appended line schema is minimal:

      { "ts": "<iso8601>", "text": "<the pending item>" }

  Like every C3a tool this is allowlisted: a bot only gets it if its
  grantor-signed charter grants `"update_agenda"`. The append is signed
  with the bot's OWN key via `state.signing_context` (C1 discipline) —
  routed through `Commonplace.Bots.Agenda.append/4`, the same
  substrate-pure text-append primitive `remember` uses. Substrate-pure:
  no bot-only fast lane.
  """

  alias Commonplace.Bots.Agenda
  alias Commonplace.Store.CommitStoreClient

  def name, do: "update_agenda"

  def definition do
    %{
      "name" => "update_agenda",
      "description" =>
        "Append an item to your agenda.jsonl (your desk of pending work). " <>
          "Persists across heartbeats; read back when you next wake on a timer.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "text" => %{
            "type" => "string",
            "description" => "The pending item to add. One line, free-form text."
          }
        },
        "required" => ["text"]
      }
    }
  end

  def call(state, %{"text" => text}) when is_binary(text) and text != "" do
    store = Keyword.get(state.opts || [], :store, CommitStoreClient)

    opts =
      [signing_context: Map.get(state, :signing_context)]
      |> maybe_put(:write_store, Keyword.get(state.opts || [], :write_store))

    item = %{"text" => text}

    case Agenda.append(state.entity, item, store, opts) do
      :ok -> {:ok, "agenda updated"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  def call(_state, _input),
    do: {:error, "update_agenda requires a non-empty 'text' field"}

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
