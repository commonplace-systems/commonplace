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
  alias Commonplace.Crypto.{Signing, SigningContext}

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

    opts =
      [room: state.room, author_path: author_path] ++ signing_opts(state)

    case Actions.post_message(messages_uuid, text, opts) do
      {:ok, %{message_id: id, ts: ts}} ->
        record_post(state)
        {:ok, Jason.encode!(%{"message_id" => id, "ts" => ts})}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  def call(_state, _input), do: {:error, "post_message requires a non-empty 'text' field"}

  defp record_post(state) do
    if Process.whereis(Commonplace.Bots.RateLimit) do
      try do
        Commonplace.Bots.RateLimit.record_post(state.room, state.entity.name)
      catch
        :exit, _ -> :ok
      end
    end

    :ok
  end

  defp get_messages_uuid(state) do
    case Keyword.get(state.opts, :messages_uuid) do
      nil -> raise ArgumentError, "post_message requires :messages_uuid in worker opts"
      uuid when is_binary(uuid) -> uuid
    end
  end

  # Camillo C1: sign the post with the bot's OWN resolved Ed25519 identity
  # (threaded into `state.signing_context` by `Commonplace.Bots.Worker`).
  # The `signer_id` is derived from that context — the same derivation the
  # MCP `loom_send` surface uses — so the audit trail carries the bot's real
  # principal, not a placeholder. With no context resolved we pass neither
  # `signer_id` nor `signing_context`: the write is unsigned, an honest
  # failure that will be denied under enforce (never a fake identity).
  defp signing_opts(%{signing_context: %SigningContext{} = sc}) do
    [signer_id: Signing.signer_id(sc.identity_uuid, sc.public_key), signing_context: sc]
  end

  defp signing_opts(_state), do: []
end
