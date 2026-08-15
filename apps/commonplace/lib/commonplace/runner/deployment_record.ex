defmodule Commonplace.Runner.DeploymentRecord do
  @moduledoc """
  Runner-owned append-only deployment records and durable promotions.

  A deployment log is an ephemeral-tier `RedLog`. Each call to `append/3`
  adds one complete §7 deployment record and confirms the write by re-reading
  the log. References that promise a durable artifact must be commit-pinned;
  an unpinned `DocRef` is refused rather than resolved at latest.

  Yields, decisions, and findings are stored as separate durable documents by
  `promote/5`. `read_promoted/2` resolves their exact pinned commit through
  `Projection`, so eviction of the deployment log cannot change the promoted
  value.

  `range_status/4` distinguishes a present commit, a missing commit covered by
  a valid signed SLA tombstone, and absence without a tombstone. The last state
  is deliberately not called "never written": without an independent
  ever-written receipt it is observationally identical to loss. The optional
  fetch seams exist for eviction simulation; production callers use the commit
  store directly. A supplied tombstone is always verified.
  """

  alias Commonplace.Crypto.SigningContext
  alias Commonplace.Dataflow.RedLog
  alias Commonplace.Document.{ContentType, DocRef}
  alias Commonplace.Projection
  alias Commonplace.Store.{Commit, CommitStoreClient, SlaTombstone}
  alias Commonplace.WriterHand
  alias Yelixer.{Doc, Encoding}

  @ephemeral_sla %{tier: "ephemeral", retention: "30 days", note: nil}
  @durable_sla %{tier: "durable", retention: "indefinite", note: nil}
  @promotion_kinds ~w(yield decision finding)a

  @record_fields ~w(
    ask_ref budget capability_proofs cell_manifest_ref class_ref context_inputs
    decision_refs deployment_id ended_at finding_refs identity_ref outputs
    runtime_profile started_at yields
  )

  @single_ref_fields ~w(ask_ref cell_manifest_ref class_ref identity_ref)
  @ref_list_fields ~w(context_inputs decision_refs finding_refs outputs yields)

  @doc "The SLA attached to every deployment-log commit."
  def ephemeral_sla, do: @ephemeral_sla

  @doc "Append one complete deployment record and confirm it by re-read."
  @spec append(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def append(log_uuid, record, opts)
      when is_binary(log_uuid) and is_map(record) and is_list(opts) do
    store = Keyword.get(opts, :store, CommitStoreClient)

    with {:ok, %SigningContext{} = signing_context} <- Keyword.fetch(opts, :signing_context),
         {:ok, record} <- validate_record(record),
         before = log_uuid |> RedLog.load(store) |> RedLog.read(),
         :ok <- unique_deployment(before, record),
         expected_parent <- latest_id(store, log_uuid),
         log = log_uuid |> RedLog.load(store) |> RedLog.append_raw(record),
         {:ok, _log} <-
           RedLog.commit(log,
             signing_context: signing_context,
             expect_parent: expected_parent,
             metadata: %{kind: :regular, sla: @ephemeral_sla}
           ),
         {:ok, %Commit{} = commit} <- latest_commit(store, log_uuid),
         :ok <- verify_append(log_uuid, before, record, store) do
      {:ok,
       %{
         commit_id: commit.id,
         deployment_id: record["deployment_id"],
         log_ref: pinned_ref(log_uuid, "deployment-log.json", commit.id),
         sla: @ephemeral_sla
       }}
    else
      :error -> {:error, :signing_context_required}
      {:error, _reason} = error -> error
    end
  end

  def append(_log_uuid, _record, _opts), do: {:error, :invalid_deployment_record}

  @doc "Read the complete append-only deployment log."
  @spec read(String.t(), GenServer.server()) :: {:ok, [map()]}
  def read(log_uuid, store \\ CommitStoreClient) when is_binary(log_uuid) do
    {:ok, log_uuid |> RedLog.load(store) |> RedLog.read()}
  end

  @doc "Write a promoted durable artifact and return a commit-pinned reference."
  @spec promote(atom(), String.t(), map(), String.t(), keyword()) ::
          {:ok, DocRef.t()} | {:error, term()}
  def promote(kind, deployment_id, value, path, opts)
      when kind in @promotion_kinds and is_binary(deployment_id) and deployment_id != "" and
             is_map(value) and is_binary(path) and path != "" and is_list(opts) do
    store = Keyword.get(opts, :store, CommitStoreClient)
    uuid = Keyword.get(opts, :uuid, UUID.uuid4())

    body = %{
      "deployment_id" => deployment_id,
      "kind" => Atom.to_string(kind),
      "value" => stringify_keys(value)
    }

    with {:ok, %SigningContext{} = signing_context} <- Keyword.fetch(opts, :signing_context),
         %Commit{} = commit <- create_promotion(uuid, body, store, signing_context),
         ref = pinned_ref(uuid, path, commit.id),
         {:ok, reread} <- read_promoted(ref, store),
         true <- reread == body or {:error, :promotion_reread_mismatch} do
      {:ok, ref}
    else
      :error -> {:error, :signing_context_required}
      {:error, _reason} = error -> error
      _ -> {:error, :promotion_write_refused}
    end
  end

  def promote(_kind, _deployment_id, _value, _path, _opts),
    do: {:error, :invalid_promotion}

  @doc "Read exactly the promoted artifact commit named by a pinned reference."
  @spec read_promoted(DocRef.t() | String.t(), GenServer.server()) ::
          {:ok, map()} | {:error, term()}
  def read_promoted(ref, store \\ CommitStoreClient)

  def read_promoted(ref, store) when is_binary(ref) do
    with {:ok, parsed} <- DocRef.parse(ref) do
      read_promoted(parsed, store)
    end
  end

  def read_promoted(%DocRef{cid: nil}, _store), do: {:error, :promotion_version_required}

  def read_promoted(%DocRef{uuid: uuid, cid: cid}, store) do
    with {:ok, commit_id} <- decode_cid(cid),
         {:ok, doc, _verdict} <-
           Projection.project_doc_at(uuid, commit_id,
             store: store,
             head_path: :chain,
             require_head_reachable: true
           ),
         body when is_binary(body) <- ContentType.get_content(doc),
         {:ok, promotion} when is_map(promotion) <- Jason.decode(body) do
      {:ok, promotion}
    else
      {:unknown, reason} -> {:error, {:promotion_projection_unknown, reason}}
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_promotion_document}
    end
  end

  @doc """
  Distinguish present, evicted-per-policy, and absence without a tombstone.

  The evicted arm requires `:trusted_tombstone_signers`, a map from trusted
  identity UUIDs to Ed25519 public keys. Signature verification without that
  anchor would prove only that the tombstone agrees with the key it carries.
  """
  @spec range_status(String.t(), binary(), GenServer.server(), keyword()) ::
          {:present, map()}
          | {:evicted_per_policy, map()}
          | {:absent_without_tombstone, map()}
          | {:error, term()}
  def range_status(log_uuid, commit_id, store \\ CommitStoreClient, opts \\ [])

  def range_status(log_uuid, commit_id, store, opts)
      when is_binary(log_uuid) and is_binary(commit_id) and is_list(opts) do
    commit_fetcher =
      Keyword.get(opts, :commit_fetcher, fn id -> CommitStoreClient.get_commit(store, id) end)

    tombstone_fetcher =
      Keyword.get(opts, :tombstone_fetcher, fn id ->
        CommitStoreClient.get_sla_tombstone_for_commit(store, id)
      end)

    trusted_signers = Keyword.get(opts, :trusted_tombstone_signers)

    case commit_fetcher.(commit_id) do
      {:ok, %Commit{doc_uuid: ^log_uuid}} ->
        {:present, %{commit_id: commit_id, log_uuid: log_uuid}}

      {:ok, %Commit{doc_uuid: other}} ->
        {:error, {:commit_doc_mismatch, expected: log_uuid, got: other}}

      :none ->
        absent_status(log_uuid, commit_id, tombstone_fetcher, trusted_signers)

      {:error, _reason} = error ->
        error

      other ->
        {:error, {:invalid_commit_fetch_result, other}}
    end
  end

  def range_status(_log_uuid, _commit_id, _store, _opts), do: {:error, :invalid_commit_range}

  defp absent_status(log_uuid, commit_id, tombstone_fetcher, trusted_signers) do
    case tombstone_fetcher.(commit_id) do
      {:ok, %SlaTombstone{} = tombstone} ->
        with :ok <- SlaTombstone.verify(tombstone, trusted_signers),
             true <- tombstone.subtree_id == log_uuid or {:error, :tombstone_subtree_mismatch} do
          {:evicted_per_policy,
           %{
             commit_id: commit_id,
             log_uuid: log_uuid,
             tombstone_id: tombstone.id
           }}
        else
          {:error, reason} -> {:error, {:invalid_tombstone, reason}}
        end

      :none ->
        {:absent_without_tombstone,
         %{
           commit_id: commit_id,
           log_uuid: log_uuid,
           possible_causes: [:never_written, :lost]
         }}

      {:error, reason} ->
        {:error, {:invalid_tombstone, reason}}

      other ->
        {:error, {:invalid_tombstone_fetch_result, other}}
    end
  end

  defp validate_record(record) do
    record = stringify_keys(record)

    with true <- Enum.sort(Map.keys(record)) == @record_fields,
         :ok <- non_empty(record, "deployment_id"),
         :ok <- validate_timestamp(record["started_at"]),
         :ok <- validate_timestamp(record["ended_at"]),
         :ok <- validate_runtime_profile(record["runtime_profile"]),
         :ok <- validate_budget(record["budget"]),
         :ok <- validate_capability_proofs(record["capability_proofs"]),
         :ok <- validate_ref_fields(record) do
      {:ok, record}
    else
      false -> {:error, {:invalid_deployment_record, @record_fields}}
      {:error, _reason} = error -> error
    end
  end

  defp validate_ref_fields(record) do
    with :ok <- Enum.reduce_while(@single_ref_fields, :ok, &validate_single_ref(&2, record[&1])),
         :ok <- Enum.reduce_while(@ref_list_fields, :ok, &validate_ref_list(&2, record[&1])) do
      :ok
    end
  end

  defp validate_single_ref(:ok, ref) do
    case pinned_ref?(ref) do
      true -> {:cont, :ok}
      false -> {:halt, {:error, :pinned_deployment_reference_required}}
    end
  end

  defp validate_ref_list(:ok, refs) when is_list(refs) do
    if Enum.all?(refs, &pinned_ref?/1),
      do: {:cont, :ok},
      else: {:halt, {:error, :pinned_deployment_reference_required}}
  end

  defp validate_ref_list(:ok, _refs),
    do: {:halt, {:error, :pinned_deployment_reference_required}}

  defp pinned_ref?(ref) when is_binary(ref) do
    with {:ok, %DocRef{cid: cid}} when is_binary(cid) <- DocRef.parse(ref),
         {:ok, decoded} when byte_size(decoded) == 32 <- Base.decode16(cid, case: :mixed) do
      true
    else
      _ -> false
    end
  end

  defp pinned_ref?(_ref), do: false

  defp validate_runtime_profile(profile) when is_map(profile) do
    profile = stringify_keys(profile)

    if Enum.sort(Map.keys(profile)) == ~w(model sandbox_profile tools_hash) and
         Enum.all?(Map.values(profile), &(is_binary(&1) and &1 != "")) do
      :ok
    else
      {:error, :invalid_runtime_profile}
    end
  end

  defp validate_runtime_profile(_profile), do: {:error, :invalid_runtime_profile}

  defp validate_budget(budget) when is_map(budget) do
    budget = stringify_keys(budget)

    if Enum.sort(Map.keys(budget)) == ~w(money tokens wall_seconds) and
         Enum.all?(Map.values(budget), &(is_number(&1) and &1 >= 0)) do
      :ok
    else
      {:error, :invalid_deployment_budget}
    end
  end

  defp validate_budget(_budget), do: {:error, :invalid_deployment_budget}

  defp validate_capability_proofs(proofs) when is_list(proofs) do
    if Enum.all?(proofs, &(is_binary(&1) and &1 != "")),
      do: :ok,
      else: {:error, :invalid_capability_proofs}
  end

  defp validate_capability_proofs(_proofs), do: {:error, :invalid_capability_proofs}

  defp validate_timestamp(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, _datetime, 0} -> :ok
      _ -> {:error, :invalid_deployment_timestamp}
    end
  end

  defp validate_timestamp(_timestamp), do: {:error, :invalid_deployment_timestamp}

  defp non_empty(record, field) do
    case record[field] do
      value when is_binary(value) and value != "" -> :ok
      _ -> {:error, {:invalid_deployment_field, field}}
    end
  end

  defp unique_deployment(records, record) do
    if Enum.any?(records, &(&1["deployment_id"] == record["deployment_id"])),
      do: {:error, :deployment_already_recorded},
      else: :ok
  end

  defp verify_append(log_uuid, before, record, store) do
    after_records = log_uuid |> RedLog.load(store) |> RedLog.read()

    if after_records == before ++ [record],
      do: :ok,
      else: {:error, :deployment_record_reread_mismatch}
  end

  defp create_promotion(uuid, body, store, signing_context) do
    doc = Doc.new(client_id: WriterHand.for_doc_actor(uuid, signing_context.identity_uuid))
    doc = ContentType.create(doc, :text, "promoted-artifact")
    doc = ContentType.insert_text(doc, 0, Jason.encode!(body))

    CommitStoreClient.create_commit(
      store,
      uuid,
      Encoding.encode_update(doc),
      nil,
      %{kind: :regular, sla: @durable_sla},
      signing_context: signing_context
    )
  end

  defp latest_id(store, log_uuid) do
    case CommitStoreClient.latest_commit(store, log_uuid) do
      {:ok, commit} -> commit.id
      :none -> nil
    end
  end

  defp latest_commit(store, log_uuid) do
    case CommitStoreClient.latest_commit(store, log_uuid) do
      {:ok, %Commit{} = commit} -> {:ok, commit}
      :none -> {:error, :deployment_record_not_found_after_write}
    end
  end

  defp pinned_ref(uuid, path, commit_id) do
    DocRef.new(uuid, path: path, cid: Base.encode16(commit_id, case: :lower))
  end

  defp decode_cid(cid) when is_binary(cid) do
    case Base.decode16(cid, case: :mixed) do
      {:ok, decoded} when byte_size(decoded) == 32 -> {:ok, decoded}
      _ -> {:error, :invalid_promotion_version}
    end
  end

  defp stringify_keys(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)

  defp stringify(map) when is_map(map), do: stringify_keys(map)
  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(value), do: value
end
