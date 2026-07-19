defmodule Commonplace.Bots.Worker.Perception do
  @moduledoc """
  Camillo C5a — awareness-by-default wake perception (cp-plan #8867).

  Renders a prose room snapshot from `state.mud_ctx` for the FIRST section
  of every wake's initial user text (both the chat and heartbeat turn
  shapes in `Commonplace.Bots.Worker.Loop`). Reads through the exact SAME
  enforce-safe path `Commonplace.Bots.Worker.Tools.Look` uses —
  `Commonplace.MUD.World.room_snapshot/4` with `viewer:` set from the
  resolved ctx's own identity — so there is ONE room-snapshot read path,
  not a parallel perception implementation.

  ## Position at assembly time

  `state.mud_ctx` is resolved fresh by `Commonplace.Bots.Worker
  .resolve_mud_context/4` when the turn STARTS (C3c pin (a)) — this module
  renders THAT position, since the perception block is built once, before
  any tool call, as the first section of the wake text. This module never
  re-resolves anything itself. Identity/certs are stable for the whole
  turn regardless; position specifically is read AGAIN, fresher than this
  block, before every tool dispatch that follows (CX-mpk0, cp-plan
  #8933/#8934 — see `Commonplace.Bots.Worker.Loop`'s moduledoc "Position is
  read before EVERY tool dispatch") — so a `look` called mid-turn reflects
  the bot's CURRENT position even if this opening perception block (rendered
  before any tool acted) does not.

  ## Why this is narrated text, never a tool_result

  The perception block is folded into the *user* message as ordinary
  prose — it is NEVER emitted as a fabricated `tool_result` block. The
  Anthropic tool-use contract ties every `tool_result` to a `tool_use_id`
  the model itself issued; inventing one to smuggle in "ambient" content
  would poison that contract (a `tool_result` the model never asked for,
  attributed to a call that never happened). Perception is instead a
  fixed first section of narrated user text, with the event content
  (chat message / agenda) always following it — a stable delimiter
  structure, not a synthetic tool round-trip.

  ## Moduledoc honesty: this is NOT a security boundary

  Nothing here defends against a hostile actor writing perception-shaped
  text INTO a chat message and hoping the model treats it as ambient
  scene-setting rather than reported speech — that is prompt hygiene at
  best, not an authority boundary. The actual authority boundary is the
  Camillo C3a default-closed tool allowlist: whatever a turn *believes*
  about the room, it can still only ACT through tools its grantor-signed
  charter actually grants. A spoofed sense can confuse a turn's read of
  the world; it cannot escalate what that turn is permitted to do.
  """

  require Logger

  alias Commonplace.MUD.World

  @nil_body_text "You cannot feel your body."
  @desc_cap 600
  @truncation_note "…the writing continues — look to read it all."

  @doc """
  Render the perception block for this turn's wake. Takes the full Loop
  state (needs `:mud_ctx` to read the room, `:entity` to name the bot in
  the degrade log). Never raises — any resolve/read failure degrades to
  the honest nil-body line plus a logged warning.
  """
  @spec render(map()) :: String.t()
  def render(state) do
    case Map.get(state, :mud_ctx) do
      ctx when is_map(ctx) ->
        try do
          case fetch_snapshot(ctx) do
            {:ok, snapshot} -> render_snapshot(snapshot)
            {:error, reason} -> degrade(state, reason)
          end
        rescue
          e -> degrade(state, Exception.message(e))
        catch
          kind, reason -> degrade(state, "#{kind}: #{inspect(reason)}")
        end

      _no_ctx ->
        degrade(state, :no_mud_ctx)
    end
  end

  @doc """
  The shared enforce-safe room-snapshot read — the SAME call
  `Commonplace.Bots.Worker.Tools.Look` makes, factored out here so both
  callers walk one read path instead of two.
  """
  @spec fetch_snapshot(map()) :: {:ok, map()} | {:error, term()}
  def fetch_snapshot(ctx) do
    World.room_snapshot(ctx.current_room_uuid, ctx.presence_filename, ctx.store,
      viewer: ctx.signing_context.identity_uuid
    )
  end

  defp render_snapshot(%{
         name: name,
         desc: desc,
         exits: exits,
         contents: contents,
         occupants: occupants
       }) do
    room_name = blank_to(name, "somewhere unnamed")
    {desc_text, truncated?} = cap_description(desc || "")
    exits_text = exits |> Enum.map(fn {dir, _to} -> dir end) |> join_or_none()
    present_text = (List.wrap(contents) ++ List.wrap(occupants)) |> join_or_none()

    desc_sentence =
      if truncated? do
        "#{desc_text} #{@truncation_note}"
      else
        desc_text
      end

    "You stand in #{room_name}. #{desc_sentence} Exits: #{exits_text}. Here: #{present_text}."
  end

  defp blank_to(nil, fallback), do: fallback
  defp blank_to("", fallback), do: fallback
  defp blank_to(text, _fallback), do: text

  defp cap_description(desc) do
    if String.length(desc) > @desc_cap do
      {String.slice(desc, 0, @desc_cap) <> "…", true}
    else
      {desc, false}
    end
  end

  defp join_or_none([]), do: "(none)"
  defp join_or_none(items), do: Enum.join(items, ", ")

  # Honest, in-fiction, logged — never a fabricated empty room.
  defp degrade(state, reason) do
    Logger.warning(
      "Commonplace.Bots.Worker.Perception: nil-degrade bot=#{bot_name(state)} reason=#{inspect(reason)}"
    )

    @nil_body_text
  end

  defp bot_name(%{entity: %{name: name}}) when is_binary(name), do: name
  defp bot_name(_), do: "(unknown)"
end
