defmodule Commonplace.Bd.StatusTransition do
  @moduledoc """
  The closed-by-default decision-axis grammar for ticket status.

  Custody is deliberately absent: `in_progress` is an import/legacy
  artifact with exits but no inbound edge, while claim/release remain
  status-silent. `closed` also has no inbound edge here because
  `ticket_close` owns the atomic close gate.
  """

  alias Commonplace.Bd.Schemas

  @decision_sources ~w(open in_progress blocked review)
  @decision_targets ~w(open blocked review wontfix)

  @spec legal_targets(String.t()) :: [String.t()]
  def legal_targets(from) when from in @decision_sources, do: @decision_targets
  def legal_targets(from) when from in ~w(closed wontfix), do: ["open"]
  def legal_targets(_from), do: []

  @spec decide(String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def decide(from, to) when is_binary(from) and is_binary(to) do
    cond do
      from not in Schemas.valid_statuses() ->
        refusal(from, to, "current status is outside the valid status set")

      to == "in_progress" ->
        refusal(
          from,
          to,
          "in_progress is EXIT-ONLY and has no inbound edges; custody is represented by the claim token"
        )

      to == "closed" and from != "closed" ->
        refusal(
          from,
          to,
          "use ticket_close; closed keeps one door and ticket_close requires status open"
        )

      to not in Schemas.valid_statuses() ->
        refusal(
          from,
          to,
          "requested status is not valid; valid statuses: #{Enum.join(Schemas.valid_statuses(), ", ")}"
        )

      to in legal_targets(from) and from in ~w(closed wontfix) ->
        {:ok, "reopen-with-reason"}

      to in legal_targets(from) ->
        {:ok, "decision"}

      true ->
        refusal(from, to, "the transition is not named in the closed-by-default table")
    end
  end

  def decide(from, to) do
    refusal(inspect(from), inspect(to), "both statuses must be strings")
  end

  defp refusal(from, to, why) do
    legal =
      case legal_targets(from) do
        [] -> "(none)"
        targets -> Enum.join(targets, ", ")
      end

    {:error,
     "ticket_set_status refuses transition from #{inspect(from)} to #{inspect(to)}: #{why}; legal targets from #{from}: #{legal}"}
  end
end
