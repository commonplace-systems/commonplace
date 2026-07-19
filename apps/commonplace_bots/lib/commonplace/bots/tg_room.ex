defmodule Commonplace.Bots.TgRoom do
  @moduledoc """
  Camillo C4 — the bot's Telegram "parlor" as a zoned child under its home,
  get-or-create idempotent, mirroring `Commonplace.Bots.NoteDoc`'s shape
  (zoned dirs minted through `Commonplace.MUD.ChildMutation.create_zoned_child/6`,
  bot-signed entry-adds).

  ## Layout

      home/tg/<room_name>/
        __tg_room.json   — the room dir's own zoned meta (node-stamped at
                            genesis, inherits the home zone — same mechanism
                            every room/object dir uses)
        _messages         — a bare `Commonplace.Chat.Messages.new()` doc
        camillo.bot        — a LINK (not a copy) to the bot's EXISTING entity
                            dir, `Schema.add_directory/3` pointed at the uuid
                            the caller passes in (the tree is a DAG: this
                            entry and the bot's real home entry both resolve
                            to the same node)

  `home/tg/` itself is also a zoned dir (get-or-create, same mechanism) so
  multiple rooms can live side by side under one inherited-zone container.

  ## THE CARVE-RULE WALL (load-bearing — read before touching this module)

  `Commonplace.Trust.subtree_carve_ok?/5` (trust.ex ~427) authorizes a
  `{:subtree, R}` capability at a target ONLY when the target's OWN carried
  zone-stamp (`Trust.doc_zone/2`, trust.ex ~458) equals `R`. That stamp is
  read by `governing_zone_of/2` (trust.ex ~473): a DIR (a doc with an
  `"entries"` Yjs type) reads its meta CHILD's `zone`; a leaf/meta doc reads
  its OWN JSON content's `"zone"` key via `own_zone/1` (trust.ex ~500) —
  which requires `Commonplace.Document.ContentType.get_content/1` to return
  a **binary** JSON string.

  `Commonplace.Chat.Messages.new/0` is a `ContentType.create(doc, :array,
  ...)` doc. For `:array` content, `ContentType.get_content/1`
  (content_type.ex ~84) calls `Array.to_list/2` — it returns a **list**, not
  a binary. `own_zone/1`'s `with content when is_binary(content) <-
  ContentType.get_content(doc)` guard therefore NEVER matches an
  array-content doc; `own_zone/1` returns `nil` for every `_messages` doc,
  unconditionally, by construction of the envelope system — there is no
  JSON object anywhere in a `_messages` doc for a `"zone"` key to live in.

  So: **a bare `Chat.Messages` doc structurally cannot carry a zone stamp
  the carve can read**, exactly as flagged in the C4 brief. This is NOT a
  bug to route around with a new stamp path (e.g. hijacking the envelope's
  `root` metadata, which `own_zone/1` never reads) — that would be
  inventing a parallel, unaudited trust mechanism. Per the brief's grounding
  instruction, this module does **not** attempt to zone-stamp `_messages`.

  ## The resolution actually used (zero trust-core changes)

  `Commonplace.Trust.grants?/5`'s SIBLING branch for a `{:docs, [uuid]}`
  capability (trust.ex ~608) is a **membership check against a frozen doc
  list** — `uuid in docs` — with no zone-stamp involvement at all. This path
  already exists, is already exercised by `Commonplace.MUD.SignedWrite`
  (`find_docs_cert/3`, signed_write.ex ~189) for exactly this shape ("a cert
  naming one specific doc, not a subtree"), and needs no trust-core changes.

  So: write authority into a given room's `_messages` doc is granted by a
  **`{:docs, [messages_uuid]}` `Commonplace.Trust.Capability`**, minted
  per-principal by `issue_write_cert/4` — NOT by the subtree/zone mechanism
  the room DIR itself still uses for its own entry-adds (those work fine;
  only the leaf `_messages` array-doc is the wall). `home/tg/<room>/`
  itself, and the `camillo.bot` link entry, ARE covered by the bot's
  ordinary `{:subtree, home}` citizenship cert, same as every other
  zoned child — only posting INTO `_messages` needs the extra docs-cert.

  ## Grantor stance (v1)

  `issue_write_cert/4` issues a ROOT cert (`Capability.issue/5`,
  `parent_cid: nil`) signed by the **node's** identity
  (`Commonplace.Crypto.NodeIdentity.signing_context/0`) — the node is the
  grantor, mirroring the C3a "default-closed tool allowlist" stance: the
  landlord (node) grants a tenant (bridge or bot) access into a room it
  minted. This is a landlord-imposed grant, not owner-consented delivery.
  **Future**: once cert-delegation lands (the CX-8yzt / cert-threading
  family), the right shape is the BOT ITSELF delegating the bridge a
  narrower cert out of its own citizenship authority — the bot inviting the
  bridge into its own parlor, not the node placing both there. Upgrade
  then; v1 ships the simpler node-as-grantor form so the door can open now.
  """

  alias Commonplace.Chat.Messages
  alias Commonplace.Crypto.NodeIdentity
  alias Commonplace.MUD.{ChildMutation, SignedWrite, Schemas}
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.Schema
  alias Commonplace.Trust.Capability
  alias Yelixer.Encoding

  @tg_dir_name "tg"
  @container_meta_filename "__tg_room.json"
  @messages_entry "_messages"
  @bot_entry "camillo.bot"
  @empty_json "{}"

  @type ensure_result :: %{room_dir_uuid: String.t(), messages_uuid: String.t()}

  @doc """
  Get-or-create `home/tg/<room_name>/` under `ctx.home_room_uuid`, with a
  bare (unzoned, see moduledoc) `_messages` doc and a link to the bot's
  entity dir (`opts[:entity_dir_uuid]`, when given and not already linked).

  `ctx` carries `:home_room_uuid`, `:store`, `:signing_context`,
  `:cert_cids`, `:signer_id` — the bot's own resolved provisioning context
  (the same shape `Commonplace.Bots.NoteDoc` takes). Idempotent: re-running
  with the same `room_name` reuses every uuid already minted.

  Returns `{:ok, %{room_dir_uuid:, messages_uuid:}}` or `{:error, reason}`.
  """
  @spec ensure(map(), String.t(), keyword()) :: {:ok, ensure_result()} | {:error, term()}
  def ensure(ctx, room_name, opts \\ []) when is_binary(room_name) do
    store = ctx.store

    with {:ok, tg_dir_uuid} <-
           ensure_zoned_container(ctx.home_room_uuid, @tg_dir_name, ctx, store),
         {:ok, room_dir_uuid} <- ensure_zoned_container(tg_dir_uuid, room_name, ctx, store),
         {:ok, messages_uuid} <- ensure_messages(room_dir_uuid, ctx, store),
         :ok <- maybe_link_bot_entity(room_dir_uuid, opts[:entity_dir_uuid], ctx, store) do
      {:ok, %{room_dir_uuid: room_dir_uuid, messages_uuid: messages_uuid}}
    end
  end

  @doc """
  Mint a `{:docs, [messages_uuid]}` `[:write]` capability, ROOT-issued
  (`parent_cid: nil`) and NODE-signed (v1 grantor stance — see moduledoc),
  delegated to `audience` (an `{identity_uuid, public_key}` pair — the
  bridge's or the bot's own keyed identity). Returns `{:ok, %Capability{}}`
  or `{:error, reason}`.

  This is the "provision time" mint the C4 brief calls for — neither
  `Commonplace.Bots.TelegramBridge` nor `Commonplace.Bots.TelegramBridge.Poller`
  ever call `Commonplace.Trust.Capability` directly; whatever wires them up
  calls this first and threads the resulting cert's CID into `opts[:cert_cids]`.
  """
  @spec issue_write_cert({String.t(), binary()}, String.t(), keyword()) ::
          {:ok, Capability.t()} | {:error, term()}
  def issue_write_cert(audience, messages_uuid, opts \\ [])
      when is_binary(messages_uuid) do
    store = Keyword.get(opts, :store, CommitStoreClient)

    with {:ok, node_ctx} <- NodeIdentity.signing_context() do
      claim = %{verbs: [:write], scope: {:docs, [messages_uuid]}}
      Capability.issue(node_ctx, audience, claim, nil, store: store)
    end
  end

  # --- internals ---

  # Get-or-create a zoned child dir named `name` under `parent_uuid`. Same
  # shape as `Commonplace.Bots.NoteDoc.ensure_zoned_dir/4`, duplicated
  # (rather than reused) because `home/tg/<room>` carries no note-meta
  # semantics (no `append_text`/`append_entry` surface) — just a plain
  # zoned container. Idempotent: an existing entry is reused.
  defp ensure_zoned_container(parent_uuid, name, ctx, store) do
    case lookup_entry(parent_uuid, name, store) do
      {:ok, child_uuid} ->
        {:ok, child_uuid}

      :error ->
        ChildMutation.create_zoned_child(
          parent_uuid,
          name,
          @container_meta_filename,
          @empty_json,
          store,
          bot_opts(ctx)
        )
    end
  end

  # Get-or-create the room dir's `_messages` doc. Deliberately NOT routed
  # through `ChildMutation.create_zoned_child/6` — that mints a zone-stamped
  # JSON meta doc, and (per the moduledoc's carve-rule wall) a
  # `Chat.Messages` array-content doc structurally cannot carry that stamp.
  # Minted directly instead: a node-signed genesis commit (the doc has no
  # subtree cert to authorize it under, so it goes out under the same
  # node-authority every other un-zoned system doc uses — see
  # `Commonplace.MUD.ChildMutation`'s own node-signed mint step for the
  # precedent), then linked into the room dir's schema with the bot's own
  # creds (the room dir itself IS zoned, so the bot's `{:subtree, home}`
  # cert covers this entry-add — only the leaf doc's OWN write authority
  # needs the separate `{:docs}` cert from `issue_write_cert/3`).
  defp ensure_messages(room_dir_uuid, ctx, store) do
    case lookup_entry(room_dir_uuid, @messages_entry, store) do
      {:ok, messages_uuid} ->
        {:ok, messages_uuid}

      :error ->
        with {:ok, messages_uuid} <- mint_messages_doc(store),
             :ok <- link_entry(room_dir_uuid, @messages_entry, messages_uuid, :file, ctx, store) do
          {:ok, messages_uuid}
        end
    end
  end

  defp mint_messages_doc(store) do
    with {:ok, node_ctx} <- NodeIdentity.signing_context() do
      messages_uuid = UUID.uuid4()
      update = Encoding.encode_update(Messages.new())

      case CommitStoreClient.create_commit(store, messages_uuid, update, nil, %{},
             signing_context: node_ctx
           ) do
        {:error, _} = err -> err
        _commit -> {:ok, messages_uuid}
      end
    end
  end

  # Link the bot's EXISTING entity dir as `camillo.bot` — a DAG link, never a
  # copy. No-op when `entity_dir_uuid` is nil (caller doesn't have/want one
  # yet) or already linked.
  defp maybe_link_bot_entity(_room_dir_uuid, nil, _ctx, _store), do: :ok

  defp maybe_link_bot_entity(room_dir_uuid, entity_dir_uuid, ctx, store)
       when is_binary(entity_dir_uuid) do
    case lookup_entry(room_dir_uuid, @bot_entry, store) do
      {:ok, ^entity_dir_uuid} -> :ok
      {:ok, _other} -> :ok
      :error -> link_entry(room_dir_uuid, @bot_entry, entity_dir_uuid, :directory, ctx, store)
    end
  end

  defp link_entry(parent_dir, entry_name, child_uuid, kind, ctx, store) do
    with {:ok, schema} <- Schemas.load_dir_schema(parent_dir, store) do
      updated_schema =
        case kind do
          :file -> Schema.add_file(schema, entry_name, child_uuid)
          :directory -> Schema.add_directory(schema, entry_name, child_uuid)
        end

      update = Encoding.encode_update(updated_schema)
      {metadata, commit_opts} = SignedWrite.opts_for(parent_dir, bot_opts(ctx) ++ [store: store])

      case CommitStoreClient.create_chained_commit(
             store,
             parent_dir,
             update,
             metadata,
             commit_opts
           ) do
        {:error, _} = err -> err
        _commit -> :ok
      end
    end
  end

  defp bot_opts(ctx) do
    [
      signing_context: ctx.signing_context,
      cert_cids: ctx.cert_cids,
      signer_id: ctx.signer_id
    ]
  end

  defp lookup_entry(parent_uuid, name, store) do
    with {:ok, schema} <- Schemas.load_dir_schema(parent_uuid, store),
         {:ok, %{node_id: node_id}} <- Schema.get_entry(schema, name) do
      {:ok, node_id}
    else
      _ -> :error
    end
  end
end
