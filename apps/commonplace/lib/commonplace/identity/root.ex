defmodule Commonplace.Identity.Root do
  @moduledoc """
  The addressable identity root introduced by I1.

  An identity root is a JSON document at `__identities__/<name>.json`. Its
  `genesis` object is written once at creation and its `records` object is a
  map of `Commonplace.Document.DocRef` strings. I1 creates exactly one governed
  record, `understanding`.

  Record authority is deliberately absent from this module. `write_record/4`
  attaches the caller-supplied capability proof to a normal signed commit and
  leaves the decision to the existing local-write gate. Each governed record
  is a separate, self-zoned JSON document, so a cert scoped to
  `{:subtree, record_uuid}` covers that record and not a sibling record.

  `:signing_context` is injectable through `start_link/1` into `init/1` so
  fenced fixtures do not depend on ambient node key custody. When omitted, the
  creator context is resolved through `NodeIdentity.signing_context/0`.
  """

  use GenServer

  alias Commonplace.Crypto.NodeIdentity
  alias Commonplace.Document.{ContentType, DocRef}
  alias Commonplace.Store.{Commit, CommitStoreClient}
  alias Commonplace.Tree.{DocBuilder, Schema}
  alias Commonplace.WriterHand
  alias Yelixer.{Doc, Encoding}

  @genesis_fields ~w(activation birth_commit class_ref created_by)
  @identities_dir "__identities__"

  @type genesis :: %{
          required(String.t()) => String.t()
        }

  @doc "Start an I1 identity root creator/holder."
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Return the created root UUID, genesis object, and parsed record DocRefs."
  def snapshot(server), do: GenServer.call(server, :snapshot)

  @doc "Read and parse an identity root directly from the commit store."
  def read(root_uuid, store \\ CommitStoreClient) do
    with {:ok, doc} <- DocBuilder.reconstruct_doc(store, root_uuid),
         body when is_binary(body) <- ContentType.get_content(doc),
         {:ok, root} when is_map(root) <- Jason.decode(body) do
      {:ok, root}
    else
      :none -> {:error, :identity_root_not_found}
      _ -> {:error, :invalid_identity_root}
    end
  end

  @doc "Read and parse the JSON body of a governed record DocRef."
  def read_record(%DocRef{uuid: uuid}, store \\ CommitStoreClient) do
    with {:ok, doc} <- DocBuilder.reconstruct_doc(store, uuid),
         body when is_binary(body) <- ContentType.get_content(doc),
         {:ok, record} when is_map(record) <- Jason.decode(body) do
      {:ok, record}
    else
      :none -> {:error, :record_not_found}
      _ -> {:error, :invalid_record}
    end
  end

  @doc """
  Replace a governed record through the ordinary signed local-write path.

  The supplied `:capability_proof` is attached even when its scope does not
  cover the target. That is essential for negative fixtures: the existing
  gate, rather than pre-selection or identity code, must inspect and refuse
  the same cert. A refusal is enriched with the DocRef path and the cert's
  carried scope for an artifact-checkable diagnostic; the nested `gate_error`
  is the store's unchanged verdict.
  """
  @spec write_record(DocRef.t(), map(), GenServer.server(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def write_record(%DocRef{} = ref, record, store \\ CommitStoreClient, opts \\ [])
      when is_map(record) do
    with {:ok, signing_context} <- Keyword.fetch(opts, :signing_context),
         {:ok, capability_proof} <- Keyword.fetch(opts, :capability_proof),
         {:ok, before} <- DocBuilder.reconstruct_doc(store, ref.uuid) do
      doc = %{
        before
        | client_id: WriterHand.for_doc_actor(ref.uuid, signing_context.identity_uuid)
      }

      current = ContentType.get_content(doc) || ""

      doc =
        if current == "", do: doc, else: ContentType.delete_text(doc, 0, String.length(current))

      doc = ContentType.insert_text(doc, 0, Jason.encode!(record))

      result =
        CommitStoreClient.create_chained_commit(
          store,
          ref.uuid,
          Encoding.encode_update(doc),
          %{kind: :regular, capability_proof: capability_proof},
          signing_context: signing_context
        )

      case result do
        %Commit{} = commit ->
          {:ok,
           %{
             attempted_path: ref.path,
             cert_cid: encode_cid(capability_proof),
             cert_scope: capability_scope(store, capability_proof),
             commit_id: encode_cid(commit.id)
           }}

        {:error, gate_error} ->
          {:error,
           {:record_write_refused,
            %{
              attempted_path: ref.path,
              cert_cid: encode_cid(capability_proof),
              cert_scope: capability_scope(store, capability_proof),
              gate_error: gate_error
            }}}
      end
    end
  end

  @impl true
  def init(opts) do
    workspace_root_uuid = Keyword.fetch!(opts, :root_uuid)
    name = Keyword.fetch!(opts, :name)
    genesis = Keyword.fetch!(opts, :genesis)
    understanding = Keyword.get(opts, :understanding, %{})
    store = Keyword.get(opts, :store, CommitStoreClient)

    identity_uuid = Keyword.get(opts, :identity_uuid, UUID.uuid4())

    with :ok <- validate_name(name),
         :ok <- validate_genesis(genesis),
         :ok <- validate_understanding(understanding),
         {:ok, signing_context} <- resolve_signing_context(opts),
         {:ok, identities_uuid} <-
           Commonplace.Presence.Identity.ensure_identities_dir(
             workspace_root_uuid,
             store,
             signing_context: signing_context
           ),
         {:ok, understanding_ref} <-
           create_record(name, "understanding", understanding, store, signing_context),
         {:ok, root_uuid} <-
           create_root(
             identity_uuid,
             name,
             genesis,
             understanding_ref,
             identities_uuid,
             store,
             signing_context
           ),
         {:ok, root} <- read(root_uuid, store),
         :ok <- verify_landed_root(root, genesis, understanding_ref) do
      {:ok,
       %{
         root_uuid: root_uuid,
         genesis: genesis,
         records: %{"understanding" => understanding_ref},
         store: store
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, Map.take(state, [:root_uuid, :genesis, :records]), state}
  end

  defp create_record(identity_name, record_name, contents, store, signing_context) do
    uuid = UUID.uuid4()
    path = "#{@identities_dir}/#{identity_name}.json/records.#{record_name}"
    body = contents |> stringify_keys() |> Map.put("zone", uuid) |> Jason.encode!()

    case create_json_doc(uuid, record_name, body, store, signing_context) do
      %Commit{} -> {:ok, DocRef.new(uuid, path: path)}
      {:error, reason} -> {:error, {:record_create_refused, record_name, reason}}
    end
  end

  defp create_root(
         root_uuid,
         name,
         genesis,
         understanding_ref,
         identities_uuid,
         store,
         signing_context
       ) do
    filename = "#{name}.json"

    body =
      Jason.encode!(%{
        "genesis" => stringify_keys(genesis),
        "records" => %{"understanding" => DocRef.to_string(understanding_ref)}
      })

    with %Commit{} <- create_json_doc(root_uuid, filename, body, store, signing_context),
         {:ok, identities_doc} <- DocBuilder.reconstruct_doc(store, identities_uuid) do
      identities_doc = %{identities_doc | client_id: WriterHand.for_doc(identities_uuid)}
      identities_doc = Schema.add_file(identities_doc, filename, root_uuid)

      case CommitStoreClient.create_chained_commit(
             store,
             identities_uuid,
             Encoding.encode_update(identities_doc),
             %{kind: :regular},
             signing_context: signing_context
           ) do
        %Commit{} -> verify_directory_entry(identities_uuid, filename, root_uuid, store)
        {:error, reason} -> {:error, {:identity_root_attach_refused, reason}}
      end
    else
      {:error, reason} -> {:error, {:identity_root_create_refused, reason}}
      :none -> {:error, :identities_directory_not_found}
    end
  end

  defp create_json_doc(uuid, name, body, store, signing_context) do
    doc = Doc.new(client_id: WriterHand.for_doc(uuid))
    doc = ContentType.create(doc, :text, name)
    doc = ContentType.insert_text(doc, 0, body)

    CommitStoreClient.create_commit(
      store,
      uuid,
      Encoding.encode_update(doc),
      nil,
      %{kind: :regular},
      signing_context: signing_context
    )
  end

  defp verify_directory_entry(identities_uuid, filename, root_uuid, store) do
    with {:ok, doc} <- DocBuilder.reconstruct_doc(store, identities_uuid),
         {:ok, %{node_id: ^root_uuid, type: :doc}} <- Schema.get_entry(doc, filename) do
      {:ok, root_uuid}
    else
      _ -> {:error, :identity_root_attach_did_not_land}
    end
  end

  defp verify_landed_root(root, genesis, understanding_ref) do
    expected = %{
      "genesis" => stringify_keys(genesis),
      "records" => %{"understanding" => DocRef.to_string(understanding_ref)}
    }

    if root == expected, do: :ok, else: {:error, :identity_root_reread_mismatch}
  end

  defp resolve_signing_context(opts) do
    case Keyword.fetch(opts, :signing_context) do
      {:ok, context} -> {:ok, context}
      :error -> NodeIdentity.signing_context()
    end
  end

  defp capability_scope(store, cid) do
    case CommitStoreClient.get_capability(store, cid) do
      {:ok, capability} -> capability.claim.scope
      :none -> :capability_not_found
    end
  end

  defp encode_cid(cid) when is_binary(cid), do: Base.encode16(cid, case: :lower)

  defp validate_name(name) when is_binary(name) and byte_size(name) > 0 do
    if String.contains?(name, ["/", "\\", ".."]),
      do: {:error, :invalid_identity_name},
      else: :ok
  end

  defp validate_name(_name), do: {:error, :invalid_identity_name}

  defp validate_genesis(genesis) when is_map(genesis) do
    genesis = stringify_keys(genesis)

    if Enum.sort(Map.keys(genesis)) == @genesis_fields and
         Enum.all?(genesis, fn {_key, value} -> is_binary(value) and value != "" end) do
      :ok
    else
      {:error, {:invalid_genesis, @genesis_fields}}
    end
  end

  defp validate_genesis(_genesis), do: {:error, {:invalid_genesis, @genesis_fields}}

  defp validate_understanding(understanding) when is_map(understanding), do: :ok
  defp validate_understanding(_understanding), do: {:error, :invalid_understanding}

  defp stringify_keys(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} when is_binary(key) -> {key, value}
    end)
  end
end
