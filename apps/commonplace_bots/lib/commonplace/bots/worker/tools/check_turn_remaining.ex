defmodule Commonplace.Bots.Worker.Tools.CheckTurnRemaining do
  @moduledoc """
  `check_turn_remaining` tool — return the worker's remaining
  budget across all three cap axes.

  Returns `{calls_remaining, output_tokens_remaining,
  wall_ms_remaining}`. A bot can use this to decide whether to
  attempt another tool call or wrap up.

  Budget data is snapshotted by `Worker.Loop` at the start of
  each tool-dispatch round and stuck onto state as
  `:budget_snapshot`. If the snapshot is missing (e.g. a test
  invoking the tool outside the loop), returns `:unknown`.
  """

  def name, do: "check_turn_remaining"

  def definition do
    %{
      "name" => "check_turn_remaining",
      "description" =>
        "Return your remaining budget: {calls_remaining, output_tokens_remaining, wall_ms_remaining}.",
      "input_schema" => %{"type" => "object", "properties" => %{}}
    }
  end

  def call(state, _input) do
    case Map.get(state, :budget_snapshot) do
      nil ->
        {:ok, Jason.encode!(%{"status" => "unknown"})}

      snap ->
        {:ok,
         Jason.encode!(%{
           "calls_remaining" => snap.calls_remaining,
           "output_tokens_remaining" => snap.output_tokens_remaining,
           "wall_ms_remaining" => snap.wall_ms_remaining
         })}
    end
  end
end
