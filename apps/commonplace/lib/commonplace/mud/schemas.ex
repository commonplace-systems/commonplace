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
              tick_interval_ms: nil,
              tick_message: nil

    @type t :: %__MODULE__{
            name: String.t(),
            aliases: [String.t()],
            description: String.t(),
            fixed: boolean(),
            tick_interval_ms: pos_integer() | nil,
            tick_message: String.t() | nil
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

  def room_filename, do: @room_file
  def object_filename, do: @obj_file
  def player_filename, do: @player_file

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
      "kind" => "object",
      "name" => o.name,
      "aliases" => o.aliases,
      "description" => o.description,
      "fixed" => o.fixed,
      "tick_interval_ms" => o.tick_interval_ms,
      "tick_message" => o.tick_message
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
           tick_interval_ms: Map.get(m, "tick_interval_ms"),
           tick_message: Map.get(m, "tick_message")
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
  Create a new metadata text doc with the given JSON body. Returns the
  UUID of the new doc.

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
    CommitStoreClient.create_commit(store, uuid, update, nil, metadata, commit_opts)
    uuid
  end

  @doc """
  Replace the contents of an existing metadata text doc with new JSON.

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
    CommitStoreClient.create_chained_commit(store, uuid, update, metadata, commit_opts)
    :ok
  end

  @doc """
  Create a new directory doc, returning its UUID. Optionally writes a
  metadata file inside it (e.g. `__room.json`) and adds it to the new
  directory's schema.

  `opts` (CX-lg06): `:signing_context`, `:cert_cids`, `:signer_id` — see
  `Commonplace.MUD.SignedWrite`. Genesis doc — see `create_meta_doc/3`
  note on cert coverage.
  """
  def create_dir_with_meta(meta_filename, json, store \\ CommitStoreClient, opts \\ []) do
    dir_uuid = UUID.uuid4()
    dir_doc = Schema.new_schema()

    dir_doc =
      if json do
        meta_uuid = create_meta_doc(json, store, opts)
        Schema.add_file(dir_doc, meta_filename, meta_uuid)
      else
        dir_doc
      end

    update = Encoding.encode_update(dir_doc)
    {metadata, commit_opts} = SignedWrite.opts_for(dir_uuid, Keyword.put(opts, :store, store))
    CommitStoreClient.create_commit(store, dir_uuid, update, nil, metadata, commit_opts)
    dir_uuid
  end
end
