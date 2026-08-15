defmodule Commonplace.Identity.ClassRatification do
  @moduledoc """
  Steward ratification and pinned reads for identity classes.

  A class is an ordinary signed JSON document. The returned `DocRef` pins the
  ratification commit in its existing `cid` field; admission deliberately uses
  `Projection.project_doc_at/3` because `DocRef.uuid/1` explicitly ignores that pin.

  The steward process is only the writer. Spawn admission and identity class
  reads use the committed document directly, so neither operation requires a
  live steward.
  """

  use GenServer

  alias Commonplace.Document.{ContentType, DocRef}
  alias Commonplace.Identity.Root
  alias Commonplace.Projection
  alias Commonplace.Store.{Commit, CommitStoreClient}
  alias Commonplace.Tree.DocBuilder
  alias Commonplace.WriterHand
  alias Yelixer.{Doc, Encoding}

  @class_fields ~w(auditor_role escalation_parent mission_template scope_envelope sla)

  @doc "Start a steward-side class writer with an explicit signing context."
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Return the currently ratified, commit-pinned class reference and body."
  def snapshot(server), do: GenServer.call(server, :snapshot)

  @doc "Amend the class and return a new reference pinned to the amendment commit."
  def amend(server, class), do: GenServer.call(server, {:amend, class})

  @doc "Read exactly the class version named by a pinned DocRef or ref string."
  def read_pinned(ref, store \\ CommitStoreClient)

  def read_pinned(ref, store) when is_binary(ref) do
    with {:ok, parsed} <- DocRef.parse(ref) do
      read_pinned(parsed, store)
    end
  end

  def read_pinned(%DocRef{cid: nil}, _store), do: {:error, :class_version_required}

  def read_pinned(%DocRef{uuid: uuid, cid: cid}, store) do
    with {:ok, commit_id} <- decode_cid(cid),
         {:ok, doc} <- pinned_doc(store, uuid, commit_id),
         body when is_binary(body) <- ContentType.get_content(doc),
         {:ok, class} when is_map(class) <- Jason.decode(body),
         :ok <- validate_class(class) do
      {:ok, class}
    else
      :none -> {:error, :class_version_not_found}
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_class_document}
    end
  end

  @doc "Check all ratified class axes for one canonical spawn request."
  def authorize_spawn(ref, request, store \\ CommitStoreClient) when is_map(request) do
    with {:ok, class} <- read_pinned(ref, store),
         :ok <- exact_axis(class, request, "mission_template", :mission),
         :ok <- scope_axis(class, request),
         :ok <- exact_axis(class, request, "auditor_role", :auditor_role),
         :ok <- exact_axis(class, request, "escalation_parent", :escalation_parent),
         :ok <- exact_axis(class, request, "sla", :sla) do
      {:ok, class}
    end
  end

  @doc "Resolve an existing identity through the class version pinned in genesis."
  def class_for_identity(identity_uuid, store \\ CommitStoreClient) do
    with {:ok, root} <- Root.read(identity_uuid, store),
         class_ref when is_binary(class_ref) <- get_in(root, ["genesis", "class_ref"]) do
      read_pinned(class_ref, store)
    else
      _ -> {:error, :identity_class_ref_not_found}
    end
  end

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    class = Keyword.fetch!(opts, :class)
    store = Keyword.get(opts, :store, CommitStoreClient)
    signing_context = Keyword.fetch!(opts, :signing_context)
    uuid = Keyword.get(opts, :uuid, UUID.uuid4())
    path = "classes/#{name}.json"

    with :ok <- validate_name(name),
         :ok <- validate_class(class),
         {:ok, commit} <- create_class(uuid, name, class, store, signing_context),
         ref = pinned_ref(uuid, path, commit),
         {:ok, reread} <- read_pinned(ref, store),
         true <- reread == stringify_keys(class) or {:error, :class_ratification_reread_mismatch} do
      {:ok,
       %{
         class: reread,
         class_ref: ref,
         path: path,
         signing_context: signing_context,
         store: store,
         uuid: uuid
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, Map.take(state, [:class, :class_ref]), state}
  end

  def handle_call({:amend, class}, _from, state) do
    case amend_class(class, state) do
      {:ok, ref, reread} ->
        state = %{state | class: reread, class_ref: ref}
        {:reply, {:ok, Map.take(state, [:class, :class_ref])}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp amend_class(class, state) do
    with :ok <- validate_class(class),
         {:ok, before} <- DocBuilder.reconstruct_doc(state.store, state.uuid),
         current when is_binary(current) <- ContentType.get_content(before) do
      doc = %{
        before
        | client_id: WriterHand.for_doc_actor(state.uuid, state.signing_context.identity_uuid)
      }

      doc = ContentType.delete_text(doc, 0, String.length(current))
      doc = ContentType.insert_text(doc, 0, Jason.encode!(stringify_keys(class)))

      case CommitStoreClient.create_chained_commit(
             state.store,
             state.uuid,
             Encoding.encode_update(doc),
             %{kind: :regular},
             signing_context: state.signing_context
           ) do
        %Commit{} = commit ->
          ref = pinned_ref(state.uuid, state.path, commit)

          with {:ok, reread} <- read_pinned(ref, state.store),
               true <-
                 reread == stringify_keys(class) or {:error, :class_amendment_reread_mismatch} do
            {:ok, ref, reread}
          end

        {:error, reason} ->
          {:error, {:class_amendment_refused, reason}}
      end
    else
      :none -> {:error, :class_not_found}
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_class_document}
    end
  end

  defp create_class(uuid, name, class, store, signing_context) do
    doc = Doc.new(client_id: WriterHand.for_doc_actor(uuid, signing_context.identity_uuid))
    doc = ContentType.create(doc, :text, name)
    doc = ContentType.insert_text(doc, 0, Jason.encode!(stringify_keys(class)))

    case CommitStoreClient.create_commit(
           store,
           uuid,
           Encoding.encode_update(doc),
           nil,
           %{kind: :regular},
           signing_context: signing_context
         ) do
      %Commit{} = commit -> {:ok, commit}
      {:error, reason} -> {:error, {:class_ratification_refused, reason}}
    end
  end

  defp pinned_doc(store, uuid, commit_id) do
    case Projection.project_doc_at(uuid, commit_id,
           store: store,
           head_path: :chain,
           require_head_reachable: true
         ) do
      {:ok, doc, _verdict} -> {:ok, doc}
      {:unknown, reason} -> {:error, {:class_projection_unknown, reason}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp pinned_ref(uuid, path, commit) do
    DocRef.new(uuid, path: path, cid: Base.encode16(commit.id, case: :lower))
  end

  defp exact_axis(class, request, class_field, request_field) do
    if class[class_field] == Map.get(request, request_field),
      do: :ok,
      else: {:error, {:spawn_outside_class, request_field}}
  end

  defp scope_axis(class, request) do
    requested_scope = get_in(request, [:grant, :scope])

    within? =
      case requested_scope do
        {:docs, uuids} when is_list(uuids) ->
          MapSet.subset?(MapSet.new(uuids), MapSet.new(class["scope_envelope"]))

        _ ->
          false
      end

    if within?, do: :ok, else: {:error, {:spawn_outside_class, :scope}}
  end

  defp validate_name(name) when is_binary(name) and name != "" do
    if String.contains?(name, ["/", "\\", ".."]),
      do: {:error, :invalid_class_name},
      else: :ok
  end

  defp validate_name(_name), do: {:error, :invalid_class_name}

  defp validate_class(class) when is_map(class) do
    class = stringify_keys(class)

    valid? =
      Enum.sort(Map.keys(class)) == @class_fields and
        is_binary(class["mission_template"]) and class["mission_template"] != "" and
        is_list(class["scope_envelope"]) and
        Enum.all?(class["scope_envelope"], &(is_binary(&1) and &1 != "")) and
        Enum.all?(~w(auditor_role escalation_parent sla), fn field ->
          is_binary(class[field]) and class[field] != ""
        end)

    if valid?, do: :ok, else: {:error, {:invalid_class, @class_fields}}
  end

  defp validate_class(_class), do: {:error, {:invalid_class, @class_fields}}

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp decode_cid(cid) when is_binary(cid) do
    case Base.decode16(cid, case: :mixed) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> {:error, :invalid_class_version}
    end
  end
end
