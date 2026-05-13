defmodule Commonplace.Bots.Trigger.Regex do
  @moduledoc """
  Built-in regex trigger adapter for v0.

  Splits the entity's `trigger_source` on newlines, treats each
  non-blank line as an Erlang `:re` pattern, and returns `:wake`
  on the first line that matches the event's `"text"` field.
  Multiple-line semantics are **ANY-match** — one matching line
  is enough.

  Malformed patterns are skipped (logged in
  `[:commonplace, :bots, :trigger, :regex_compile_failed]`
  telemetry; never raise). A bot with all-malformed patterns
  silently never fires; this is deliberate v0 behavior (we
  don't want trigger-source typos to crash the dispatcher).

  Returns `:skip` if the event has no `"text"` (e.g. delete
  verbs) or if no pattern matches.
  """

  alias Commonplace.Bots.Entity

  @spec evaluate(map(), Entity.t()) :: :skip | :wake
  def evaluate(%{} = event, %Entity{trigger_source: source}) when is_binary(source) do
    text = Map.get(event, "text")

    if is_binary(text) and any_pattern_matches?(source, text) do
      :wake
    else
      :skip
    end
  end

  def evaluate(_event, _entity), do: :skip

  defp any_pattern_matches?(source, text) do
    source
    |> String.split("\n", trim: true)
    |> Enum.any?(fn line ->
      pattern = String.trim(line)
      pattern != "" and matches?(pattern, text)
    end)
  end

  defp matches?(pattern, text) do
    case Regex.compile(pattern) do
      {:ok, re} ->
        Regex.match?(re, text)

      {:error, reason} ->
        :telemetry.execute(
          [:commonplace, :bots, :trigger, :regex_compile_failed],
          %{system_time: System.system_time()},
          %{pattern: pattern, reason: reason}
        )

        false
    end
  end
end
