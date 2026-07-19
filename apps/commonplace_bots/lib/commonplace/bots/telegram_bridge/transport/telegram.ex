defmodule Commonplace.Bots.TelegramBridge.Transport.Telegram do
  @moduledoc """
  Camillo C4 — the REAL outbound transport: implements
  `Commonplace.Bots.TelegramBridge.Transport` by POSTing to Telegram's
  `sendMessage` endpoint. This is the module that was MISSING at the
  original C4 gate — without it, `TelegramBridge` had no `transport_mod`
  to actually wire up against a live deployment; `relay_to_external/2`
  would have nowhere to send Camillo's replies. Every other C4 module
  (`TgRoom`, `TelegramBridge` itself, `Poller`) was already real; only the
  outbound wire adapter was stubbed as a behaviour with no implementation.

  ## `new/1` — the constructor (not a GenServer)

  Unlike `Poller` (a GenServer that owns its own process), this module's
  `transport_state` is a PLAIN struct (`State`) constructed once via
  `new/1` and threaded into `TelegramBridge.start_link/1` as
  `transport_state:` — the bridge already owns the tick loop; the
  transport is stateless call-in/call-out from the bridge's perspective
  (`relay_to_external/2` returns the SAME struct back as the "new"
  transport state on success, since there's nothing to mutate — no
  offset, no queue).

  `new/1` takes:

    * `:env_file` — same default (`~/.claude/channels/camillo/.env`) and
      `CAMILLO_BOT_TOKEN=...` format as `Poller` — see
      `Commonplace.Bots.TelegramBridge.Token`, the SHARED loader both
      adapters call so the parsing rule can never drift between them.
    * `:http_fn` — `(method, url, req_opts -> {:ok, %{status:, body:}} |
      {:error, term()})`, defaulting to a `Req`-backed implementation.
      Same seam `Poller` uses — ALL tests inject a fake `http_fn`; `Req`
      itself is exercised by NOTHING in this bead's test suite.

  ## Token custody — identical discipline to `Poller`

  The loaded token is wrapped in a zero-arity closure (`state.token_fn`)
  immediately on load, never assigned to a bare field — `inspect(state)`
  / `:sys.get_state/1` never prints it (a closure is opaque to `Inspect`).
  `State` additionally carries a custom `Inspect` implementation as a
  defensive second layer. The token lives in exactly one place at any
  moment: inside the closure, or inline in the URL string for the single
  `http_fn.(:post, url, ...)` call that needs it — NEVER in a log line,
  NEVER in a returned error tuple. See `sanitize_error/1` below: any raw
  transport-exception term (which could embed the token-bearing request
  URL — Telegram's REST convention is `/bot<token>/method`, so the URL
  itself is secret-bearing, unlike a typical API that carries auth in a
  header) is reduced to the exception's bare `__struct__` name (or
  `:unknown`) — deliberately dropping the exception's `message` field
  entirely, since some HTTP clients echo the request URL back inside it —
  before it ever reaches a log statement or a caller-visible `{:error, _}`.
  The URL string itself is never interpolated into anything this module
  logs or returns.

  ## Request shape (v1 — deliberately minimal)

  `POST /bot<token>/sendMessage` with JSON body `%{chat_id:, text:}` —
  NO `parse_mode`. Telegram's Markdown/MarkdownV2 parse modes reject the
  whole message on an unescaped special character; Camillo's prose is not
  written defensively against that grammar, so sending plain text (no
  parse_mode at all — Telegram's default) is the only choice that can't
  silently eat a reply. Upgrading to a parse mode is a deliberate,
  separate, human-reviewed follow-up (it needs an escaping strategy, not
  just a flag flip).

  ## Error mapping (matches `TelegramBridge`'s halt-and-retry-next-tick contract)

    * `200` → `{:ok, state}` (unchanged — nothing to mutate).
    * `429` → `{:error, {:rate_limited, retry_after}}` — `retry_after` in
      SECONDS from `body["parameters"]["retry_after"]` when Telegram sends
      it, else `nil`. `TelegramBridge.relay_entries/2` treats ANY
      `{:error, _}` from the transport as "halt this tick, retry the SAME
      message next tick" — this module does NOT sleep/retry itself (unlike
      `Poller`'s blocking long-poll loop, `relay_to_external/2` is called
      synchronously from the bridge's own tick and must return promptly;
      blocking here would stall the whole bridge, not just Telegram
      traffic).
    * Any other 4xx/5xx → `{:error, {:telegram_status, status}}`.
    * Transport-level failure (DNS, timeout, connection refused) →
      `{:error, {:transport_error, sanitized}}` — `sanitized` is
      `sanitize_error/1`'s output, never the raw exception (which could,
      in principle, carry request details).
  """

  @behaviour Commonplace.Bots.TelegramBridge.Transport

  require Logger

  alias Commonplace.Bots.TelegramBridge.Token

  @api_base "https://api.telegram.org"

  defmodule State do
    @moduledoc """
    Transport state: `token_fn` is a zero-arity closure over the parsed
    token — see the module moduledoc's "Token custody" section. Custom
    `Inspect` below is the defensive second layer.
    """
    defstruct [:token_fn, :http_fn]
  end

  defimpl Inspect, for: State do
    # Canonical algebra-style impl with an EXPLICIT field allowlist — see
    # `TelegramBridge.Poller.State`'s Inspect impl for the full
    # CONSOLIDATION GOTCHA rationale (found at the C4 mini-gate). `State`
    # only has two fields today, but the allowlist form is kept for
    # consistency with the other two C4 redacting Inspect impls (and so a
    # future field defaults to hidden, not dumped).
    import Inspect.Algebra

    def inspect(_state, opts) do
      fields = [token_fn: :redacted, http_fn: :fun]

      concat([
        "#Commonplace.Bots.TelegramBridge.Transport.Telegram.State<",
        to_doc(fields, opts),
        ">"
      ])
    end
  end

  @doc """
  Build a `%State{}` by loading the bot token (see moduledoc). Returns
  `{:ok, state}` or `{:error, reason}` — the same shape `Token.load/1`
  returns, since that's the only way this can fail.
  """
  @spec new(keyword()) :: {:ok, State.t()} | {:error, term()}
  def new(opts \\ []) do
    http_fn = Keyword.get(opts, :http_fn, &default_http_fn/3)

    case Token.load(opts) do
      {:ok, token} -> {:ok, %State{token_fn: fn -> token end, http_fn: http_fn}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def relay_to_external(%State{} = state, %{text: text, chat_id: chat_id}) do
    token = state.token_fn.()
    url = "#{@api_base}/bot#{token}/sendMessage"
    body = %{chat_id: chat_id, text: text}

    case state.http_fn.(:post, url, json: body, receive_timeout: 15_000) do
      {:ok, %{status: 200}} ->
        {:ok, state}

      {:ok, %{status: 429, body: resp_body}} ->
        retry_after = retry_after_s(resp_body)

        Logger.warning(
          "TelegramBridge.Transport.Telegram: 429 rate limited (retry_after=#{inspect(retry_after)})"
        )

        {:error, {:rate_limited, retry_after}}

      {:ok, %{status: status}} ->
        Logger.warning("TelegramBridge.Transport.Telegram: sendMessage failed, HTTP #{status}")
        {:error, {:telegram_status, status}}

      {:error, reason} ->
        sanitized = sanitize_error(reason)

        Logger.warning(
          "TelegramBridge.Transport.Telegram: transport error — #{inspect(sanitized)}"
        )

        {:error, {:transport_error, sanitized}}
    end
  end

  defp retry_after_s(%{"parameters" => %{"retry_after" => seconds}}) when is_integer(seconds) do
    seconds
  end

  defp retry_after_s(_body), do: nil

  # Never let a raw exception flow straight into a Logger call or a
  # caller-visible error tuple. Unlike Poller's sanitize_error (which keeps
  # `message` — getUpdates failures can't embed request-specific text that
  # matters here), THIS module's http_fn is building a `sendMessage` POST
  # whose URL is the secret itself (Telegram's REST convention puts the
  # token IN the path, not a header) — some HTTP clients' exception
  # `message` fields echo the request URL verbatim (e.g. a connection
  # error or a redirect-loop message), which would leak the token straight
  # through a "helpful" error string. So `message` is dropped ENTIRELY,
  # not merely trusted-and-passed-through — only the exception's
  # `__struct__` name (never free text) survives into a log line or a
  # returned `{:error, _}` tuple.
  defp sanitize_error(%{__struct__: struct}), do: struct
  defp sanitize_error(_other), do: :unknown

  defp default_http_fn(:post, url, opts) do
    case Req.post(url, opts) do
      {:ok, %Req.Response{status: status, body: body}} -> {:ok, %{status: status, body: body}}
      {:error, exception} -> {:error, exception}
    end
  end
end
