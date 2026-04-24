defmodule Commonplace.MCP.Anubis do
  @moduledoc """
  Thin facade over `Anubis` (the `anubis_mcp` hex dep).

  **All** interaction with anubis goes through this module (or other
  `Commonplace.MCP.*` submodules that wrap a specific anubis surface).
  No other part of Commonplace should call `Anubis.*` directly. When
  (if) we fork anubis or swap to a different MCP backend, the fork
  trigger is tracked in CX-pd6k — the facade is the single place that
  needs to change.

  Today this module is intentionally small: the existing MCP server
  in `Commonplace.MCP.{Server, Stdio, Protocol, Tools, Resources}` is
  still hand-rolled and does not route through anubis yet. Wrappers
  will be added here incrementally as specific anubis capabilities
  (sampling, elicitation, streamable-HTTP transport, completion) are
  brought in.

  `supported_protocol_versions/0` returns anubis's supported version
  registry — useful both as proof-of-wiring for the dep and as the
  authoritative list our handlers should negotiate against.
  """

  @doc """
  Return the list of MCP protocol versions this anubis build supports,
  e.g. `["2024-11-05", "2025-03-26", "2025-06-18"]`.
  """
  @spec supported_protocol_versions() :: [String.t()]
  def supported_protocol_versions do
    Anubis.Protocol.supported_versions()
  end

  @doc """
  Return anubis's preferred/latest MCP protocol version.
  """
  @spec latest_protocol_version() :: String.t()
  def latest_protocol_version do
    Anubis.Protocol.latest_version()
  end
end
