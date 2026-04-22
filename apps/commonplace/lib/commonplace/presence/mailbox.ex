defmodule Commonplace.Presence.Mailbox do
  @moduledoc """
  Per-agent mailbox helpers (CX-92u).

  Derives a stable red-log UUID from an agent's cold identity_uuid, and
  produces the magenta topic on which other actors address that agent by
  name. The log UUID is deterministic so an agent reconnecting picks up
  its backlog — no per-session provisioning needed.

  Consumed by `Commonplace.MCP` when bootstrapping presence: the
  escript spawns a `RedLog.start_onramp/3` on the topic, writing into the
  log UUID returned here. Senders address the agent with
  `Magenta.send(Mailbox.topic_for_name(name), msg)`.
  """

  def log_uuid_for_identity(identity_uuid) when is_binary(identity_uuid) do
    UUID.uuid5(:url, "urn:commonplace:agent-mailbox:" <> identity_uuid)
  end

  def topic_for_name(name) when is_binary(name) do
    "agents/" <> name
  end
end
