defmodule Commonplace.Bots.TelegramBridge.Token do
  @moduledoc """
  Camillo C4 — shared runtime token loading for the two Telegram-facing
  adapters (`Commonplace.Bots.TelegramBridge.Poller`, the inbound
  long-poller, and `Commonplace.Bots.TelegramBridge.Transport.Telegram`,
  the outbound `sendMessage` transport). Both need the SAME bot token, read
  the SAME way — this module is the one place that reads it, so the parsing
  rule and the redaction discipline can never drift between the two.

  ## Custody contract (the callers, not this module, hold the closure)

  `load/1` returns the raw token string in an `{:ok, token}` tuple — it does
  NOT wrap it in a closure itself, because the closure/`Inspect` redaction
  discipline belongs to whichever GenServer `State` struct ends up holding
  it (see `Poller.State` / `Transport.Telegram.State`, both of which wrap
  the returned string in a zero-arity closure immediately upon receiving
  it, per each module's own moduledoc). `load/1`'s own return value is
  therefore live token bytes for exactly one line of the caller's `init/1`
  — never stored, never logged by THIS module.

  ## Format

  Read at RUNTIME (never compile time, never `Application.get_env` — a live
  secret has no business in app config) from a file, default
  `~/.claude/channels/camillo/.env` (`opts[:env_file]` overrides,
  `Path.expand/1`-ed so `~` resolves), expected to contain a
  `CAMILLO_BOT_TOKEN=...` line (first match wins; blank value is treated as
  absent).
  """

  @default_env_file "~/.claude/channels/camillo/.env"

  @doc """
  Load the bot token from `opts[:env_file]` (default
  `~/.claude/channels/camillo/.env`). Returns `{:ok, token}` or
  `{:error, {:env_file_not_found, path}}` / `{:error, :token_not_found}` /
  `{:error, reason}`.
  """
  @spec load(keyword()) :: {:ok, String.t()} | {:error, term()}
  def load(opts \\ []) do
    path = opts |> Keyword.get(:env_file, @default_env_file) |> Path.expand()

    with {:ok, contents} <- File.read(path),
         {:ok, token} <- parse(contents) do
      {:ok, token}
    else
      {:error, :enoent} -> {:error, {:env_file_not_found, path}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse(contents) do
    contents
    |> String.split("\n")
    |> Enum.find_value(fn line ->
      case String.split(String.trim(line), "=", parts: 2) do
        ["CAMILLO_BOT_TOKEN", value] when value != "" -> value
        _ -> nil
      end
    end)
    |> case do
      nil -> {:error, :token_not_found}
      token -> {:ok, token}
    end
  end
end
