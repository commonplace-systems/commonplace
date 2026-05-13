defmodule Commonplace.Bots.Worker.Tools.PostMessage do
  @moduledoc """
  `post_message` tool — publish a chat message to the worker's
  room as the bot.

  Routes through `Commonplace.Chat.Actions.post_message/3` — the
  same primitive every other client uses. The bot's
  `author_path` is the suffixed entity name (e.g. `"alice.bot"`)
  so subscribers can filter on the suffix per the loop-prevention
  contract.
  """

  alias Commonplace.Bots.Entity
  alias Commonplace.Chat.Actions

  def name, do: "post_message"

  def definition do
    %{
      "name" => "post_message",
      "description" =>
        "Post a chat message to the current room. Returns {message_id, ts} on success.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "text" => %{
            "type" => "string",
            "description" => "The message body."
          }
        },
        "required" => ["text"]
      }
    }
  end

  def call(state, %{"text" => text}) when is_binary(text) and text != "" do
    messages_uuid = get_messages_uuid(state)
    author_path = Entity.dir_entry_name(state.entity)

    case Actions.post_message(messages_uuid, text,
           room: state.room,
           signer_id: signer_id_for(state.entity),
           author_path: author_path
         ) do
      {:ok, %{message_id: id, ts: ts}} ->
        {:ok, Jason.encode!(%{"message_id" => id, "ts" => ts})}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  def call(_state, _input), do: {:error, "post_message requires a non-empty 'text' field"}

  defp get_messages_uuid(state) do
    case Keyword.get(state.opts, :messages_uuid) do
      nil -> raise ArgumentError, "post_message requires :messages_uuid in worker opts"
      uuid when is_binary(uuid) -> uuid
    end
  end

  # v0 stub: bots don't have ed25519 identities yet (that's gated on
  # CX-88mw landing the per-identity signer flow). Use a deterministic
  # bot-prefixed signer id so audit logs are scannable.
  defp signer_id_for(%Entity{name: name}), do: "bot:#{name}"
end
