defmodule Commonplace.Identity.SpawnCeremony do
  @moduledoc """
  The I2 identity spawn ceremony with I3's pinned class-ratification admission.

  A deterministic proposal receipt is the transaction's idempotency gate. The
  receipt is written before key minting and binds one child UUID to the digest
  of one named request. An identical retry resumes that receipt; a different
  request for the same parent/name returns `:spawn_request_conflict`.

  After the parent-signed birth, I3 admits the request against the exact class
  commit named by `class_ref`; no live steward participates in this read.

  Child keys are minted through `AgentKeys` in the caller-supplied child
  workspace SecretStore. Parent and issuer signing contexts are explicit
  options so fenced callers never fall back to masked node key custody.

  The activation document carries a detached Ed25519 signature by the child.
  Its storage commit is parent-signed transport: letting the provisioning
  child author an ordinary commit before certification would violate the
  lifecycle gate this ceremony is responsible for enforcing.
  """

  use GenServer

  alias Commonplace.Crypto.{AgentKeys, Signing, SigningContext}
  alias Commonplace.Document.{ContentType, DocRef}
  alias Commonplace.Identity.{ClassRatification, Root}
  alias Commonplace.Store.{Commit, CommitStoreClient}
  alias Commonplace.Tree.DocBuilder
  alias Commonplace.Trust.Capability
  alias Commonplace.WriterHand
  alias Yelixer.{Doc, Encoding}

  @request_fields ~w(auditor_role budget child_workspace_id class_ref context_seed delegation_depth escalation_parent initial_cell lifetime mission name parent_delegation_depth sla)a
  @statuses ~w(proposed key_minted birth_signed activated active)

  @doc "Start a parent-side ceremony coordinator with explicit fixture-compatible signing contexts."
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Run or resume one named spawn transaction."
  def spawn_child(server, request, opts \\ []),
    do: GenServer.call(server, {:spawn_child, request, opts}, :infinity)

  @doc "The lifecycle gate used by writes and first-deployment admission."
  def authorize_action(server, request), do: GenServer.call(server, {:authorize_action, request})

  @doc "Permit a first deployment only for a fully active receipt."
  def deployment_permitted?(server, request), do: authorize_action(server, request)

  @doc "Attempt a child record write through the lifecycle gate and then I1's ordinary write gate."
  def write_record(server, request, %DocRef{} = ref, record, opts) when is_map(record) do
    with :ok <- authorize_action(server, request) do
      Root.write_record(ref, record, Keyword.fetch!(opts, :store), opts)
    end
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       workspace_root_uuid: Keyword.fetch!(opts, :root_uuid),
       store: Keyword.get(opts, :store, CommitStoreClient),
       parent_context: Keyword.fetch!(opts, :signing_context),
       issuer_context:
         Keyword.get(opts, :issuer_signing_context, Keyword.fetch!(opts, :signing_context))
     }}
  end

  @impl true
  def handle_call({:spawn_child, request, opts}, _from, state) do
    {:reply, run(request, opts, state), state}
  end

  def handle_call({:authorize_action, request}, _from, state) do
    result =
      with {:ok, canonical} <- canonical_request(request),
           {:ok, receipt} <- read_receipt(canonical.name, state),
           true <-
             receipt["request_digest"] == request_digest(canonical) or
               {:error, :spawn_request_conflict},
           "active" <- receipt["status"] do
        :ok
      else
        {:error, :receipt_not_found} -> {:error, {:action_refused, :identity_not_proposed}}
        {:error, :spawn_request_conflict} -> {:error, {:action_refused, :spawn_request_conflict}}
        status when status in @statuses -> {:error, {:action_refused, :identity_provisioning}}
        {:error, reason} -> {:error, {:action_refused, reason}}
      end

    {:reply, result, state}
  end

  defp run(request, opts, state) do
    with {:ok, canonical} <- canonical_request(request),
         digest = request_digest(canonical),
         {:ok, receipt} <- propose(canonical, digest, state),
         :ok <- same_request(receipt, digest, canonical.name),
         {:ok, receipt} <- mint_child_key(receipt, opts, state),
         {:ok, receipt} <- sign_birth(receipt, canonical, state),
         {:ok, _ratified_class} <-
           ClassRatification.authorize_spawn(canonical.class_ref, canonical, state.store),
         {:continue, receipt} <- halt_or_continue(receipt, opts),
         {:ok, receipt} <- sign_activation(receipt, canonical, opts, state),
         {:ok, snapshot} <- land_identity_root(receipt, canonical, state),
         {:ok, receipt, cert} <- mint_certificate(receipt, canonical, request, state),
         {:ok, _active_receipt} <- activate(receipt, snapshot, cert, state),
         {:ok, verified} <- read_receipt(canonical.name, state),
         true <- verified["status"] == "active" or {:error, :activation_did_not_land} do
      {:ok, result(verified, snapshot, cert)}
    else
      {:halt, receipt} -> {:ok, provisioning_result(receipt)}
      {:error, _reason} = error -> error
      false -> {:error, :activation_did_not_land}
    end
  end

  defp canonical_request(request) when is_map(request) do
    with :ok <- require_fields(request),
         %Capability{} = parent <- Map.get(request, :parent_capability),
         grant when is_map(grant) <- Map.get(request, :grant),
         true <- is_binary(request.name) and request.name != "",
         true <- is_binary(request.child_workspace_id) and request.child_workspace_id != "" do
      {:ok,
       request
       |> Map.take(@request_fields)
       |> Map.put(:parent_capability_id, parent.id)
       |> Map.put(:grant, normalized_claim(grant))}
    else
      _ -> {:error, :invalid_spawn_request}
    end
  end

  defp canonical_request(_request), do: {:error, :invalid_spawn_request}

  defp require_fields(request) do
    required = @request_fields ++ [:grant, :parent_capability]

    if Enum.all?(required, &Map.has_key?(request, &1)),
      do: :ok,
      else: {:error, :missing_spawn_field}
  end

  defp normalized_claim(claim) do
    %{
      verbs: claim |> Map.get(:verbs, []) |> Enum.uniq() |> Enum.sort(),
      scope: normalize_scope(Map.get(claim, :scope, {:docs, []})),
      caveats: %{
        not_before: get_in(claim, [:caveats, :not_before]),
        not_after: get_in(claim, [:caveats, :not_after])
      }
    }
  end

  defp normalize_scope({:docs, uuids}), do: {:docs, uuids |> Enum.uniq() |> Enum.sort()}
  defp normalize_scope(scope), do: scope

  defp request_digest(canonical) do
    canonical
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp receipt_uuid(parent_uuid, name),
    do: UUID.uuid5(:url, "urn:commonplace:identity-spawn:#{parent_uuid}:#{name}")

  defp propose(canonical, digest, state) do
    case read_receipt(canonical.name, state) do
      {:ok, receipt} ->
        {:ok, receipt}

      {:error, :receipt_not_found} ->
        receipt = %{
          "child_uuid" => UUID.uuid4(),
          "name" => canonical.name,
          "request_digest" => digest,
          "status" => "proposed"
        }

        case create_json(
               receipt_uuid(state.workspace_root_uuid, canonical.name),
               "spawn-proposal-#{canonical.name}",
               receipt,
               state.store,
               state.parent_context,
               :regular
             ) do
          {:ok, _commit} -> read_receipt(canonical.name, state)
          {:error, :parent_moved} -> read_receipt(canonical.name, state)
          {:error, reason} -> {:error, {:proposal_refused, reason}}
        end
    end
  end

  defp same_request(receipt, digest, name) do
    if receipt["request_digest"] == digest do
      :ok
    else
      {:error,
       {:spawn_request_conflict,
        %{name: name, existing_digest: receipt["request_digest"], requested_digest: digest}}}
    end
  end

  defp mint_child_key(%{"status" => "proposed"} = receipt, opts, state) do
    child_secret_store = Keyword.fetch!(opts, :child_secret_store)

    with {:ok, public_key} <- AgentKeys.ensure(receipt["child_uuid"], child_secret_store) do
      update_receipt(
        Map.merge(receipt, %{
          "public_key" => Signing.encode_key(public_key),
          "status" => "key_minted"
        }),
        state
      )
    end
  end

  defp mint_child_key(receipt, _opts, _state), do: {:ok, receipt}

  defp sign_birth(%{"status" => "key_minted"} = receipt, canonical, state) do
    birth = %{
      "child_uuid" => receipt["child_uuid"],
      "class_ref" => canonical.class_ref,
      "context_seed" => canonical.context_seed,
      "created_by" => state.parent_context.identity_uuid,
      "public_key" => receipt["public_key"],
      "request_digest" => receipt["request_digest"]
    }

    uuid = UUID.uuid5(:url, "urn:commonplace:identity-birth:#{receipt["request_digest"]}")

    with {:ok, commit} <-
           ensure_json(uuid, "identity-birth", birth, state.store, state.parent_context, :regular),
         {:ok, reread} <- read_json(uuid, state.store),
         true <- reread == birth or {:error, :birth_reread_mismatch} do
      update_receipt(
        Map.merge(receipt, %{
          "birth_commit" => encode_cid(commit.id),
          "birth_uuid" => uuid,
          "status" => "birth_signed"
        }),
        state
      )
    end
  end

  defp sign_birth(receipt, _canonical, _state), do: {:ok, receipt}

  defp halt_or_continue(%{"status" => "birth_signed"} = receipt, opts) do
    if Keyword.get(opts, :halt_after) == :birth,
      do: {:halt, receipt},
      else: {:continue, receipt}
  end

  defp halt_or_continue(receipt, _opts), do: {:continue, receipt}

  defp sign_activation(%{"status" => "birth_signed"} = receipt, canonical, opts, state) do
    child_secret_store = Keyword.fetch!(opts, :child_secret_store)

    with {:ok, child_context} <-
           AgentKeys.signing_context_for(receipt["child_uuid"], child_secret_store) do
      accepted_genesis = %{
        "birth_commit" => receipt["birth_commit"],
        "class_ref" => canonical.class_ref,
        "created_by" => state.parent_context.identity_uuid,
        "identity_uuid" => receipt["child_uuid"]
      }

      activation = %{
        "accepted_genesis" => accepted_genesis,
        "accepted_context_seed" => canonical.context_seed,
        "child_uuid" => receipt["child_uuid"]
      }

      activation =
        Map.merge(activation, %{
          "child_public_key" => Signing.encode_key(child_context.public_key),
          "child_signature" =>
            activation
            |> activation_digest()
            |> then(&:crypto.sign(:eddsa, :none, &1, [child_context.private_key, :ed25519]))
            |> Base.encode64()
        })

      uuid = UUID.uuid5(:url, "urn:commonplace:identity-activation:#{receipt["request_digest"]}")

      with {:ok, commit} <-
             ensure_json(
               uuid,
               "identity-activation",
               activation,
               state.store,
               state.parent_context,
               :regular
             ),
           {:ok, reread} <- read_json(uuid, state.store),
           true <- reread == activation or {:error, :activation_reread_mismatch} do
        update_receipt(
          Map.merge(receipt, %{
            "activation" => encode_cid(commit.id),
            "activation_uuid" => uuid,
            "status" => "activated"
          }),
          state
        )
      end
    end
  end

  defp sign_activation(receipt, _canonical, _opts, _state), do: {:ok, receipt}

  defp land_identity_root(receipt, canonical, state) do
    case Root.read(receipt["child_uuid"], state.store) do
      {:ok, root} -> snapshot_from_root(receipt["child_uuid"], root)
      {:error, :identity_root_not_found} -> create_identity_root(receipt, canonical, state)
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_identity_root(receipt, canonical, state) do
    genesis = %{
      "activation" => receipt["activation"],
      "birth_commit" => receipt["birth_commit"],
      "class_ref" => canonical.class_ref,
      "created_by" => state.parent_context.identity_uuid
    }

    case Root.start_link(
           root_uuid: state.workspace_root_uuid,
           identity_uuid: receipt["child_uuid"],
           name: canonical.name,
           genesis: genesis,
           understanding: %{"seed_refs" => canonical.context_seed},
           store: state.store,
           signing_context: state.parent_context
         ) do
      {:ok, server} ->
        snapshot = Root.snapshot(server)
        GenServer.stop(server)
        {:ok, snapshot}

      {:error, reason} ->
        {:error, {:identity_root_refused, reason}}
    end
  end

  defp snapshot_from_root(uuid, %{"genesis" => genesis, "records" => records}) do
    with {:ok, understanding} <- DocRef.parse(records["understanding"]) do
      {:ok, %{root_uuid: uuid, genesis: genesis, records: %{"understanding" => understanding}}}
    end
  end

  defp mint_certificate(%{"status" => "activated"} = receipt, canonical, request, state) do
    parent = request.parent_capability
    claim = canonical.grant

    with :ok <- validate_parent_holder(parent, state.issuer_context),
         :ok <- validate_grant_axes(claim, parent.claim, canonical.delegation_depth, request),
         {:ok, cert} <-
           Capability.issue(
             state.issuer_context,
             {receipt["child_uuid"], decode_key!(receipt["public_key"])},
             claim,
             parent.id,
             parent: parent,
             store: state.store
           ),
         :ok <- CommitStoreClient.store_capability(state.store, cert),
         {:ok, reread_cert} <- reread_capability(state.store, cert.id),
         true <- reread_cert.id == cert.id or {:error, :certificate_reread_mismatch},
         {:ok, receipt} <-
           update_receipt(
             Map.merge(receipt, %{"certificate" => encode_cid(cert.id)}),
             state
           ) do
      {:ok, receipt, cert}
    end
  end

  defp mint_certificate(receipt, _canonical, _request, state) do
    with {:ok, cert_id} <- Base.decode16(receipt["certificate"], case: :mixed),
         {:ok, cert} <- reread_capability(state.store, cert_id) do
      {:ok, receipt, cert}
    end
  end

  defp validate_parent_holder(%Capability{audience: {uuid, pub}}, %SigningContext{} = issuer) do
    if uuid == issuer.identity_uuid and pub == issuer.public_key,
      do: :ok,
      else: {:error, {:grant_outside_parent_holdings, :issuer}}
  end

  defp validate_grant_axes(child, parent, requested_depth, request) do
    cond do
      not MapSet.subset?(MapSet.new(child.verbs), MapSet.new(parent.verbs)) ->
        {:error, {:grant_outside_parent_holdings, :verbs}}

      not scope_within?(child.scope, parent.scope) ->
        {:error, {:grant_outside_parent_holdings, :scope}}

      not caveats_within?(child.caveats, parent.caveats) ->
        {:error, {:grant_outside_parent_holdings, :expiry}}

      requested_depth > Map.get(request, :parent_delegation_depth, requested_depth) ->
        {:error, {:grant_outside_parent_holdings, :delegation_depth}}

      true ->
        :ok
    end
  end

  defp scope_within?({:docs, child}, {:docs, parent}),
    do: MapSet.subset?(MapSet.new(child), MapSet.new(parent))

  defp scope_within?(scope, scope), do: true
  defp scope_within?(_child, _parent), do: false

  defp caveats_within?(child, parent) do
    lower_within?(child.not_before, parent.not_before) and
      upper_within?(child.not_after, parent.not_after)
  end

  defp lower_within?(_child, nil), do: true
  defp lower_within?(nil, _parent), do: false
  defp lower_within?(child, parent), do: DateTime.compare(child, parent) in [:eq, :gt]
  defp upper_within?(_child, nil), do: true
  defp upper_within?(nil, _parent), do: false
  defp upper_within?(child, parent), do: DateTime.compare(child, parent) in [:eq, :lt]

  defp activate(receipt, snapshot, cert, state) do
    update_receipt(
      Map.merge(receipt, %{
        "certificate" => encode_cid(cert.id),
        "identity_ref" =>
          DocRef.to_string(
            DocRef.new(snapshot.root_uuid, path: "__identities__/#{receipt["name"]}.json")
          ),
        "status" => "active"
      }),
      state
    )
  end

  defp result(receipt, snapshot, cert) do
    %{
      activation: receipt["activation"],
      capability_proofs: [encode_cid(cert.id)],
      child_uuid: receipt["child_uuid"],
      identity_ref: receipt["identity_ref"],
      records: snapshot.records,
      status: :active
    }
  end

  defp provisioning_result(receipt) do
    %{
      birth_commit: receipt["birth_commit"],
      child_uuid: receipt["child_uuid"],
      status: :provisioning
    }
  end

  defp read_receipt(name, state) do
    uuid = receipt_uuid(state.workspace_root_uuid, name)

    case read_json(uuid, state.store) do
      {:ok, receipt} -> {:ok, receipt}
      {:error, :not_found} -> {:error, :receipt_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp update_receipt(receipt, state) do
    uuid = receipt_uuid(state.workspace_root_uuid, receipt["name"])

    with {:ok, before} <- DocBuilder.reconstruct_doc(state.store, uuid),
         current when is_binary(current) <- ContentType.get_content(before) do
      doc = %{
        before
        | client_id: WriterHand.for_doc_actor(uuid, state.parent_context.identity_uuid)
      }

      doc = ContentType.delete_text(doc, 0, String.length(current))
      doc = ContentType.insert_text(doc, 0, Jason.encode!(receipt))

      case CommitStoreClient.create_chained_commit(
             state.store,
             uuid,
             Encoding.encode_update(doc),
             %{kind: :regular},
             signing_context: state.parent_context
           ) do
        %Commit{} -> verify_receipt(receipt, state)
        {:error, reason} -> {:error, {:receipt_write_refused, reason}}
      end
    end
  end

  defp verify_receipt(expected, state) do
    with {:ok, reread} <- read_receipt(expected["name"], state),
         true <- reread == expected or {:error, :receipt_reread_mismatch} do
      {:ok, reread}
    end
  end

  defp ensure_json(uuid, name, body, store, signing_context, kind) do
    case CommitStoreClient.latest_commit(store, uuid) do
      {:ok, commit} -> {:ok, commit}
      :none -> create_json(uuid, name, body, store, signing_context, kind)
    end
  end

  defp create_json(uuid, name, body, store, signing_context, kind) do
    doc = Doc.new(client_id: WriterHand.for_doc_actor(uuid, signing_context.identity_uuid))
    doc = ContentType.create(doc, :text, name)
    doc = ContentType.insert_text(doc, 0, Jason.encode!(body))

    case CommitStoreClient.create_commit(
           store,
           uuid,
           Encoding.encode_update(doc),
           nil,
           %{kind: kind},
           signing_context: signing_context
         ) do
      %Commit{} = commit -> {:ok, commit}
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_json(uuid, store) do
    with {:ok, doc} <- DocBuilder.reconstruct_doc(store, uuid),
         body when is_binary(body) <- ContentType.get_content(doc),
         {:ok, decoded} when is_map(decoded) <- Jason.decode(body) do
      {:ok, decoded}
    else
      :none -> {:error, :not_found}
      _ -> {:error, :invalid_ceremony_document}
    end
  end

  defp reread_capability(store, cid) do
    case CommitStoreClient.get_capability(store, cid) do
      {:ok, capability} -> {:ok, capability}
      :none -> {:error, :certificate_not_found}
    end
  end

  defp decode_key!(encoded) do
    {:ok, key} = Signing.decode_key(encoded)
    key
  end

  defp activation_digest(activation) do
    activation
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
  end

  defp encode_cid(cid), do: Base.encode16(cid, case: :lower)
end
