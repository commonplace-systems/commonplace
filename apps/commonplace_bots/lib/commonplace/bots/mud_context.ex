defmodule Commonplace.Bots.MudContext do
  @moduledoc """
  Camillo slice C3c — the per-turn MUD acting context for a native-agent bot.

  A heartbeat/chat Worker turn acts in the MUD world through a freshly-resolved
  ctx — the SAME pattern MUD citizen-bots already use
  (`Commonplace.MUD.Bot.resolve_signing_opts`, `Commonplace.Bots.Citizen`) — NOT
  through a human `PlayerSession`. `resolve/4` assembles that ctx once, and the
  Worker calls it ONCE PER TURN (the cave-diver is one process per fired
  trigger), which is what makes the three design pins below hold structurally.

  ## THE CURRENT INVARIANT (CX-mpk0, cp-plan #8933/#8934 — supersedes the
  ## once-per-turn position claim this module originally shipped with)

  Identity and certs resolve ONCE per turn, exactly as `resolve/4` always
  did — nothing below changes that. POSITION does NOT stay pinned to this
  one resolve for the rest of the turn: `Commonplace.Bots.Worker.Loop`'s
  `dispatch_tool/2` re-reads `current_room_uuid`/`presence_uuid` fresh
  (via this same `World.find_presence/3` primitive, called directly, not
  a second `resolve/4`) immediately before EVERY tool dispatch within the
  turn. `resolve/4` below is still the correct, sole ENTRY point for a
  turn's ctx (identity/certs/home_room_uuid come from nowhere else); its
  own position read is simply the FIRST of what may be several within the
  turn, not the only one. See `Loop`'s moduledoc "Position is read before
  EVERY tool dispatch" for the full mechanism and the live incident that
  motivated it.

  ## The three pins (non-negotiable)

    * **(a) Position is read fresh before every ACT, never cached across
      acts.** `current_room_uuid` (and the presence doc uuid it moves as)
      is resolved FRESH here via `World.find_presence/3` on every call to
      `resolve/4` — the bot's `.usr` presence is the single source of
      position truth — AND, as of CX-mpk0, fresh again before every
      subsequent tool dispatch in the same turn (see above). An EXTERNAL
      move (a jes-summon, another actor relocating the bot's `.usr`) is
      now honored on the very next tool call, not merely the next turn.

    * **(b) One motion path.** This module carries only the coordinates a move
      needs; the `move` tool bottoms the actual motion out on
      `Commonplace.MUD.World.move_presence/5` — the CX-avzp gated
      presence-move chokepoint every player's `go`/`teleport` uses. There is no
      parallel move path.

    * **(c) The ctx is assembled ONLY from the resolved C1 signing context + the
      `Citizenship.ensure/5` certs + the canonical MUD root** — NEVER from
      caller / tool / dispatcher args (the C1/C3a registrar discipline, third
      application). `signer_id` is DERIVED from the signing context; `cert_cids`
      come straight from `Citizenship.ensure/5` (idempotent — re-called every
      turn to RESOLVE, never to re-provision); `current_room_uuid` /
      `presence_uuid` are READ from the live tree. Nothing in the ctx is taken
      on trust from a caller-supplied value.

  ## Graceful degradation

  A bot with no signing context (unresolved identity), no MUD root, or no `.usr`
  presence yet (not provisioned as a citizen) resolves to `{:error, reason}` —
  the Worker then threads `mud_ctx: nil`, and every MUD tool refuses gracefully
  (a sanitized "you are not in the world" rather than a crash). Never raises.
  """

  alias Commonplace.Crypto.{Signing, SigningContext}
  alias Commonplace.MUD.{Citizenship, World}
  alias Commonplace.Presence
  alias Commonplace.Store.CommitStoreClient

  @type t :: %{
          player_name: String.t(),
          root_uuid: String.t(),
          store: term(),
          signing_context: SigningContext.t(),
          signer_id: String.t(),
          cert_cids: [binary()],
          home_room_uuid: String.t(),
          presence_filename: String.t(),
          presence_uuid: String.t(),
          current_room_uuid: String.t()
        }

  @doc """
  Resolve the bot's MUD acting ctx for THIS turn.

  `entity` supplies only the bot's bare name (the `.usr` handle);
  `signing_context` is the C1-resolved `%SigningContext{}`; `root_uuid` is the
  canonical MUD root; `store` is the commit store. Returns `{:ok, ctx}` or a
  graceful `{:error, reason}`.

  Position (`current_room_uuid` + `presence_uuid`) is read here from
  `World.find_presence/3` — pin (a), the FIRST of what may be several
  reads across the turn (`Commonplace.Bots.Worker.Loop.dispatch_tool/2`
  re-reads it again before every subsequent tool dispatch — CX-mpk0; see
  that module's moduledoc). Nothing is sourced from anywhere but
  `signing_context` + `Citizenship.ensure/5` + `root_uuid` — pin (c).
  """
  @spec resolve(Commonplace.Bots.Entity.t(), SigningContext.t() | nil, String.t() | nil, term()) ::
          {:ok, t()} | {:error, term()}
  def resolve(entity, signing_context, root_uuid, store \\ CommitStoreClient)

  def resolve(_entity, %SigningContext{} = _sc, root_uuid, _store)
      when not is_binary(root_uuid),
      do: {:error, :no_root}

  def resolve(%{name: name}, %SigningContext{} = sc, root_uuid, store)
      when is_binary(name) and is_binary(root_uuid) do
    presence_filename = Presence.filename(name, :usr)

    # Certs come ONLY from Citizenship.ensure/5 — idempotent, so calling it
    # every turn RESOLVES the same content-addressed cert cids without
    # re-provisioning anything (pin c). A citizenship failure is graceful.
    with {:ok, %{cert_cids: cert_cids, home_room_uuid: home_room_uuid}} <-
           Citizenship.ensure(sc.identity_uuid, sc.public_key, name, root_uuid, store),
         # Position is RE-READ here, every call, from the .usr presence — the
         # single source of position truth (pin a). Never cached.
         {:ok, current_room_uuid, presence_uuid} <-
           find_presence(root_uuid, presence_filename, store) do
      {:ok,
       %{
         player_name: name,
         root_uuid: root_uuid,
         store: store,
         signing_context: sc,
         signer_id: Signing.signer_id(sc.identity_uuid, sc.public_key),
         cert_cids: cert_cids,
         home_room_uuid: home_room_uuid,
         presence_filename: presence_filename,
         presence_uuid: presence_uuid,
         current_room_uuid: current_room_uuid
       }}
    end
  end

  # No signing context (unresolved identity) → no MUD ctx. The Worker threads
  # mud_ctx: nil and the MUD tools refuse gracefully.
  def resolve(_entity, _no_sc, _root_uuid, _store), do: {:error, :no_signing_context}

  defp find_presence(root_uuid, presence_filename, store) do
    case World.find_presence(root_uuid, presence_filename, store) do
      {:ok, room_uuid, presence_uuid} -> {:ok, room_uuid, presence_uuid}
      :not_found -> {:error, :no_presence}
      # CX-iwf5: an ambiguous match (World.find_presence/3 refuses to pick
      # one) degrades EXACTLY like a genuine absence — mud_ctx resolves to
      # `{:error, _}`, the Worker threads `mud_ctx: nil`, and every MUD tool
      # refuses gracefully ("You are not in the world.") rather than acting
      # on a coin-flip-chosen room.
      {:error, :ambiguous_presence} -> {:error, :ambiguous_presence}
    end
  end
end
