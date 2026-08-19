defmodule Commonplace.MCP.Tools.PresenceInfo do
  @moduledoc """
  MCP tool: return the agent's presence + mailbox identifiers.

  Before CX-hf71 these three values rode in the `initialize` response's
  `serverInfo` (as `presenceUuid` / `mailboxUuid` / `mailboxTopic`).
  The anubis-backed server (CX-hf71) can't enrich that payload, so the
  same three values are now exposed here with snake_case keys. An
  agent calls `tools/call presence_info` once after initialization to
  learn its mailbox UUID for later `tail_red` calls.

  All three values are `nil` when the server was started without a
  `presence_starter` (e.g. in pure test mode) — the agent should treat
  a nil mailbox_uuid as "no dedicated mailbox this session".
  """

  alias Commonplace.MCP.Tools.Response

  def descriptor do
    %{
      "name" => "presence_info",
      "description" =>
        "Return this agent's presence UUID, mailbox UUID, and mailbox topic. Replaces the pre-CX-hf71 initialize-response serverInfo fields (presenceUuid / mailboxUuid / mailboxTopic) — anubis_mcp's initialize handler can't be enriched, so the same data is exposed through a tool call. Call once after initialization; pass mailbox_uuid to tail_red to read messages addressed to this agent.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{},
        "additionalProperties" => false
      }
    }
  end

  def run(args, context \\ %{})

  def run(_args, context) when is_map(context) do
    payload = %{
      "presence_uuid" => context[:presence_uuid],
      "mailbox_uuid" => context[:mailbox_uuid],
      "mailbox_topic" => context[:mailbox_topic]
    }

    {:ok, Response.text(summary(payload), payload)}
  end

  defp summary(%{"presence_uuid" => nil}),
    do: "No presence info — server started without a presence_starter."

  defp summary(%{"mailbox_topic" => topic, "mailbox_uuid" => uuid}) do
    "Presence active. Mailbox topic: #{topic}. Mailbox UUID: #{uuid}."
  end
end
