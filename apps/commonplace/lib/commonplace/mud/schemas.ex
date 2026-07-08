defmodule Commonplace.MUD.Schemas do
  @moduledoc """
  Room / object / player metadata docs for the MUD.

  Each room/object/player directory holds a single JSON metadata file
  (`__room.json`, `__obj.json`, `__player.json`) — stored as a Yelixer
  text doc with a JSON string body. Parse on read, re-encode on write.

  Schemas are intentionally minimal for v0; additions (currency, doors,
  etc.) extend the JSON shape without migrations because missing keys
  default to nil/false/empty.
  """

  alias Commonplace.Document.ContentType
  alias Commonplace.MUD.SignedWrite
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.{DocBuilder, Schema}
  alias Commonplace.WriterHand
  alias Yelixer.Doc
  alias Yelixer.Encoding

  @room_file "__room.json"
  @obj_file "__obj.json"
  @player_file "__player.json"
  @recipe_file "__recipe.json"

  defmodule Room do
    @enforce_keys [:name, :description]
    defstruct name: "",
              description: "",
              exits: %{},
              tick_interval_ms: nil,
              tick_message: nil

    @type t :: %__MODULE__{
            name: String.t(),
            description: String.t(),
            exits: %{String.t() => String.t()},
            tick_interval_ms: pos_integer() | nil,
            tick_message: String.t() | nil
          }
  end

  defmodule Object do
    @enforce_keys [:name]
    defstruct name: "",
              aliases: [],
              description: "",
              fixed: false,
              container?: false,
              tick_interval_ms: nil,
              tick_message: nil,
              # CX-cj3t (items epic phase 2, MINE) — the vein yield-spec.
              # `kind: "vein"` marks an Object as a mineable resource node
              # rather than a plain takeable item. `yield_type` /
              # `yield_max` / `regen_per_ms` are PROTECTED (node-signed,
              # verb-immutable — the anti-forgery root, see
              # `Commonplace.MUD.Mint` moduledoc); `yield_remaining` /
              # `last_regen_at` are the elevated-mutable pair (decrement +
              # advance-clock ONLY — never written up). A plain `Object`
              # (`kind: "object"`, the default) leaves all five nil.
              kind: "object",
              yield_type: nil,
              yield_max: nil,
              regen_per_ms: nil,
              yield_remaining: nil,
              last_regen_at: nil

    @type t :: %__MODULE__{
            name: String.t(),
            aliases: [String.t()],
            description: String.t(),
            fixed: boolean(),
            container?: boolean(),
            tick_interval_ms: pos_integer() | nil,
            tick_message: String.t() | nil,
            kind: String.t(),
            yield_type: map() | nil,
            yield_max: non_neg_integer() | nil,
            regen_per_ms: number() | nil,
            yield_remaining: number() | nil,
            last_regen_at: integer() | nil
          }
  end

  defmodule Player do
    @enforce_keys [:name]
    defstruct name: "",
              title: "",
              description: ""

    @type t :: %__MODULE__{
            name: String.t(),
            title: String.t(),
            description: String.t()
          }
  end

  # CX-cj3t (items epic phase 2, SMITH) — a Recipe is a CURATED,
  # node-signed DOC (not a verb attr): it DEFINES the output type
  # (mint-authority, anti-forgery — a player who could author one could
  # mint anything, so authorship is curation/write-gated). `inputs` are
  # `%{"type" => name, "qty" => n}`; `output` is an object template
  # (name/aliases/description) minted node-signed; `station` is an
  # optional required-object gate (unused in v1, reserved). Inspectable
  # pre-craft (the `recipes` read verb) = informed consent.
  defmodule Recipe do
    @enforce_keys [:name]
    defstruct name: "", inputs: [], output: %{}, station: nil

    @type t :: %__MODULE__{
            name: String.t(),
            inputs: [map()],
            output: map(),
            station: String.t() | nil
          }
  end

  def room_filename, do: @room_file
  def object_filename, do: @obj_file
  def player_filename, do: @player_file
  def recipe_filename, do: @recipe_file

  # ---- Encoding ----

  def encode_room(%Room{} = r) do
    Jason.encode!(%{
      "kind" => "room",
      "name" => r.name,
      "description" => r.description,
      "exits" => r.exits,
      "tick_interval_ms" => r.tick_interval_ms,
      "tick_message" => r.tick_message
    })
  end

  def encode_object(%Object{} = o) do
    Jason.encode!(%{
      "kind" => o.kind,
      "name" => o.name,
      "aliases" => o.aliases,
      "description" => o.description,
      "fixed" => o.fixed,
      "container" => o.container?,
      "tick_interval_ms" => o.tick_interval_ms,
      "tick_message" => o.tick_message,
      "yield_type" => o.yield_type,
      "yield_max" => o.yield_max,
      "regen_per_ms" => o.regen_per_ms,
      "yield_remaining" => o.yield_remaining,
      "last_regen_at" => o.last_regen_at
    })
  end

  def encode_player(%Player{} = p) do
    Jason.encode!(%{
      "kind" => "player",
      "name" => p.name,
      "title" => p.title,
      "description" => p.description
    })
  end

  # ---- Decoding ----

  def decode_room(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, m} ->
        {:ok,
         %Room{
           name: Map.get(m, "name", ""),
           description: Map.get(m, "description", ""),
           exits: Map.get(m, "exits", %{}),
           tick_interval_ms: Map.get(m, "tick_interval_ms"),
           tick_message: Map.get(m, "tick_message")
         }}

      err ->
        err
    end
  end

  def decode_object(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, m} ->
        {:ok,
         %Object{
           name: Map.get(m, "name", ""),
           aliases: Map.get(m, "aliases", []),
           description: Map.get(m, "description", ""),
           fixed: Map.get(m, "fixed", false),
           container?: Map.get(m, "container", false),
           tick_interval_ms: Map.get(m, "tick_interval_ms"),
           tick_message: Map.get(m, "tick_message"),
           kind: Map.get(m, "kind", "object"),
           yield_type: Map.get(m, "yield_type"),
           yield_max: Map.get(m, "yield_max"),
           regen_per_ms: Map.get(m, "regen_per_ms"),
           yield_remaining: Map.get(m, "yield_remaining"),
           last_regen_at: Map.get(m, "last_regen_at")
         }}

      err ->
        err
    end
  end

  def decode_player(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, m} ->
        {:ok,
         %Player{
           name: Map.get(m, "name", ""),
           title: Map.get(m, "title", ""),
           description: Map.get(m, "description", "")
         }}

      err ->
        err
    end
  end

  # ---- Loading from store ----

  @doc """
  Load the metadata struct for a directory doc whose entries include a
  `__room.json` (or other metadata file). Returns `{:ok, struct}` on
  success, `{:error, reason}` otherwise.
  """
  def load_room(dir_uuid, store \\ CommitStoreClient), do: load_meta(dir_uuid, @room_file, &decode_room/1, store)
  def load_recipe(dir_uuid, store \\ CommitStoreClient), do: load_meta(dir_uuid, @recipe_file, &decode_recipe/1, store)

  def encode_recipe(%Recipe{} = r) do
    Jason.encode!(%{
      "kind" => "recipe",
      "name" => r.name,
      "inputs" => r.inputs,
      "output" => r.output,
      "station" => r.station
    })
  end

  def decode_recipe(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, m} ->
        {:ok,
         %Recipe{
           name: Map.get(m, "name", ""),
           inputs: Map.get(m, "inputs", []),
           output: Map.get(m, "output", %{}),
           station: Map.get(m, "station")
         }}

      {:error, _} = err ->
        err
    end
  end
  def load_object(dir_uuid, store \\ CommitStoreClient), do: load_meta(dir_uuid, @obj_file, &decode_object/1, store)
  def load_player(dir_uuid, store \\ CommitStoreClient), do: load_meta(dir_uuid, @player_file, &decode_player/1, store)

  defp load_meta(dir_uuid, filename, decoder, store) do
    with {:ok, schema} <- load_dir_schema(dir_uuid, store),
         {:ok, entry} <- Schema.get_entry(schema, filename),
         {:ok, doc} <- DocBuilder.reconstruct_doc(store, entry.node_id),
         json when is_binary(json) <- ContentType.get_content(doc) do
      decoder.(json)
    else
      :error -> {:error, {:no_meta_entry, filename}}
      :none -> {:error, {:no_doc, filename}}
      nil -> {:error, {:empty_doc, filename}}
      other -> {:error, other}
    end
  end

  # CX-41qg.3: stable per-doc hand — every caller of this loader
  # re-encodes and chain-commits onto the SAME directory uuid
  # (`add_file_entry`/`add_directory_entry` in `MUD.VerbSource`, room/obj
  # metadata attach in this module). Without a fixed client_id every
  # add-file/add-dir minted a fresh random one, bloating the directory
  # schema's state vector one slot per entry added, forever.
  @doc "Load a directory's Schema doc, returning `{:ok, schema}` or `{:error, :missing}`."
  def load_dir_schema(uuid, store \\ CommitStoreClient) when is_binary(uuid) do
    case CommitStoreClient.latest_commit(store, uuid) do
      {:ok, commit} ->
        doc = Schema.new_schema(client_id: WriterHand.for_doc(uuid))
        {:ok, doc} = Encoding.apply_update(doc, commit.update)
        {:ok, doc}

      :none ->
        {:error, :missing}
    end
  end

  # ---- Writing ----

  @doc """
  Create a new metadata text doc with the given JSON body.

  Returns `{:ok, uuid}` of the new doc, or `{:error, reason}` (CX-93ea)
  when the write is rejected — most commonly `{:trust_rejected, _}`
  under `local_write_gate: :enforce`. Callers must check this rather
  than assume the doc landed.

  `opts` (CX-lg06): `:signing_context`, `:cert_cids`, `:signer_id` — see
  `Commonplace.MUD.SignedWrite`. Genesis doc, so a cert can only cover
  this new uuid if a caller-passed cert's scope was minted wide enough
  to include it ahead of time (ordinarily not the case — see
  `SignedWrite` moduledoc on the no-proof-yet case).
  """
  def create_meta_doc(json, store \\ CommitStoreClient, opts \\ []) when is_binary(json) do
    uuid = UUID.uuid4()
    doc = Doc.new()
    doc = ContentType.create(doc, :text, "metadata")
    doc = ContentType.insert_text(doc, 0, json)
    update = Encoding.encode_update(doc)
    {metadata, commit_opts} = SignedWrite.opts_for(uuid, Keyword.put(opts, :store, store))

    case CommitStoreClient.create_commit(store, uuid, update, nil, metadata, commit_opts) do
      {:error, _} = err -> err
      _commit -> {:ok, uuid}
    end
  end

  @doc """
  Replace the contents of an existing metadata text doc with new JSON.

  Returns `:ok` or `{:error, reason}` (CX-93ea) — never swallows a
  rejected commit.

  `opts` (CX-lg06): `:signing_context`, `:cert_cids`, `:signer_id` — see
  `Commonplace.MUD.SignedWrite`.
  """
  def write_meta_doc(uuid, json, store \\ CommitStoreClient, opts \\ [])
      when is_binary(uuid) and is_binary(json) do
    hand = SignedWrite.hand_for(uuid, opts)
    {:ok, doc} = DocBuilder.reconstruct_doc(store, uuid, client_id: hand)
    current = ContentType.get_content(doc) || ""
    doc = if current != "", do: ContentType.delete_text(doc, 0, String.length(current)), else: doc
    doc = ContentType.insert_text(doc, 0, json)
    update = Encoding.encode_update(doc)
    {metadata, commit_opts} = SignedWrite.opts_for(uuid, Keyword.put(opts, :store, store))

    case CommitStoreClient.create_chained_commit(store, uuid, update, metadata, commit_opts) do
      {:error, _} = err -> err
      _commit -> :ok
    end
  end

  @doc """
  Create a new directory doc, returning its UUID. Optionally writes a
  metadata file inside it (e.g. `__room.json`) and adds it to the new
  directory's schema.

  Returns `{:ok, dir_uuid}` or `{:error, reason}` (CX-93ea) — if the
  meta doc write is rejected, the directory doc is never created either
  (short-circuits before the dir's own genesis commit); if the meta doc
  lands but the dir's own genesis commit is then rejected, the meta doc
  is left as an orphan (no rollback — append-only store; same
  partial-write stance as `WikiLive`'s create-page path, CX-qat5.3).

  `opts` (CX-lg06): `:signing_context`, `:cert_cids`, `:signer_id` — see
  `Commonplace.MUD.SignedWrite`. Genesis doc — see `create_meta_doc/3`
  note on cert coverage.
  """
  def create_dir_with_meta(meta_filename, json, store \\ CommitStoreClient, opts \\ []) do
    dir_uuid = UUID.uuid4()
    dir_doc = Schema.new_schema()

    with {:ok, dir_doc} <- maybe_attach_meta(dir_doc, meta_filename, json, store, opts) do
      update = Encoding.encode_update(dir_doc)
      {metadata, commit_opts} = SignedWrite.opts_for(dir_uuid, Keyword.put(opts, :store, store))

      case CommitStoreClient.create_commit(store, dir_uuid, update, nil, metadata, commit_opts) do
        {:error, _} = err -> err
        _commit -> {:ok, dir_uuid}
      end
    end
  end

  defp maybe_attach_meta(dir_doc, nil, nil, _store, _opts), do: {:ok, dir_doc}

  defp maybe_attach_meta(dir_doc, meta_filename, json, store, opts) do
    case create_meta_doc(json, store, opts) do
      {:ok, meta_uuid} -> {:ok, Schema.add_file(dir_doc, meta_filename, meta_uuid)}
      {:error, _} = err -> err
    end
  end
end
