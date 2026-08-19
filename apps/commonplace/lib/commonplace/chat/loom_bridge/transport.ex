defmodule Commonplace.Chat.LoomBridge.Transport do
  @moduledoc """
  The pluggable transport seam for `Commonplace.Chat.LoomBridge` (CX-6sf2.2 A2).

  A transport is anything that can push a loom message OUT to an
  external channel. `LoomBridge` never touches a socket, a client
  library, or a channel name directly — it only knows how to call this
  behaviour's single callback and how to receive `{:external_message,
  %{nick:, text:}}` messages sent (or cast) TO the bridge process.

  ## OUTBOUND (loom -> external): the callback

  `relay_to_external/2` is called by the bridge, synchronously, once
  per new loom message (in order). Implementations own whatever
  transport-specific state they need (a socket, a client pid, a queue —
  the bridge doesn't care) threaded as the opaque `transport_state`.

  ## INBOUND (external -> loom): NOT a callback

  There is deliberately no `receive_message` callback. A real adapter
  (an IRC client process, a webhook handler, etc.) delivers inbound
  traffic by sending the bridge process a plain message:

      send(bridge_pid, {:external_message, %{nick: "someircnick", text: "hello"}})

  `LoomBridge` handles that via `handle_info/2`. This asymmetry is
  intentional: outbound is a call the bridge INITIATES (it needs a
  return value / error to know whether to advance its cursor), inbound
  is a push the transport INITIATES whenever a line arrives on the wire
  — there's no meaningful synchronous return value for the transport to
  wait on, and forcing one would mean the transport blocks the bridge's
  mailbox on network I/O.

  ## Where the real IRC adapter plugs in (human-gated, NOT this bead)

  CX-6sf2.2 (this bead) ships ONLY the bridge logic + this seam,
  exercised entirely with a fake transport in tests. NO IRC client
  dependency is added and NO network socket is opened by this code.
  Wiring an actual IRC connection to `#loom` is a separate, explicitly
  human-gated follow-up bead — `#loom` is the team's live coordination
  channel, and a mis-wired bridge (duplicate relay, wrong nick, runaway
  loop) could disrupt it. The real adapter is expected to:

    1. Implement this behaviour, with `transport_state` holding its IRC
       client handle/connection.
    2. On receiving an IRC PRIVMSG for the mirrored channel, `send/2`
       (or `GenServer.cast/2`) the bridge pid an `{:external_message,
       %{nick:, text:}}` message.
    3. Be started and injected into `LoomBridge.start_link/1` only
       after a human has reviewed the wiring.
  """

  @doc """
  Push one loom message out to the external channel. `message` is
  `%{author: author_path_string, text: message_text}`.

  Returns `{:ok, new_transport_state}` on success (the bridge advances
  its outbound cursor past this message), or `{:error, reason}` (the
  bridge halts the outbound scan for this tick and retries the SAME
  message next tick — never skips a message on a relay failure).
  """
  @callback relay_to_external(
              transport_state :: term(),
              message :: %{author: String.t(), text: String.t()}
            ) ::
              {:ok, term()} | {:error, term()}
end
