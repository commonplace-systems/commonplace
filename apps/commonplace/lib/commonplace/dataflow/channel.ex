defmodule Commonplace.Dataflow.Channel do
  @moduledoc """
  Color channel definitions.

  - :blue    — CRDT state (the documents themselves)
  - :cyan    — directed writes into blue
  - :red     — persistent event logs
  - :magenta — ephemeral fire-and-forget messages
  - :green   — exclusive locks (bursar)
  """

  @type color :: :blue | :cyan | :red | :magenta | :green

  @colors [:blue, :cyan, :red, :magenta, :green]

  def colors, do: @colors

  def valid?(color) when color in @colors, do: true
  def valid?(_), do: false
end
