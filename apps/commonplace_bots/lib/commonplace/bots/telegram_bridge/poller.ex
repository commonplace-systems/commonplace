defmodule Commonplace.Bots.TelegramBridge.Poller do
  @moduledoc """
  Camillo C4 — the real Telegram adapter: long-polls `getUpdates` and
  forwards each text message to a `Commonplace.Bots.TelegramBridge` pid as
  `{:external_message, %{nick:, handle:, text:, chat_id:}}`.

  ## NOT auto-started (deliberate — mirrors LoomBridge's real-adapter gate)

  This module is never started by any supervisor in this bead. It opens a
  real long-lived HTTP long-poll against Telegram's servers using the
  live bot token — exactly the "human-gated, wire only after review" stance
  `Commonplace.Chat.LoomBridge.Transport`'s moduledoc documents for the real
  IRC adapter. Whatever provisions Camillo for real starts this explicitly
  (`start_link/1`), after review; env-flag gating at deploy time is a
  SEPARATE, later concern (not this module's job to read a flag and
  self-start).

  ## Token custody — NEVER logged, NEVER in a state dump

  The bot token is loaded at RUNTIME via `Commonplace.Bots.TelegramBridge.Token.load/1`
  — see that module's moduledoc for the file/format contract
  (`opts[:env_file]`, default `~/.claude/channels/camillo/.env`,
  `CAMILLO_BOT_TOKEN=...`). It is loaded ONCE at `init/1` and immediately
  wrapped in a zero-arity closure stored in state (`state.token_fn`) — the
  raw string itself is never assigned to a bare state field, so
  `inspect(state)` / `:sys.get_state/1` / a crash report's state dump never
  prints it (a closure's captured environment is opaque to `Inspect` — it
  prints as `#Function<...>`, not its contents). `State` additionally
  carries a custom `Inspect` implementation so even a future field holding
  token-adjacent data (the raw `Req` auth header, say) can be redacted
  defensively — belt AND suspenders, not either/or. Every log line and
  every `{:error, _}` this module can return is built from status codes /
  offsets / counts only, never token bytes. `Transport.Telegram` (the
  outbound `sendMessage` adapter) holds the SAME custody discipline over
  the SAME loader — see that module's moduledoc.

  ## HTTP seam

  `opts[:http_fn]` — `(method, url, req_opts -> {:ok, %{status:, body:}} |
  {:error, term()})` — defaults to a `Req`-backed implementation
  (`Commonplace.Bots.Worker.Client`'s dep, already in `commonplace_bots`).
  ALL tests inject a fake `http_fn`; `Req` itself is exercised by NOTHING
  in this bead's test suite (no network I/O in CI, matching the C4 brief's
  offline-test requirement).

  ## Long-poll loop

  Each cycle: `GET /bot<token>/getUpdates?offset=<cursor>&timeout=<poll_s>`.
  On success, for each update carrying a `message.text`, send
  `{:external_message, %{nick:, handle:, text:, chat_id:}}` to the bridge
  pid, and advance `offset` to `update_id + 1` (Telegram's own
  at-least-once-ack cursor contract — an update is only "consumed" once a
  STRICTLY GREATER offset is sent in the next request). `nick` is the
  sender's `username` if present, else `first_name` (never absent —
  Telegram always sends at least one); `handle` is the raw `username` field
  verbatim, `nil` when the sender has none (used by `TelegramBridge`'s
  owner-handle binding — display-name fallback is NEVER an acceptable
  handle match, so `nick` and `handle` are kept as two distinct fields, not
  collapsed into one).

  ## Error handling

    * `409 Conflict` (Telegram: another `getUpdates` long-poll is already
      active for this token) — `Logger.warning`, back off `opts[:backoff_ms]`
      (default 5s) and retry. Never crashes — a second poller misconfigured
      elsewhere shouldn't take this one down; it should visibly complain
      and keep trying.
    * `429 Too Many Requests` — honors Telegram's `retry_after` (seconds,
      from the response body's `parameters.retry_after` when present, else
      falls back to `opts[:backoff_ms]`).
    * Any other transport/HTTP error — logs (status/reason only, never
      body-with-token — the token is never IN the body/URL path Telegram
      echoes back either, so this is a non-issue in practice, but the log
      statement doesn't dump raw response bodies regardless) and retries
      after `opts[:backoff_ms]`.
  """

  use GenServer
  require Logger

  alias Commonplace.Bots.TelegramBridge.Token

  @default_poll_timeout_s 30
  @default_backoff_ms 5_000
  @api_base "https://api.telegram.org"

  defmodule State do
    @moduledoc """
    Poller GenServer state. `token_fn` is a zero-arity closure over the
    parsed token — see the module moduledoc's "Token custody" section for
    why a closure, not a bare field. Custom `Inspect` below is the
    defensive second layer.
    """
    defstruct [
      :bridge,
      :token_fn,
      :http_fn,
      :offset,
      :poll_timeout_s,
      :backoff_ms
    ]
  end

  defimpl Inspect, for: State do
    # Canonical algebra-style impl with an EXPLICIT field allowlist — a
    # future field added to State is NOT auto-dumped (redacted-by-default),
    # unlike a Map.from_struct dump which would include it. `token_fn`
    # renders as the literal `:redacted`.
    #
    # ⚠️ CONSOLIDATION GOTCHA (found at the C4 mini-gate): protocol
    # consolidation compiled from a _build that predates this impl leaves
    # the consolidated Inspect unaware of it — the belt goes silently
    # inert (raw struct dump) while targeted runs with unconsolidated
    # protocols pass. The PRIMARY custody mechanism is deliberately not
    # this impl but the closure (`token_fn` — a #Function is opaque to
    # Inspect with or without consolidation); this impl is the
    # belt-and-suspenders layer. Redaction pins must hold under a
    # full-suite run from clean, not only targeted runs.
    import Inspect.Algebra

    def inspect(state, opts) do
      fields = [
        bridge: state.bridge,
        token_fn: :redacted,
        offset: state.offset,
        poll_timeout_s: state.poll_timeout_s,
        backoff_ms: state.backoff_ms
      ]

      concat(["#Commonplace.Bots.TelegramBridge.Poller.State<", to_doc(fields, opts), ">"])
    end
  end

  # --- Public API ---

  @doc """
  Start the poller against `opts[:bridge]` (a `TelegramBridge` pid or
  registered name). NOT started by any supervisor — see moduledoc.

  `opts[:auto_poll]` (default `true`) schedules the first `:poll`
  immediately via `handle_continue/2`, then the loop free-runs
  (`handle_info(:poll, ...)` re-schedules itself after every cycle) —
  the production shape. Tests that drive cycles deterministically via
  `poll_now/1` against a finite, order-sensitive stub queue pass
  `auto_poll: false` so the loop's own background cycle can't race a
  test's explicit call for the next queued stub response.
  """
  def start_link(opts) do
    name = Keyword.get(opts, :name)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc "Current long-poll offset (for inspection / tests)."
  def offset(poller), do: GenServer.call(poller, :offset)

  @doc "Run one poll cycle synchronously (tests)."
  def poll_now(poller), do: GenServer.call(poller, :poll_now, 30_000)

  # --- GenServer callbacks ---

  @impl true
  def init(opts) do
    bridge = Keyword.fetch!(opts, :bridge)
    http_fn = Keyword.get(opts, :http_fn, &default_http_fn/3)

    case Token.load(opts) do
      {:ok, token} ->
        state = %State{
          bridge: bridge,
          token_fn: fn -> token end,
          http_fn: http_fn,
          offset: Keyword.get(opts, :offset, 0),
          poll_timeout_s: Keyword.get(opts, :poll_timeout_s, @default_poll_timeout_s),
          backoff_ms: Keyword.get(opts, :backoff_ms, @default_backoff_ms)
        }

        if Keyword.get(opts, :auto_poll, true) do
          {:ok, state, {:continue, :schedule_poll}}
        else
          {:ok, state}
        end

      {:error, reason} ->
        {:stop, {:token_load_failed, reason}}
    end
  end

  @impl true
  def handle_continue(:schedule_poll, state) do
    send(self(), :poll)
    {:noreply, state}
  end

  @impl true
  def handle_call(:offset, _from, state), do: {:reply, state.offset, state}

  @impl true
  def handle_call(:poll_now, _from, state) do
    {result, new_state} = do_poll(state)
    {:reply, result, new_state}
  end

  @impl true
  def handle_info(:poll, state) do
    {_result, new_state} = do_poll(state)
    schedule_next(new_state)
    {:noreply, new_state}
  end

  # --- Poll cycle ---

  defp do_poll(state) do
    token = state.token_fn.()
    url = "#{@api_base}/bot#{token}/getUpdates"

    params = [offset: state.offset, timeout: state.poll_timeout_s]

    case state.http_fn.(:get, url,
           params: params,
           receive_timeout: (state.poll_timeout_s + 10) * 1_000
         ) do
      {:ok, %{status: 200, body: %{"ok" => true, "result" => updates}}} ->
        new_state = Enum.reduce(updates, state, &handle_update/2)
        {{:ok, %{updates: length(updates)}}, new_state}

      {:ok, %{status: 409}} ->
        Logger.warning(
          "TelegramBridge.Poller: 409 Conflict (another poller active) — backing off"
        )

        Process.sleep(state.backoff_ms)
        {{:error, :conflict}, state}

      {:ok, %{status: 429, body: body}} ->
        retry_after = retry_after_ms(body, state.backoff_ms)
        Logger.warning("TelegramBridge.Poller: 429 rate limited — backing off #{retry_after}ms")
        Process.sleep(retry_after)
        {{:error, :rate_limited}, state}

      {:ok, %{status: status}} ->
        Logger.warning("TelegramBridge.Poller: unexpected HTTP status #{status}")
        Process.sleep(state.backoff_ms)
        {{:error, {:http_status, status}}, state}

      {:error, reason} ->
        Logger.warning(
          "TelegramBridge.Poller: transport error — #{inspect(sanitize_error(reason))}"
        )

        Process.sleep(state.backoff_ms)
        {{:error, {:transport_error, reason}}, state}
    end
  end

  defp handle_update(update, state) do
    new_offset = max(state.offset, Map.get(update, "update_id", -1) + 1)
    state = %{state | offset: new_offset}

    case Map.get(update, "message") do
      %{"text" => text, "chat" => %{"id" => chat_id}} = message when is_binary(text) ->
        from = Map.get(message, "from", %{})

        send(
          state.bridge,
          {:external_message,
           %{nick: nick(from), handle: handle(from), text: text, chat_id: chat_id}}
        )

        state

      _other ->
        state
    end
  end

  defp nick(%{"username" => username}) when is_binary(username) and username != "", do: username

  defp nick(%{"first_name" => first_name}) when is_binary(first_name) and first_name != "",
    do: first_name

  defp nick(_), do: "telegram-user"

  defp handle(%{"username" => username}) when is_binary(username) and username != "", do: username
  defp handle(_), do: nil

  defp retry_after_ms(%{"parameters" => %{"retry_after" => seconds}}, _backoff_ms)
       when is_integer(seconds) do
    seconds * 1_000
  end

  defp retry_after_ms(_body, backoff_ms), do: backoff_ms

  defp schedule_next(_state), do: send(self(), :poll)

  # Never let a raw exception struct (which could embed request opts,
  # including the token-bearing URL) flow straight into a Logger call —
  # keep only the exception's __struct__ name and message.
  defp sanitize_error(%{__struct__: struct, message: message}) when is_binary(message) do
    {struct, message}
  end

  defp sanitize_error(%{__struct__: struct}), do: {:error, struct}
  defp sanitize_error(_other), do: {:error, :unknown}

  # --- Default HTTP impl (Req) ---

  defp default_http_fn(:get, url, opts) do
    case Req.get(url, opts) do
      {:ok, %Req.Response{status: status, body: body}} -> {:ok, %{status: status, body: body}}
      {:error, exception} -> {:error, exception}
    end
  end
end
