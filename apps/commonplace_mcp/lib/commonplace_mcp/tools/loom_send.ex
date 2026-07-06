defmodule Commonplace.MCP.Tools.LoomSend do
  @moduledoc """
  MCP tool: post a message to the `#loom` chat room (CX-6sf2.1 A1).

  `#loom` is a first-class commonplace chat room (`Commonplace.Chat.Rooms`
  under `/chat/loom/`) — this tool is how an agent posts to it. Lazily
  ensures the room exists on first call (see `Commonplace.Chat.LoomRoom`
  moduledoc for why lazy-ensure over boot-time creation), then delegates
  the actual write to `Commonplace.Chat.Actions.post_message/3` — the
  same write path the LiveView UI and `invoke_view_action` use, so the
  audit trail / signing story is identical across surfaces.

  ## Identity

  Modeled on `InvokeViewAction`'s per-session context handling
  (CX-o3r7): `author_path` comes from the session's `:presence_path`
  (falls back to `"anonymous.usr"` for callers with no bound presence);
  `signer_id` derives from `:signing_context` when the session carries
  a real `Commonplace.Crypto.SigningContext`, else the same
  `"mcp-agent@local"` placeholder every other tool uses pre-CX-88mw
  key-minting.
  """

  alias Commonplace.Chat.{Actions, LoomRoom}
  alias Commonplace.MCP.Tools.Response
  alias Commonplace.Workspace

  def descriptor do
    %{
      "name" => "loom_send",
      "description" =>
        "Post a message to the #loom chat room — the shared channel agents use to talk to each other and to jes. Lazily creates the room on first use. Use loom_read to poll for replies.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "text" => %{
            "type" => "string",
            "description" => "Message text to post."
          }
        },
        "required" => ["text"],
        "additionalProperties" => false
      }
    }
  end

  def run(args, context \\ %{})

  def run(%{"text" => text}, context) when is_binary(text) and is_map(context) do
    with {:ok, root_uuid} <- Workspace.root_uuid(),
         {:ok, room} <- LoomRoom.ensure(root_uuid) do
      opts = [
        room: LoomRoom.room_name(),
        signer_id: derive_signer_id(context),
        author_path: author_path(context),
        signing_context: Map.get(context, :signing_context)
      ]

      case Actions.post_message(room.messages_uuid, text, opts) do
        {:ok, %{message_id: id, ts: ts}} ->
          {:ok,
           Response.text("Posted to #loom (#{id}).", %{"message_id" => id, "ts" => ts})}

        {:error, reason} ->
          {:error, :invalid_params, "loom_send failed: #{inspect(reason)}"}
      end
    else
      {:error, reason} -> {:error, :invalid_params, "loom_send failed: #{inspect(reason)}"}
    end
  end

  def run(_args, _context),
    do: {:error, :invalid_params, "Missing or non-string `text` argument."}

  defp author_path(context), do: Map.get(context, :presence_path) || "anonymous.usr"

  defp derive_signer_id(%{signing_context: %Commonplace.Crypto.SigningContext{} = ctx}) do
    Commonplace.Crypto.Signing.signer_id(ctx.identity_uuid, ctx.public_key)
  end

  defp derive_signer_id(_), do: "mcp-agent@local"
end
