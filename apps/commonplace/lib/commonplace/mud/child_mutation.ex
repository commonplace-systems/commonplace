defmodule Commonplace.MUD.ChildMutation do
  @moduledoc """
  CX-4u03 / A1c — THE sole zone-stamp writer (the tree-mutation chokepoint).

  Every ZONED child (a meta-bearing dir: a room/object/home) created under the
  tree gets a node-signed `zone` stamp DERIVED from its parent, written ATOMICALLY
  at the child's genesis. The stamp is the frozen attestation the subtree
  write-carve (`Commonplace.Trust.subtree_carve_ok?`) reads to decide membership;
  making this module the SOLE writer of that field is the stamp-by-construction
  integrity guarantee — a create cannot produce an un-stamped or mis-stamped
  child, and a caller NEVER supplies the stamp (it is DERIVED from the actual
  parent, node-signed).

  (Named under `MUD` rather than `Tree` — CX-4u03 sketched `Tree.ChildMutation`,
  but the stamp lives in MUD meta docs and this orchestrates `MUD.Schemas` +
  `MUD.SignedWrite` + `Trust`, so a `Tree`-layer module would invert the
  MUD-builds-on-Tree dependency. Same chokepoint, layering-correct home.)

  ## Split authority (plan #7262)
  A player building in their home does TWO writes with DIFFERENT signers, each a
  single-author self-verifiable artifact:
    * the child MINT + zone-STAMP are NODE-signed (the stamp is a protected field;
      only the node writes it; the node derives it from the parent — uncheatable),
    * the parent ENTRY-ADD is signed by the caller's creds (a player's {:subtree,R}
      cert authorizes adding an entry to a dir whose zone==R, via the A1b carve).
  The node-elevated write touches ONLY the new child's own meta `zone` field
  (nothing else, no other doc); the entry-add touches ONLY the parent's schema.

  ## Zone derivation (the escalation bound — plan #7262)
    * `create_zoned_child/6` INHERITS: child.zone = `Trust.doc_zone(parent)`. The
      caller NEVER supplies a zone → a player is structurally bounded to the zone
      of a parent they can already write (their own home subtree). A player cannot
      mint a child in another zone, and cannot self-root.
    * `create_zone_root/5` SELF-ROOTS: child.zone = child_uuid (a NEW zone). A
      DISTINCT, node-authored operation (citizenship's create-home genesis), never
      reachable from the player build path — self-rooting a zone is exactly the
      escalation a player must never perform.

  ## Not here (deliberate, structural exemption)
  Presence `.usr` entries are STAMP-EXEMPT and use `Commonplace.Presence`'s own
  writer, never this module. A zone-less `.usr` is governed by the PRESENCE carve
  (bound_identity); the subtree carve fail-closes on its absent zone (a subtree
  cert can't write a `.usr`) = clean two-carve separation. The exemption is a
  SEPARATE PATH, not a flag on add-child — a caller can never request "create my
  content stamp-exempt" to dodge the zone-carve.
  """

  alias Commonplace.MUD.{Schemas, SignedWrite}
  alias Commonplace.Crypto.NodeIdentity
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.Schema
  alias Yelixer.Encoding

  @doc """
  Genesis of a NEW zone ROOT (self-rooted): the created child carries
  `zone == its own uuid`, and is linked under `parent_dir` NODE-signed. This is
  the node-authored zone-genesis operation (citizenship's create-home) — NOT
  reachable from the player build path. Returns `{:ok, child_uuid}` or
  `{:error, reason}`.
  """
  def create_zone_root(parent_dir, entry_name, meta_filename, base_json, store \\ CommitStoreClient) do
    with {:ok, node_ctx} <- NodeIdentity.signing_context() do
      child_uuid = UUID.uuid4()
      # zone == self: a fresh zone root. Node-signed entry-add (a zone root is
      # linked into a node-owned dir, e.g. players/<name>).
      mint_and_link(parent_dir, entry_name, child_uuid, meta_filename, base_json,
        child_uuid, node_ctx, store, signing_context: node_ctx)
    end
  end

  @doc """
  Create a zoned child under `parent_dir`, INHERITING the parent's zone-stamp
  (`Trust.doc_zone(parent_dir)`), and link it. The child mint + stamp are
  NODE-signed; the entry-add uses `entry_opts` (a player's `[signing_context:,
  cert_cids:]` for the @create path, or the node's for curated content). The
  caller cannot supply a zone — it is DERIVED from the parent (the escalation
  bound). Returns `{:ok, child_uuid}` or `{:error, reason}`.
  """
  def create_zoned_child(parent_dir, entry_name, meta_filename, base_json, store \\ CommitStoreClient, entry_opts) do
    with {:ok, node_ctx} <- NodeIdentity.signing_context() do
      child_uuid = UUID.uuid4()
      # DERIVED from the actual parent — never caller input (nil if the parent is
      # itself un-zoned, e.g. curated/global node content → an un-stamped child,
      # which is unwritable by any subtree cert = fail-closed-safe).
      zone = Commonplace.Trust.doc_zone(parent_dir, store)
      mint_and_link(parent_dir, entry_name, child_uuid, meta_filename, base_json,
        zone, node_ctx, store, entry_opts)
    end
  end

  @doc """
  Remove an entry from `parent_dir`'s schema. No stamp concern (the child doc and
  its stamp are untouched; only the link is removed). `opts` threads the caller's
  creds (`SignedWrite`).
  """
  def unlink(parent_dir, entry_name, store \\ CommitStoreClient, opts \\ []) do
    with {:ok, schema} <- Schemas.load_dir_schema(parent_dir, store) do
      update = Encoding.encode_update(Schema.remove_entry(schema, entry_name))
      {metadata, commit_opts} = SignedWrite.opts_for(parent_dir, Keyword.put(opts, :store, store))

      case CommitStoreClient.create_chained_commit(store, parent_dir, update, metadata, commit_opts) do
        {:error, _} = err -> err
        _commit -> :ok
      end
    end
  end

  # --- internals ---

  # The three-step create: (1) node-mint the meta carrying the zone stamp at
  # GENESIS (atomic with the meta's existence — never an un-stamped window),
  # (2) node-mint the child dir schema linking that meta, (3) link the child
  # under the parent with the caller's creds. Fail-safe: a failure after (1)/(2)
  # leaves an orphan (unreachable, benign) — there is never a writable child with
  # a wrong/missing stamp (the stamp is set at the child's own genesis or the
  # child does not exist).
  defp mint_and_link(parent_dir, entry_name, child_uuid, meta_filename, base_json, zone, node_ctx, store, entry_opts) do
    stamped_json = stamp(base_json, zone)

    # Hygiene (plan #7265): pre-check the caller's link-authority against the
    # parent BEFORE minting, so an UNAUTHORIZED @create doesn't strand an orphan
    # child (mint→mint→fail-link would leave 2 orphan commits). The parent's zone
    # exists pre-mint, so this is a cheap commitless check with the SAME predicate
    # the write-gate applies to the link commit. Not security (the link commit is
    # still gate-checked); it just avoids orphan-litter on the rejected path.
    with :ok <- precheck_link(parent_dir, entry_opts, store),
         {:ok, meta_uuid} <- Schemas.create_meta_doc(stamped_json, store, signing_context: node_ctx),
         :ok <- mint_dir(child_uuid, meta_filename, meta_uuid, node_ctx, store),
         :ok <- link_entry(parent_dir, entry_name, child_uuid, store, entry_opts) do
      {:ok, child_uuid}
    end
  end

  # Would the caller's creds authorize the entry-add to `parent_dir`? Uses the
  # commitless mirror (`Trust.writer_authorized?`, the SAME predicate the gate
  # applies to the resulting commit). A node/unsigned entry_opts (no
  # signing_context) → :ok here and lets the write itself gate.
  defp precheck_link(parent_dir, entry_opts, store) do
    case Keyword.get(entry_opts, :signing_context) do
      %{identity_uuid: id, public_key: pub} when is_binary(id) ->
        cfg = Commonplace.Trust.config()
        certs = Keyword.get(entry_opts, :cert_cids, [])

        if Commonplace.Trust.writer_authorized?(id, pub, certs, parent_dir, cfg, store),
          do: :ok,
          else: {:error, :link_unauthorized}

      _ ->
        :ok
    end
  end

  # Fold the node-derived `zone` into the meta JSON at genesis. Omitted when nil
  # (an un-zoned parent → un-stamped child, like the omit-when-default of the
  # other protected meta fields). This is the ONLY write of the `zone` field.
  defp stamp(base_json, nil), do: base_json

  defp stamp(base_json, zone) when is_binary(zone) do
    case Jason.decode(base_json) do
      {:ok, map} when is_map(map) -> map |> Map.put("zone", zone) |> Jason.encode!()
      _ -> base_json
    end
  end

  # Node-signed genesis of the child dir schema at a CHOSEN uuid (so a zone root
  # can be self-referential). Mirrors Schemas.create_dir_with_meta's dir genesis.
  defp mint_dir(dir_uuid, meta_filename, meta_uuid, node_ctx, store) do
    dir_doc = Schema.new_schema() |> Schema.add_file(meta_filename, meta_uuid)
    update = Encoding.encode_update(dir_doc)
    {metadata, commit_opts} = SignedWrite.opts_for(dir_uuid, signing_context: node_ctx, store: store)

    case CommitStoreClient.create_commit(store, dir_uuid, update, nil, metadata, commit_opts) do
      {:error, _} = err -> err
      _commit -> :ok
    end
  end

  # Link the child under the parent (caller-signed via SignedWrite — a player's
  # {:subtree,R} cert authorizes this when parent.zone==R; the A1b carve checks it).
  defp link_entry(parent_dir, entry_name, child_uuid, store, entry_opts) do
    # entry_name may be a plain string (rooms use the display name) OR a
    # `(child_uuid -> name)` function (objects derive an instance-unique
    # "<name>-<short-uuid>.obj" key, CX-lfo3, which needs the minted uuid).
    name = if is_function(entry_name, 1), do: entry_name.(child_uuid), else: entry_name

    with {:ok, schema} <- Schemas.load_dir_schema(parent_dir, store) do
      update = Encoding.encode_update(Schema.add_directory(schema, name, child_uuid))
      {metadata, commit_opts} = SignedWrite.opts_for(parent_dir, Keyword.put(entry_opts, :store, store))

      case CommitStoreClient.create_chained_commit(store, parent_dir, update, metadata, commit_opts) do
        {:error, _} = err -> err
        _commit -> :ok
      end
    end
  end
end
