defmodule Commonplace.MCP.Tools.Response do
  @moduledoc """
  Helpers for building MCP `tools/call` result objects.

  Per the MCP spec, a tool result is `%{"content" => [...], "isError" => bool}`
  where each content entry has a `type` (text, image, resource, …) and the
  matching payload fields.

  `text/2` is the common case: a human-readable status line plus an optional
  structured-data payload encoded as a second text block (pretty JSON). The
  structured block lets agents mechanically parse the result without needing
  to interpret natural-language.
  """

  def text(message, structured \\ nil)

  def text(message, nil) do
    %{
      "content" => [%{"type" => "text", "text" => message}],
      "isError" => false
    }
  end

  def text(message, structured) do
    %{
      "content" => [
        %{"type" => "text", "text" => message},
        %{"type" => "text", "text" => Jason.encode!(structured, pretty: true)}
      ],
      "isError" => false
    }
  end

  def error(message) do
    %{
      "content" => [%{"type" => "text", "text" => message}],
      "isError" => true
    }
  end
end
