defmodule Commonplace.Runner.ProtoChitHarvest do
  @moduledoc """
  Verifies and ingests a provisioned pod's proto-chit WAL before pod reaping.

  Verification uses the public key in a runner-written deployment binding at
  the pod-home root, outside the pod's three writable binds. A pod below the
  private `/tmp` mount can create a shadow pathname there, but cannot change the
  host inode harvest reads. The writable data directory contains only an
  equality-checked copy. A WAL record never supplies its verifier key. Refused
  records are written, with stable line names and reasons, to a runner-owned
  quarantine outside the reapable pod home.
  """

  alias Commonplace.ProtoChit
  alias Commonplace.ProtoChit.IntentRecord
  alias Commonplace.Runner.PodIdentity
  alias Commonplace.Store.CommitStoreClient

  @deployment_file "proto-chit-deployment.json"
  @binding_file "proto-chit-deployment-binding.json"
  @receipt_file "harvest-receipt.json"

  @spec harvest(Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def harvest(pod_home, opts) when is_binary(pod_home) and is_list(opts) do
    data_dir = Path.join([pod_home, "workspace", ".commonplace"])

    case {read_deployment(data_dir), read_binding(pod_home)} do
      {{:ok, deployment}, {:ok, deployment}} ->
        harvest_deployment(data_dir, deployment, opts)

      {{:ok, %{"binding-version" => "pod-home-read-only-v1"}}, {:error, :enoent}} ->
        {:error, :deployment_binding_absent}

      {{:ok, deployment}, {:error, :enoent}} ->
        harvest_deployment(data_dir, deployment, opts)

      {{:ok, _deployment}, {:ok, _binding}} ->
        {:error, :deployment_binding_mismatch}

      {{:error, :enoent}, {:error, :enoent}} ->
        {:ok, %{ingested: [], quarantined: [], legacy_without_record: true}}

      {{:error, reason}, {:ok, _binding}} ->
        {:error, {:deployment_record_unreadable, reason}}

      {{:error, reason}, _binding} ->
        {:error, {:deployment_record_unreadable, reason}}

      {_deployment, {:error, reason}} ->
        {:error, {:deployment_binding_unreadable, reason}}
    end
  end

  @doc "Return the durable, runner-owned quarantine pathname for a deployment log."
  @spec quarantine_path(Path.t(), String.t()) :: Path.t()
  def quarantine_path(quarantine_root, event_log_uuid)
      when is_binary(quarantine_root) and is_binary(event_log_uuid),
      do: Path.join(quarantine_root, event_log_uuid <> ".quarantine.ndjson")

  defp harvest_deployment(data_dir, deployment, opts) do
    with {:ok, event_log_uuid} <- required_binary(deployment, "event-log-uuid"),
         {:ok, wal_path} <- required_binary(deployment, "wal-path"),
         {:ok, signer_id} <- required_binary(deployment, "signer-id"),
         {:ok, public_key} <- bound_public_key(deployment),
         {:ok, signing_context} <- PodIdentity.signing_context(data_dir),
         :ok <- signer_matches(signing_context, signer_id, public_key),
         {:ok, records} <- read_records(wal_path) do
      receipt_path = Path.join(data_dir, @receipt_file)
      receipt = read_receipt(receipt_path)

      reduce_records(
        records,
        receipt,
        receipt_path,
        event_log_uuid,
        public_key,
        signing_context,
        opts
      )
    end
  end

  defp reduce_records(
         records,
         receipt,
         receipt_path,
         event_log_uuid,
         public_key,
         signing_context,
         opts
       ) do
    initial = {:ok, %{receipt: receipt, ingested: [], quarantined: []}}

    records
    |> Enum.reduce_while(initial, fn record, {:ok, summary} ->
      case Map.get(summary.receipt, record.name) do
        %{"outcome" => "ingested", "event-ref" => event_ref} ->
          case advance_predecessor(record.value, event_log_uuid, event_ref, opts) do
            :ok ->
              {:cont, {:ok, summary}}

            {:error, reason} ->
              {:halt, {:error, {:predecessor_advance_failed, record.name, reason}}}
          end

        %{"outcome" => "quarantined"} ->
          {:cont, {:ok, summary}}

        nil ->
          case process_record(record, event_log_uuid, public_key, signing_context, opts) do
            {:ingested, event_ref} ->
              outcome = %{"outcome" => "ingested", "event-ref" => event_ref}

              with :ok <-
                     persist_receipt(receipt_path, Map.put(summary.receipt, record.name, outcome)),
                   :ok <- advance_predecessor(record.value, event_log_uuid, event_ref, opts) do
                {:cont,
                 {:ok,
                  %{
                    summary
                    | receipt: Map.put(summary.receipt, record.name, outcome),
                      ingested: summary.ingested ++ [%{name: record.name, event_ref: event_ref}]
                  }}}
              else
                {:error, reason} ->
                  {:halt, {:error, {:post_ingest_recording_failed, record.name, reason}}}
              end

            {:quarantined, reason} ->
              case quarantine(record, event_log_uuid, reason, opts) do
                {:ok, path} ->
                  outcome = %{
                    "outcome" => "quarantined",
                    "reason" => inspect(reason),
                    "path" => path
                  }

                  case persist_receipt(
                         receipt_path,
                         Map.put(summary.receipt, record.name, outcome)
                       ) do
                    :ok ->
                      {:cont,
                       {:ok,
                        %{
                          summary
                          | receipt: Map.put(summary.receipt, record.name, outcome),
                            quarantined:
                              summary.quarantined ++
                                [%{name: record.name, reason: reason, path: path}]
                        }}}

                    {:error, receipt_reason} ->
                      {:halt, {:error, {:harvest_receipt_failed, record.name, receipt_reason}}}
                  end

                {:error, quarantine_reason} ->
                  {:halt, {:error, {:quarantine_write_failed, record.name, quarantine_reason}}}
              end

            {:error, reason} ->
              {:halt, {:error, {:ingest_failed, record.name, reason}}}
          end

        _invalid_receipt ->
          {:halt, {:error, {:invalid_harvest_receipt, record.name}}}
      end
    end)
    |> case do
      {:ok, summary} -> {:ok, Map.delete(summary, :receipt)}
      {:error, _reason} = error -> error
    end
  end

  defp process_record(%{decode_error: reason}, _uuid, _public_key, _context, _opts),
    do: {:quarantined, {:invalid_json, reason}}

  defp process_record(record, event_log_uuid, public_key, signing_context, opts) do
    case IntentRecord.verify(record.value, public_key) do
      :ok ->
        if get_in(record.value, ["authentication", "principal"]) ==
             signing_context.identity_uuid do
          ingest(record, event_log_uuid, signing_context, opts)
        else
          {:quarantined, :deployment_principal_mismatch}
        end

      {:error, reason} ->
        {:quarantined, reason}
    end
  end

  defp ingest(record, event_log_uuid, signing_context, opts) do
    event =
      record.value
      |> Map.fetch!("event")
      |> normalize_event(record.value)
      |> Map.put("intent-record-name", record.name)
      |> Map.put("intent-record", record.value)
      |> Map.put("intent-record-sha256", sha256(record.raw))

    store = Keyword.get(opts, :store, CommitStoreClient)

    case ProtoChit.ingest_verified(event_log_uuid, event, signing_context, store: store) do
      {:ok, %{event_ref: event_ref}} -> {:ingested, event_ref}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_event(event, record) do
    event =
      case event["predecessor-ref"] do
        predecessor when is_map(predecessor) ->
          Map.put(event, "predecessor-ref", Map.put_new(predecessor, "unresolved", []))

        _other ->
          event
      end

    case record["post-exec"] do
      %{"exit-status" => 0, "resulting-git-sha" => sha, "message" => message}
      when is_binary(sha) ->
        event |> Map.put("git-sha", sha) |> Map.put("message", message)

      _other ->
        event
    end
  end

  defp quarantine(record, event_log_uuid, reason, opts) do
    quarantine_root = Keyword.fetch!(opts, :quarantine_root)
    path = quarantine_path(quarantine_root, event_log_uuid)

    entry = %{
      "record-name" => record.name,
      "reason" => inspect(reason),
      "raw-record" => record.raw
    }

    with :ok <- File.mkdir_p(quarantine_root),
         :ok <- File.write(path, Jason.encode!(entry) <> "\n", [:append]) do
      {:ok, path}
    end
  end

  defp advance_predecessor(record, event_log_uuid, event_ref, opts) do
    case get_in(record, ["event", "predecessor-ref", "branch"]) do
      branch when is_binary(branch) ->
        root = Keyword.fetch!(opts, :quarantine_root)
        path = Path.join(root, event_log_uuid <> ".predecessors.json")
        state = read_json_map(path)
        atomic_json_write(path, Map.put(state, branch, event_ref))

      _other ->
        :ok
    end
  end

  defp read_records(path) do
    case File.read(path) do
      {:ok, contents} ->
        records =
          contents
          |> String.split("\n", trim: true)
          |> Enum.with_index(1)
          |> Enum.map(fn {raw, line} -> decode_record(raw, line) end)

        {:ok, records}

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, {:wal_unreadable, reason}}
    end
  end

  defp decode_record(raw, line) do
    name = "events.wal.ndjson:#{line}"

    case Jason.decode(raw) do
      {:ok, value} when is_map(value) -> %{name: name, raw: raw, value: value}
      {:ok, _value} -> %{name: name, raw: raw, decode_error: :record_is_not_an_object}
      {:error, error} -> %{name: name, raw: raw, decode_error: Exception.message(error)}
    end
  end

  defp bound_public_key(deployment) do
    with {:ok, encoded} <- required_binary(deployment, "signer-public-key"),
         {:ok, public_key} <- Base.decode64(encoded),
         true <- byte_size(public_key) == 32 do
      {:ok, public_key}
    else
      _other -> {:error, :invalid_deployment_public_key}
    end
  end

  defp signer_matches(signing_context, signer_id, public_key) do
    if signing_context.identity_uuid == signer_id and signing_context.public_key == public_key,
      do: :ok,
      else: {:error, :deployment_signer_artifact_mismatch}
  end

  defp read_deployment(data_dir),
    do: data_dir |> Path.join(@deployment_file) |> read_json()

  defp read_binding(pod_home),
    do: pod_home |> Path.join(@binding_file) |> read_json()

  defp read_json(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, document} when is_map(document) <- Jason.decode(contents) do
      {:ok, document}
    else
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_json_object}
    end
  end

  defp read_receipt(path), do: read_json_map(path)

  defp read_json_map(path) do
    case read_json(path) do
      {:ok, map} -> map
      {:error, :enoent} -> %{}
      _other -> %{}
    end
  end

  defp persist_receipt(path, receipt), do: atomic_json_write(path, receipt)

  defp atomic_json_write(path, value) do
    :ok = File.mkdir_p(Path.dirname(path))
    tmp = path <> ".tmp.#{System.unique_integer([:positive])}"

    with :ok <- File.write(tmp, Jason.encode!(value)),
         :ok <- File.rename(tmp, path) do
      :ok
    end
  end

  defp required_binary(map, key) do
    case map[key] do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, {:invalid_deployment_field, key}}
    end
  end

  defp sha256(value),
    do: value |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
end
