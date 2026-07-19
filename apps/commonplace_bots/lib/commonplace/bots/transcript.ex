defmodule Commonplace.Bots.Transcript do
  @moduledoc """
  Camillo C5c-i (cp-plan #8895) — the turn-transcript WRITE side: the
  scrollback substrate jes's two-tier memory model builds on (C5c-ii wires
  this doc up as Camillo's SHORT-TERM memory; this slice only writes it).

  Same class as `Commonplace.Bots.Agenda`: a thin, ctx-based wrapper over
  `Commonplace.Bots.NoteDoc` — a zoned entries-doc under the bot's home,
  `home/transcript/`, get-or-create like `Agenda.ensure_dir/1`. No new
  primitive, no bespoke write path: this is the SAME zoned-note-meta class
  every C3d/C5b working doc already is.

  ## NOT Inc-1 XHTML machinery — the doc is the fact, rendering is later

  This is deliberately NOT the Inc-1 pretty-transcript renderer (XHTML,
  styled turns, the human-facing scrollback view). This doc is the
  SUBSTRATE FACT — one compact JSON entry per turn, machine-shaped, cheap
  to append and cheap to read back. A pretty rendering (XHTML, a chat-log
  view, whatever C5c-ii or later wants) is a PROJECTION over these entries,
  built later, out of scope here. Conflating the two would mean every
  turn's append also pays for layout/markup work it doesn't need yet.

  ## `append_turn/2` — ONE append per turn (k20z-friendly)

  `append_turn(turn, ctx)` appends `turn` (a map, normally
  `%{"wake" => "chat" | "heartbeat", "events" => [...]}`) as a SINGLE
  `"entries"` array update via `NoteDoc.append_entry/3` — one RMW per
  TURN, not per event. Every event the turn produced (inbound message,
  tool calls, replies, acts, refusals — see
  `Commonplace.Bots.Worker.Loop`'s moduledoc for the taxonomy this batches)
  is nested inside that single entry's `"events"` list. This mirrors the
  CX-cl65/CX-k20z lesson `Agenda`/`NoteDoc` already encode: fewer, larger
  RMWs beat many small ones, and it's also the natural transcript shape —
  a turn is one scrollback line, not N.

  `"ts"` is stamped here if the caller omits it (same convention
  `Agenda.append/2` uses).

  ## Rotation (v1 = single doc)

  v1 keeps the whole transcript in ONE `home/transcript/__note.json`
  entries array — no rotation, no rollover. This will not scale forever
  (a long-lived bot's transcript grows without bound); the roll-to-
  per-period-docs work is filed as a size-watch bead (see CX-4rec —
  `bd show CX-4rec`) rather than built speculatively here. When that
  lands, a rolled-off doc becomes part of the bot's walkable EPISODIC
  archive (distinct from this doc's role as the live short-term window);
  this module's `append_turn/2`/`read/1` contract is meant to survive that
  change unchanged from every caller's point of view.

  ## API (ctx-based, mirrors `Agenda`)

  `ctx` is the bot's resolved MUD acting context (`Commonplace.Bots.MudContext`
  or the `Commonplace.Bots.Citizen` build ctx) — home_room_uuid, store, and
  signing creds. A `nil`/absent ctx (unprovisioned bot) reads empty and
  refuses appends gracefully — never a crash.

    * `ensure_dir/1` — the `home/transcript` note dir uuid (get-or-create).
    * `read/1` — turn entries, oldest-first (`[]` if none / no ctx).
    * `append_turn/2` — append one turn entry (bot-signed).
  """

  alias Commonplace.Bots.NoteDoc

  @transcript_dir "transcript"
  @empty_entries ~s({"entries":[]})

  @doc "Get-or-create the bot's `home/transcript` note dir; `{:ok, uuid}` or error."
  @spec ensure_dir(map() | nil) :: {:ok, String.t()} | {:error, term()}
  def ensure_dir(%{home_room_uuid: home} = ctx) when is_binary(home) do
    NoteDoc.ensure_zoned_dir(home, @transcript_dir, @empty_entries, ctx)
  end

  def ensure_dir(_ctx), do: {:error, :no_mud_ctx}

  @doc "Read the transcript's turn entries, oldest-first. `[]` when none / no ctx."
  @spec read(map() | nil) :: [map()]
  def read(%{} = ctx) do
    case ensure_dir(ctx) do
      {:ok, uuid} -> NoteDoc.read_entries(uuid, ctx)
      _ -> []
    end
  end

  def read(_ctx), do: []

  @doc """
  Append one turn (a free-form map, normally
  `%{"wake" => ..., "events" => [...]}`) to the transcript, bot-signed.

  `"ts"` is stamped here if the caller omitted it. Ensures the dir exists
  first (get-or-create) so a first-ever append is safe. Returns `:ok` or
  `{:error, reason}` — callers that must never let a transcript failure
  affect their own outcome (the turn loop) are responsible for catching
  that error themselves; this function does not swallow it.
  """
  @spec append_turn(map(), map() | nil) :: :ok | {:error, term()}
  def append_turn(turn, %{} = ctx) when is_map(turn) do
    turn =
      Map.put_new_lazy(turn, "ts", fn -> DateTime.utc_now() |> DateTime.to_iso8601() end)

    with {:ok, uuid} <- ensure_dir(ctx) do
      NoteDoc.append_entry(uuid, turn, ctx)
    end
  end

  def append_turn(_turn, _ctx), do: {:error, :no_mud_ctx}
end
