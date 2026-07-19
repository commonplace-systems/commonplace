defmodule Commonplace.Bots.TelegramBridge.Transport do
  @moduledoc """
  The pluggable transport seam for `Commonplace.Bots.TelegramBridge` — the
  SAME shape as `Commonplace.Chat.LoomBridge.Transport` (see that module's
  moduledoc for the full outbound/inbound asymmetry rationale); only the
  message shape differs (a `chat_id` rides along, since Telegram's
  `sendMessage` is addressed per-chat, unlike an IRC channel-wide PRIVMSG).

  ## OUTBOUND (room -> Telegram): the callback

  `relay_to_external/2` is called by the bridge, synchronously, once per new
  bot-authored room message (in order — see `TelegramBridge`'s CRITERION-3
  FILTER for which messages reach this callback at all). `message.chat_id`
  is the bridge's currently-`bound_chat_id` (see `TelegramBridge`'s
  owner-gated binding) — never absent when this callback fires, since the
  bridge withholds relay entirely while unbound.

  ## INBOUND (Telegram -> room): NOT a callback

  There is deliberately no `receive_message` callback, for the same reason
  `LoomBridge.Transport` has none: a real adapter (`TelegramBridge.Poller`,
  or a test's fake) delivers inbound traffic by sending the bridge process a
  plain message:

      send(bridge_pid, {:external_message, %{nick: "someone", handle: "someone_tg", text: "hi", chat_id: 123}})

  `TelegramBridge` handles that via `handle_info/2`.
  """

  @doc """
  Push one room message out to Telegram. `message` is `%{author:
  author_path_string, text: message_text, chat_id: the_bound_chat_id}`.

  Returns `{:ok, new_transport_state}` on success (the bridge advances its
  outbound cursor past this message), or `{:error, reason}` (the bridge
  halts the outbound scan for this tick and retries the SAME message next
  tick — never skips a message on a relay failure).
  """
  @callback relay_to_external(
              transport_state :: term(),
              message :: %{author: String.t(), text: String.t(), chat_id: String.t() | nil}
            ) :: {:ok, term()} | {:error, term()}
end
