defmodule Commonplace.MUD.Citizenship do
  @moduledoc """
  CX-gjpi: shared "become a citizen of this MUD world" plumbing.

  Factored out of `Commonplace.MUD.Bot` (the M1 pattern for a bot's
  presence-starter cert — see that module's moduledoc, "presence-carve,
  W7") so the SAME node-signed, idempotent capability-issuance logic can
  be reused by a logged-in HUMAN player's browser session
  (`CommonplaceWebWeb.MudLive`), not just an MCP bot spawn.

  `ensure/5` does two node-signed, idempotent things every time it's
  called (safe to call on every session start — get-before-issue is
  unnecessary because both operations are themselves idempotent):

    1. **Starter cert** — issues (or re-issues, landing on the same
       content-addressed cid) the presence-starter capability cert:
       `{identity_uuid, pub}` audience, `%{verbs: [:write], scope:
       {:presence, identity_uuid}, caveats: %{}}` claim, node-issued
       (`NodeIdentity.signing_context/0` — the sanctioned D9 headless
       signer; `Commonplace.Trust` auto-trusts the node's own identity
       by construction). IDENTICAL scope to `Bot.issue_presence_starter_cert/3`
       — this is now the shared home for that logic; `Bot` delegates
       here (see below) rather than duplicating it.

    2. **Node-signed home provision** — ensures `players/<name>/` (with
       a `__player.json` meta doc) and `players/<name>/inventory/` exist
       under `root_uuid`, ALL signed by the node's own `SigningContext`
       (not the player's — a freshly-registered player has no capability
       over `root_uuid`'s directory schemas yet, so someone else has to
       land the genesis provisioning writes; the node is the sanctioned
       headless signer for exactly this, same as `PlayerSession`'s own
       unsigned-by-necessity `ensure_start_room/2`). Mirrors the
       `players/` -> per-player home -> `inventory/` shape
       `PlayerSession.bootstrap_player/3` builds, but every write here
       is node-signed so it lands under `local_write_gate: :enforce`
       even before the player holds any cert of their own.

  Returns `{:ok, cert_cids}` — a list of capability CIDs to thread into
  a `PlayerSession`'s `:cert_cids` start opt (currently just the starter
  cert, `nil`s dropped). Degrades gracefully: any step that can't
  resolve a node signer, or whose commit is rejected, is swallowed
  (rescue/catch) rather than raised — a citizen with no starter cert (or
  even a citizen whose home dirs already existed) is still better than
  a hard crash at session start.
  """

  alias Commonplace.Crypto.NodeIdentity
  alias Commonplace.MUD.Schemas
  alias Commonplace.MUD.Schemas.Room
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.Schema
  alias Commonplace.Trust.Capability
  alias Yelixer.Encoding

  @players_dir "players"
  @inventory_dir "inventory"
  @start_room_name "start"

  @type cert_cid :: binary()

  @type citizenship :: %{
          cert_cids: [cert_cid()],
          home_room_uuid: String.t(),
          home_room_meta_uuid: String.t()
        }

  @doc """
  Idempotently ensure `identity_uuid` (public key `pub`, presence name
  `name`) is a fully-provisioned citizen of the MUD world rooted at
  `root_uuid`. Node-signed, safe to call on every session start.

  Grants (all issued to the audience `{identity_uuid, pub}`, all
  node-signed):

    1. **Presence starter cert** — `{:presence, identity_uuid}` `[:write]`.
       Presence-only, NO zone-edit (the citizenship⊥ownership firewall).
       Lets the player create/move their own `.usr` presence under
       `local_write_gate: :enforce` via the W3 carve.

    2. **Home ROOM the player OWNS** — `players/<name>/` is provisioned
       (node-signed) as a ROOM (`__room.json`, with an `"out"` exit to
       the world's `start` room) plus an `inventory/`, and the player is
       issued a SEPARATE `{:docs, [home_room_meta_uuid]}` `[:write]` zone
       cert over that home room's `__room.json` meta doc. This is a
       DISTINCT cert from the presence cert — presence and ownership are
       two grants, never merged into one over-broad cert.

  Returns `{:ok, %{cert_cids: [...], home_room_uuid: uuid,
  home_room_meta_uuid: uuid}}`. `cert_cids` (starter + home-zone, nils
  dropped) is threaded into a `PlayerSession`'s `:cert_cids`;
  `home_room_uuid` into its `:spawn_room_uuid` (spawn-in-home). Cert
  issuance degrades to `[]` on any signer/store failure (never
  `{:error, _}` for a cert alone); only a home-provisioning failure
  propagates as `{:error, reason}` — a player with no home has nowhere
  to stand.
  """
  @spec ensure(String.t(), binary(), String.t(), String.t(), module()) ::
          {:ok, citizenship()} | {:error, term()}
  def ensure(identity_uuid, pub, name, root_uuid, store)
      when is_binary(identity_uuid) and is_binary(pub) and is_binary(name) and is_binary(root_uuid) do
    starter_cids = issue_presence_starter_cert(identity_uuid, pub, store)

    with {:ok, home} <- ensure_home(identity_uuid, name, root_uuid, store) do
      # A SEPARATE grant from the presence cert (presence⊥ownership):
      # {:docs} over the home room's meta only, never folded into the
      # presence cert's scope.
      zone_cids = issue_home_zone_cert(identity_uuid, pub, home.home_room_meta_uuid, store)

      {:ok,
       %{
         cert_cids: Enum.uniq(Enum.reject(starter_cids ++ zone_cids, &is_nil/1)),
         home_room_uuid: home.home_room_uuid,
         home_room_meta_uuid: home.home_room_meta_uuid
       }}
    end
  end

  # ---- Starter cert (moved from Commonplace.MUD.Bot, CX-gjpi) ----

  # Mints+signs+persists the presence-starter cert. `Capability.issue/5`
  # + `CommitStoreClient.store_capability/2` are both content-addressed /
  # idempotent (same issuer/audience/claim/proof → same signed bytes →
  # same CID → re-storing is a no-op), so this can safely re-run on
  # every call without minting a fresh cert each time — no
  # get-before-issue guard needed. The issuer is the NODE identity (no
  # human operator in the loop for either a bot spawn or a browser
  # LiveView mount — same sanctioned D9 headless branch).
  #
  # Wrapped in try/catch: `store_capability/2` raises (a caught `:exit`)
  # if `store` is a bare `CommitStore` with no `TrustSideStore` companion
  # (see `CommitStore.trust_side_store_name/1`'s moduledoc). Degrading to
  # `[]` there matches the pre-existing `Bot` failure path: a citizen
  # with no starter cert is still better than one that can't spawn/mount
  # at all.
  @doc false
  def issue_presence_starter_cert(identity_uuid, pub, store) do
    with {:ok, node_ctx} <- NodeIdentity.signing_context(),
         claim <- %{verbs: [:write], scope: {:presence, identity_uuid}, caveats: %{}},
         {:ok, cap} <- Capability.issue(node_ctx, {identity_uuid, pub}, claim, nil, store: store),
         :ok <- CommitStoreClient.store_capability(store, cap) do
      [cap.id]
    else
      _ -> []
    end
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  # ---- Home-zone cert (CX-gjpi, plan #6431/#6433 sign-off) ----

  # Issues the player a {:docs} zone cert over their OWN home room's
  # `__room.json` meta doc — the "you own your room" grant that makes
  # `@desc`-while-standing-in-your-home LAND under enforce
  # (`write_current_room_meta` writes exactly this meta uuid; the
  # {:docs} scope covers it). Node-issued, content-addressed/idempotent,
  # graceful-degrade to `[]`, EXACTLY like the presence starter cert —
  # but a SEPARATE cert with a SEPARATE ({:docs}, not {:presence}) scope.
  # The two grants are never merged: presence authority ⊥ ownership
  # authority (the M1 firewall, upheld here).
  defp issue_home_zone_cert(identity_uuid, pub, home_room_meta_uuid, store)
       when is_binary(home_room_meta_uuid) do
    with {:ok, node_ctx} <- NodeIdentity.signing_context(),
         claim <- %{verbs: [:write], scope: {:docs, [home_room_meta_uuid]}, caveats: %{}},
         {:ok, cap} <- Capability.issue(node_ctx, {identity_uuid, pub}, claim, nil, store: store),
         :ok <- CommitStoreClient.store_capability(store, cap) do
      [cap.id]
    else
      _ -> []
    end
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp issue_home_zone_cert(_identity_uuid, _pub, _meta, _store), do: []

  # ---- Node-signed home provision (as an OWNED ROOM) ----

  defp ensure_home(identity_uuid, name, root_uuid, store) do
    with {:ok, node_ctx} <- node_write_opts(store),
         {:ok, players_dir_uuid} <- ensure_players_dir(root_uuid, node_ctx),
         start_room_uuid <- resolve_start_room(root_uuid, store),
         {:ok, home} <-
           ensure_player_home(identity_uuid, name, players_dir_uuid, start_room_uuid, node_ctx) do
      {:ok, home}
    end
  end

  # Best-effort locate the world's shared `start` room dir (the "out"
  # exit target). `nil` if absent — the home room is then created with no
  # exits (still a valid, editable, owned room; the exit is polish, not
  # correctness).
  defp resolve_start_room(root_uuid, store) do
    with {:ok, root_schema} <- Schemas.load_dir_schema(root_uuid, store),
         {:ok, entry} <- Schema.get_entry(root_schema, @start_room_name) do
      entry.node_id
    else
      _ -> nil
    end
  end

  defp node_write_opts(store) do
    case NodeIdentity.signing_context() do
      {:ok, ctx} -> {:ok, [store: store, signing_context: ctx]}
      {:error, _} = err -> err
    end
  end

  defp ensure_players_dir(root_uuid, write_opts) do
    store = Keyword.fetch!(write_opts, :store)

    case Schemas.load_dir_schema(root_uuid, store) do
      {:ok, root_schema} ->
        case Schema.get_entry(root_schema, @players_dir) do
          {:ok, entry} ->
            {:ok, entry.node_id}

          :error ->
            with {:ok, new_uuid} <- Schemas.create_dir_with_meta(nil, nil, store, write_opts),
                 :ok <- add_dir_entry(root_uuid, @players_dir, new_uuid, write_opts) do
              {:ok, new_uuid}
            end
        end

      {:error, reason} ->
        {:error, {:no_root_schema, reason}}
    end
  end

  # `players/<name>/` is provisioned AS THE PLAYER'S HOME ROOM: a dir
  # carrying a `__room.json` meta (so `World.get_room/2` sees a real
  # room, the player can spawn IN it, and `@desc` there writes its meta)
  # plus an `inventory/`. Idempotent in both directions — an
  # already-provisioned home returns its existing room-meta uuid (so the
  # zone cert re-issues to the same cid); a legacy player dir that lacks
  # a `__room.json` gets one added (node-signed) so ownership still
  # attaches.
  defp ensure_player_home(identity_uuid, name, players_dir_uuid, start_room_uuid, write_opts) do
    store = Keyword.fetch!(write_opts, :store)
    {:ok, players_schema} = Schemas.load_dir_schema(players_dir_uuid, store)

    case Schema.get_entry(players_schema, name) do
      {:ok, entry} ->
        home_uuid = entry.node_id

        with {:ok, meta_uuid} <-
               ensure_home_room_meta(identity_uuid, home_uuid, name, start_room_uuid, write_opts),
             {:ok, inv_uuid} <- ensure_inventory(home_uuid, write_opts) do
          {:ok, %{home_room_uuid: home_uuid, home_room_meta_uuid: meta_uuid, inventory_uuid: inv_uuid}}
        end

      :error ->
        room_json = home_room_json(identity_uuid, name, start_room_uuid)

        with {:ok, home_uuid} <-
               Schemas.create_dir_with_meta(Schemas.room_filename(), room_json, store, write_opts),
             {:ok, meta_uuid} <- room_meta_uuid(home_uuid, store),
             {:ok, inv_uuid} <- Schemas.create_dir_with_meta(nil, nil, store, write_opts),
             :ok <- add_dir_entry(home_uuid, @inventory_dir, inv_uuid, write_opts),
             :ok <- add_dir_entry(players_dir_uuid, name, home_uuid, write_opts) do
          {:ok, %{home_room_uuid: home_uuid, home_room_meta_uuid: meta_uuid, inventory_uuid: inv_uuid}}
        end
    end
  end

  defp ensure_home_room_meta(identity_uuid, home_uuid, name, start_room_uuid, write_opts) do
    store = Keyword.fetch!(write_opts, :store)
    {:ok, schema} = Schemas.load_dir_schema(home_uuid, store)

    case Schema.get_entry(schema, Schemas.room_filename()) do
      {:ok, entry} ->
        {:ok, entry.node_id}

      :error ->
        # Legacy home dir with no room meta — add one node-signed, then
        # read its uuid back.
        with {:ok, meta_uuid} <- create_room_meta(identity_uuid, home_uuid, name, start_room_uuid, write_opts) do
          {:ok, meta_uuid}
        end
    end
  end

  defp create_room_meta(identity_uuid, home_uuid, name, start_room_uuid, write_opts) do
    store = Keyword.fetch!(write_opts, :store)
    json = home_room_json(identity_uuid, name, start_room_uuid)

    with {:ok, meta_uuid} <- Schemas.create_meta_doc(json, store, write_opts),
         :ok <- add_file_entry(home_uuid, Schemas.room_filename(), meta_uuid, write_opts) do
      {:ok, meta_uuid}
    end
  end

  defp ensure_inventory(home_uuid, write_opts) do
    store = Keyword.fetch!(write_opts, :store)
    {:ok, schema} = Schemas.load_dir_schema(home_uuid, store)

    case Schema.get_entry(schema, @inventory_dir) do
      {:ok, inv_entry} ->
        {:ok, inv_entry.node_id}

      :error ->
        with {:ok, inv_uuid} <- Schemas.create_dir_with_meta(nil, nil, store, write_opts),
             :ok <- add_dir_entry(home_uuid, @inventory_dir, inv_uuid, write_opts) do
          {:ok, inv_uuid}
        end
    end
  end

  # CX-ivqz (read-scoping P2, Seam 1): a freshly-minted home room is
  # PRIVATE by default — owned by the player it's minted for, gated. This
  # is the safe default for a personal home; the owner can flip it public
  # later (`@public`, `Commonplace.MUD.Verbs`). node-signed at mint (same
  # write as the rest of this doc), so a reader can't forge it open (W3).
  defp home_room_json(identity_uuid, name, start_room_uuid) do
    exits = if is_binary(start_room_uuid), do: %{"out" => start_room_uuid}, else: %{}

    Schemas.encode_room(%Room{
      name: "#{name}'s Home",
      description:
        "A quiet room that is yours to shape — this is your own corner of the world." <>
          if(is_binary(start_room_uuid), do: " An exit leads <out> to the rest of the demesne.", else: ""),
      exits: exits,
      owner: identity_uuid,
      visibility: :capability_gated
    })
  end

  defp room_meta_uuid(home_uuid, store) do
    {:ok, schema} = Schemas.load_dir_schema(home_uuid, store)

    case Schema.get_entry(schema, Schemas.room_filename()) do
      {:ok, entry} -> {:ok, entry.node_id}
      :error -> {:error, :no_room_meta}
    end
  end

  defp add_dir_entry(parent_uuid, name, child_uuid, write_opts) do
    add_entry(parent_uuid, write_opts, &Schema.add_directory(&1, name, child_uuid))
  end

  defp add_file_entry(parent_uuid, filename, child_uuid, write_opts) do
    add_entry(parent_uuid, write_opts, &Schema.add_file(&1, filename, child_uuid))
  end

  defp add_entry(parent_uuid, write_opts, mutate) do
    store = Keyword.fetch!(write_opts, :store)
    {:ok, schema} = Schemas.load_dir_schema(parent_uuid, store)
    update = Encoding.encode_update(mutate.(schema))
    signing_context = Keyword.get(write_opts, :signing_context)
    commit_opts = if signing_context, do: [signing_context: signing_context], else: []

    case CommitStoreClient.create_chained_commit(store, parent_uuid, update, %{}, commit_opts) do
      {:error, _} = err -> err
      _commit -> :ok
    end
  end
end
