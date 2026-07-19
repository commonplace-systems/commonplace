defmodule Commonplace.MUD.Build do
  @moduledoc """
  The player-build WRITE-CORES — one implementation, two entry points.

  Extracted from `Commonplace.MUD.Verbs` (CX-Camillo-C2) so the exact same
  room-dig and object-create write path a HUMAN builder drives through
  `@dig`/`@create` is ALSO reachable programmatically (the native-agent
  runtime's citizen orchestrator, `Commonplace.Bots.Citizen`, seeds a bot's
  foyer through these functions, bot-signed). There is deliberately NO
  parallel seeding side-door: a seeded room/object is INDISTINGUISHABLE from
  player-built content because it IS player-built content — same
  `ChildMutation.create_zoned_child` mint, same zone-inheritance, same
  `write_opts(ctx)` signing, same exit edges.

  Each core returns `{:ok, uuid}` | `{:error, reason}` — a RAW result with NO
  player-visible `{:reply, string}` formatting. `Verbs` calls these and formats
  the reply exactly as before (behavior-preserving; `verbs_dig_link_test`
  proves the verb behavior is unchanged).

  ## ctx contract
  Every core reads the SAME `ctx` fields the verb path threads (see
  `Commonplace.MUD.PlayerSession`'s `build_ctx/2`):

    * `:store`, `:signing_context`, `:cert_cids`, `:signer_id` — the write
      creds (`write_opts/1`).
    * `:player_name`, `:root_uuid` — resolve the builder's OWN home subtree
      (`resolve_home/1`): new rooms attach UNDER it (never the global root),
      inheriting its zone and covered by the builder's `{:subtree, home}` cert.
    * `:current_room_uuid` — where the dig's exit edge attaches and where a
      created object lands.
  """

  alias Commonplace.MUD.{ChildMutation, Schemas, Sections, World}
  alias Commonplace.MUD.Schemas.{Object, Room}

  require Logger

  @doc """
  WRITE-CORE of `@dig` (`Verbs.do_dig_write_new_room/4`): carve a new room
  `name` reached by `direction` from `ctx.current_room_uuid`, with the
  reciprocal `opposite` exit baked back. The room is minted UNDER the builder's
  HOME subtree (never the global root) via `ChildMutation.create_zoned_child`,
  so it inherits the home zone-stamp and is covered by the builder's
  `{:subtree, home}` cert. Returns `{:ok, new_room_uuid}` | `{:error, reason}`.

  Note (split authority, CX-4u03): the child mint + zone stamp are NODE-signed
  by construction (the stamp is a protected field); the ENTRY-ADD under home and
  the EXIT edge on `current_room` are `ctx`-signed (the builder's own creds). So
  a seeded room's OWN meta genesis is node-signed, while the exit edge writes are
  builder-signed — the design's stamp-by-construction integrity.
  """
  @spec dig_room(map(), String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def dig_room(ctx, direction, opposite, name) do
    json =
      Schemas.encode_room(%Room{
        name: name,
        description: "(no description yet)",
        exits: %{opposite => ctx.current_room_uuid}
      })

    with {:ok, home} <- resolve_home(ctx),
         {:ok, new_room_uuid} <-
           ChildMutation.create_zoned_child(
             home,
             name,
             Schemas.room_filename(),
             json,
             ctx.store,
             write_opts(ctx)
           ),
         :ok <- update_room_exit(ctx.current_room_uuid, direction, new_room_uuid, ctx) do
      # CX-qat5.5: dug FROM current_room, so that's the section context.
      auto_extend_section(new_room_uuid, ctx.current_room_uuid, ctx.store)
      {:ok, new_room_uuid}
    end
  end

  @doc """
  WRITE-CORE of `@create object`/`@create container`
  (`Verbs.create_object/3`): mint an object `name` UNDER
  `ctx.current_room_uuid` via `ChildMutation.create_zoned_child`, inheriting the
  room's zone (so creating in a room you OWN is cert-authorized; in a room you
  don't own the carve fail-closes). `container?` sets the `container?` flag.
  Returns `{:ok, obj_uuid}` | `{:error, reason}`.
  """
  @spec create_object(map(), String.t(), boolean()) ::
          {:ok, String.t()} | {:error, term()}
  def create_object(ctx, name, container?) do
    obj_json =
      Schemas.encode_object(%Object{
        name: name,
        description: "(no description yet)",
        container?: container?
      })

    ChildMutation.create_zoned_child(
      ctx.current_room_uuid,
      fn uuid -> instance_obj_entry(name, uuid) end,
      Schemas.object_filename(),
      obj_json,
      ctx.store,
      write_opts(ctx)
    )
  end

  @doc """
  Resolve the builder's OWN home dir (`players/<name>/`) — the root of their
  build zone. New content attaches UNDER it (never the global root). A builder
  who can't resolve a home simply can't build (graceful `{:error}`).
  """
  @spec resolve_home(map()) :: {:ok, String.t()} | {:error, term()}
  def resolve_home(ctx) do
    World.resolve_path("players/#{ctx.player_name}", ctx.root_uuid, ctx.store)
  end

  @doc """
  Surgically merge a single `direction => dest_uuid` exit onto `room_dir_uuid`'s
  room meta (CX-cl65: never a `%Room{}` round-trip — that drops the zone stamp).
  `ctx`-signed. Returns `:ok` | `{:error, reason}`.
  """
  @spec update_room_exit(String.t(), String.t(), String.t(), map()) :: :ok | {:error, term()}
  def update_room_exit(room_dir_uuid, direction, dest_uuid, ctx) do
    store = ctx.store

    case World.get_meta_map(room_dir_uuid, Schemas.room_filename(), store) do
      {:ok, map} ->
        new_exits = Map.put(Map.get(map, "exits", %{}), direction, dest_uuid)

        World.merge_meta(
          room_dir_uuid,
          Schemas.room_filename(),
          %{"exits" => new_exits},
          store,
          write_opts(ctx)
        )

      err ->
        err
    end
  end

  @doc """
  Best-effort section-cert auto-extend for a newly-created room. Never a hard
  gate on room creation — a failure here is logged, not surfaced (the room was
  already carved). See `Sections.auto_extend_for_new_room/3`.
  """
  @spec auto_extend_section(String.t(), String.t() | nil, term()) :: :ok
  def auto_extend_section(new_room_uuid, context_room_uuid, store) do
    case Sections.auto_extend_for_new_room(new_room_uuid, context_room_uuid, store: store) do
      {:ok, _results} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Commonplace.MUD.Build: section cert auto-extend for new room " <>
            "#{new_room_uuid} failed: #{inspect(reason)}"
        )

        :ok
    end
  end

  @doc """
  The `ctx` -> `[store:, signing_context:, cert_cids:, signer_id:]` opts adapter
  every build write goes through — one seam, so a session's (or a bot's)
  resolved identity reaches every commit-producing core.
  """
  @spec write_opts(map()) :: keyword()
  def write_opts(ctx) do
    [
      store: ctx.store,
      signing_context: Map.get(ctx, :signing_context),
      cert_cids: Map.get(ctx, :cert_cids, []),
      signer_id: Map.get(ctx, :signer_id)
    ]
  end

  # CX-3hii — instance-unique object entry key: so two same-named objects don't
  # collide on the "<name>.obj" key. Display name stays "<name>" (from meta);
  # uuid-derived suffix → collision-proof, CRDT-safe.
  defp instance_obj_entry(name, uuid) do
    short = uuid |> String.replace("-", "") |> String.slice(0, 8)
    "#{name}-#{short}.obj"
  end
end
