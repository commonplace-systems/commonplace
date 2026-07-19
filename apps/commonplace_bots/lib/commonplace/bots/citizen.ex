defmodule Commonplace.Bots.Citizen do
  @moduledoc """
  Camillo slice C2 — CITIZEN WITH A HOUSE.

  Turns a native-agent bot into a MUD full-citizen with a seeded, oriented
  foyer, built through the SAME player-build paths a human would use, signed by
  the bot's OWN key. The seed is the bot's FIRST ACTS as a citizen — every
  seeded room/object is INDISTINGUISHABLE from player-built content because it IS
  player-built content: same `Commonplace.MUD.Build` write-cores, same
  `ChildMutation.create_zoned_child` zone-inheritance, same bot-signed
  `write_opts`. There is NO bespoke seeding side-door and NO hand-rolled schema
  entry here — the orchestrator only chooses WHAT to build (foyer, study, map)
  and drives the ordinary build cores to do it.

  ## The unified principal (MODULEDOC INVARIANT — do not violate)

  Camillo's principal is defined by `(name, MUD-root)`; any surface that resolves
  him MUST pass the MUD root. `Commonplace.Presence.Identity.__identities__` is
  root-relative, so resolving under a DIFFERENT root yields a DIFFERENT principal.
  `provision/4` resolves the bot's signing context via
  `Commonplace.Bots.Identity.resolve_signing_context/4` (the C1 chat-Worker entry
  point) under the MUD root, and hands the SAME `identity_uuid` to
  `Commonplace.MUD.Citizenship.ensure/5`. Because both the chat surface and the
  MUD-citizen surface register under the bare name at the MUD root, the bot's
  chat identity, MUD-citizen identity, and the identity that OWNS the seeded home
  are ONE `identity_uuid`, one keypair, one signer_id — a single principal no
  matter which surface acts.

  ## What gets built (orient, don't furnish)

    1. `Citizenship.ensure/5` — the bot's node-provisioned home ROOM (owned,
       private) + a `{:subtree, home}[:write]` cert covering everything the bot
       builds under it.
    2. dig **foyer** north from home (reciprocal south baked back).
    3. dig **study** north from the foyer.
    4. create the **map** item in the foyer (a non-container object).
    5. stand the bot's `.usr` presence in the foyer and set its status.

  Exactly foyer + study + map — nothing more.

  ## Idempotency

  `Citizenship.ensure/5` is already idempotent. The digs are guarded
  check-then-dig (the `@dig` core refuses an existing exit), the map is
  guarded find-then-create, and the presence is guarded by an
  entry-existence check — so a second `provision/4` re-resolves the SAME
  principal and adds no duplicate rooms/objects/presence.
  """

  alias Commonplace.Bots.Identity, as: BotIdentity
  alias Commonplace.Crypto.Signing
  alias Commonplace.MUD.{Build, Citizenship, Schemas, World}
  alias Commonplace.MUD.Schemas.Room
  alias Commonplace.Presence
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.Schema

  # The oriented layout: a hallway of one exit each. north from home reaches the
  # foyer; north from the foyer reaches the study. Reciprocal south exits are
  # baked back by the dig core.
  @foyer_dir "north"
  @foyer_opposite "south"
  @study_dir "north"
  @study_opposite "south"
  @map_name "map"

  @type provision_result :: %{
          identity_uuid: String.t(),
          home_room_uuid: String.t(),
          foyer_uuid: String.t(),
          study_uuid: String.t(),
          presence_uuid: String.t()
        }

  @doc """
  Provision `name` as a full MUD citizen rooted at `root_uuid` (the MUD root —
  see the MODULEDOC INVARIANT). Returns `{:ok, provision_result()}` or
  `{:error, reason}`. Idempotent.

  `opts` are forwarded to `Commonplace.Bots.Identity.resolve_signing_context/4`
  (e.g. `:secret_store`, `:registrar_signing_context` for tests/provisioning).
  """
  @spec provision(String.t(), String.t(), module(), keyword()) ::
          {:ok, provision_result()} | {:error, term()}
  def provision(name, root_uuid, store \\ CommitStoreClient, opts \\ [])
      when is_binary(name) and is_binary(root_uuid) do
    with {:ok, sc} <- BotIdentity.resolve_signing_context(name, root_uuid, store, opts),
         {:ok, %{home_room_uuid: home_room_uuid, cert_cids: cert_cids}} <-
           Citizenship.ensure(sc.identity_uuid, sc.public_key, name, root_uuid, store) do
      # The bot's build-ctx — the SAME shape `PlayerSession.build_ctx/2` threads
      # to the build cores, carrying the bot's OWN signing context + the certs
      # Citizenship issued. `current_room_uuid` starts at home, then advances to
      # the foyer for the study dig / map create / presence.
      ctx = %{
        player_name: name,
        root_uuid: root_uuid,
        store: store,
        signing_context: sc,
        signer_id: Signing.signer_id(sc.identity_uuid, sc.public_key),
        cert_cids: cert_cids,
        current_room_uuid: home_room_uuid
      }

      with {:ok, foyer_uuid} <- ensure_dig(ctx, @foyer_dir, @foyer_opposite, "Foyer"),
           foyer_ctx = %{ctx | current_room_uuid: foyer_uuid},
           {:ok, study_uuid} <- ensure_dig(foyer_ctx, @study_dir, @study_opposite, "Study"),
           {:ok, _map_uuid} <- ensure_map(foyer_ctx),
           {:ok, presence_uuid} <- ensure_presence(foyer_ctx, name) do
        {:ok,
         %{
           identity_uuid: sc.identity_uuid,
           home_room_uuid: home_room_uuid,
           foyer_uuid: foyer_uuid,
           study_uuid: study_uuid,
           presence_uuid: presence_uuid
         }}
      end
    end
  end

  # Check-then-dig: the `@dig` core refuses an existing exit, so re-running
  # provision must reuse the room already reached that direction rather than
  # attempt (and fail) a second dig. Same `Build.dig_room` core the `@dig` verb
  # drives — no parallel write path.
  defp ensure_dig(ctx, direction, opposite, name) do
    case World.get_room(ctx.current_room_uuid, ctx.store) do
      {:ok, %Room{exits: exits}} ->
        case Map.get(exits, direction) do
          existing when is_binary(existing) -> {:ok, existing}
          nil -> Build.dig_room(ctx, direction, opposite, name)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Find-then-create: reuse an existing map object in the foyer rather than
  # minting a duplicate. Same `Build.create_object` core the `@create` verb
  # drives.
  defp ensure_map(ctx) do
    case World.find_entry_by_name(ctx.current_room_uuid, @map_name, ctx.store) do
      {:ok, entry} -> {:ok, entry.node_id}
      :error -> Build.create_object(ctx, @map_name, false)
    end
  end

  # Stand the bot's `.usr` presence in the foyer, bot-signed (its OWN write, via
  # the presence-starter cert Citizenship issued), and set its status. Guarded on
  # the entry existing so a re-run doesn't stack a second presence.
  defp ensure_presence(ctx, name) do
    fname = Presence.filename(name, :usr)

    case entry(ctx.current_room_uuid, fname, ctx.store) do
      {:ok, node_id} ->
        {:ok, node_id}

      :error ->
        {:ok, presence_uuid} =
          Presence.create(name, :usr, ctx.current_room_uuid, ctx.store, presence_opts(ctx))

        Presence.update_status(presence_uuid, "settling in", ctx.store, presence_opts(ctx))
        {:ok, presence_uuid}
    end
  end

  defp presence_opts(ctx) do
    [
      signing_context: ctx.signing_context,
      cert_cids: ctx.cert_cids,
      signer_id: ctx.signer_id
    ]
  end

  defp entry(dir_uuid, fname, store) do
    case Schemas.load_dir_schema(dir_uuid, store) do
      {:ok, schema} ->
        case Schema.get_entry(schema, fname) do
          {:ok, %{node_id: node_id}} -> {:ok, node_id}
          _ -> :error
        end

      _ ->
        :error
    end
  end
end
