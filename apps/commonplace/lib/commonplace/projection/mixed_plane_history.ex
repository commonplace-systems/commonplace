defmodule Commonplace.Projection.MixedPlaneHistory do
  @moduledoc """
  Resumable, detect-only sweep of every persisted commit of every document.

  This deliberately does not walk only current heads: CX-mchn's known shape
  is clean at head and mixed at a historical pin. `run/1` first executes a
  five-commit scratch-store positive control reproducing the known
  `235d73b5-...` / `5042f340` incident shape. Store enumeration does not begin
  unless that control sees a clean head and exactly one historical trip.

  A live-mode sweep is valid only when every expected known-positive document
  appears in its actual hits. The default set contains the known affected
  document. If any expected hit is absent, the completed sweep is declared
  void and no summary is emitted.

  Production calls run on the serve node itself. Document UUIDs come from
  `CommitStoreClient.all_doc_uuids/0` (including unreachable documents), and
  commit IDs come from `CommitStore.all_commit_ids_for_doc/2` (including
  unreachable commits). Nothing in this module writes to the commit store.

  The checkpoint is an operator-selected directory outside the store. Its
  manifest and per-document JSON records are replaced atomically. Keeping one
  file per document avoids quadratically rewriting an ever-growing census
  after each of thousands of documents. A resumed run reuses a document only
  when its complete current commit-ID set exactly matches the checkpoint; a
  changed set is scanned again.
  """

  alias Commonplace.Projection
  alias Commonplace.Projection.MixedPlaneHistoryFixture
  alias Commonplace.Store.{CommitStore, CommitStoreClient}

  @checkpoint_version 1
  @default_known_positives ["235d73b5-a44a-44de-91ad-a753c61f7407"]

  @type summary :: %{
          docs_total: non_neg_integer(),
          docs_scanned: non_neg_integer(),
          commits_total: non_neg_integer(),
          commits_scanned: non_neg_integer(),
          docs_skipped: non_neg_integer(),
          affected_docs: non_neg_integer(),
          hits: non_neg_integer(),
          elapsed_ms: non_neg_integer()
        }

  @doc """
  Run the positive-control gate and, only if it passes, sweep the store.

  Required option: `:checkpoint_path`. Production normally leaves `:store`
  unset, which selects `CommitStore` and the required
  `CommitStoreClient.all_doc_uuids/0` census. `:progress_every` defaults to 25
  documents and `:max_concurrency` defaults to 4. `:mode` defaults to `:live`;
  live mode requires every UUID in `:expected_known_positives` to have a hit,
  with the known affected document as the default set.
  """
  @spec run(keyword()) :: {:ok, summary()} | {:error, term()}
  def run(opts) do
    checkpoint_path = Keyword.fetch!(opts, :checkpoint_path)
    emit = Keyword.get(opts, :emit, &IO.puts/1)
    positive_control = Keyword.get(opts, :positive_control, &positive_control/0)

    emit.("GATE START fixture_reproducing=#{fixture_source_shape()}")

    case safe_positive_control(positive_control) do
      {:ok, control} ->
        emit.(
          "GATE PASS fixture_reproducing=#{fixture_source_shape()} " <>
            "fixture_commit=#{control.armed_commit_id_hex} head=CLEAN history=TRIPS"
        )

        sweep(Keyword.merge(opts, checkpoint_path: checkpoint_path, emit: emit))

      {:error, reason} ->
        emit.("GATE FAIL fixture_reproducing=#{fixture_source_shape()} reason=#{inspect(reason)}")
        emit.("SWEEP ABORTED docs_enumerated=0 commits_scanned=0")
        {:error, {:positive_control_failed, reason}}
    end
  end

  @doc false
  def positive_control do
    contrast = MixedPlaneHistoryFixture.contrast()

    with {:ok, _bytes, _verdict} <- contrast.head_result,
         [{armed_commit_id, {:unknown, {:mixed_plane, _details}}}] <- contrast.hits,
         true <- armed_commit_id == contrast.fixture.armed_commit_id,
         5 <- length(contrast.historical_results) do
      {:ok, %{armed_commit_id_hex: hex(armed_commit_id), commits: 5}}
    else
      other -> {:error, {:control_contrast_mismatch, other}}
    end
  end

  defp sweep(opts) do
    started_ms = monotonic_ms()
    emit = Keyword.fetch!(opts, :emit)
    store = Keyword.get(opts, :store, CommitStore)
    checkpoint_path = Keyword.fetch!(opts, :checkpoint_path)
    scan_id = Keyword.get(opts, :scan_id, "#{inspect(node())}:#{inspect(store)}")
    progress_every = positive_integer!(opts, :progress_every, 25)
    max_concurrency = positive_integer!(opts, :max_concurrency, 4)

    with {:ok, checkpoint} <- load_checkpoint(checkpoint_path, scan_id),
         {:ok, doc_uuids} <- fetch_doc_uuids(store, opts) do
      docs = doc_uuids |> MapSet.to_list() |> Enum.sort()
      total = length(docs)
      checkpoint = put_in(checkpoint, ["docs"], Map.take(checkpoint["docs"], docs))

      emit.(
        "SWEEP START docs_total=#{total} checkpoint=#{checkpoint_path} " <>
          "resumable=true max_concurrency=#{max_concurrency}"
      )

      initial = %{
        checkpoint: checkpoint,
        processed: 0,
        reused: 0,
        commits_this_run: 0
      }

      final =
        docs
        |> Task.async_stream(
          fn doc_uuid -> scan_or_reuse_doc(doc_uuid, store, checkpoint, opts) end,
          max_concurrency: max_concurrency,
          ordered: false,
          timeout: :infinity
        )
        |> Enum.reduce(initial, fn {:ok, result}, acc ->
          acc = accept_result(result, acc, checkpoint_path, emit)

          if rem(acc.processed, progress_every) == 0 or acc.processed == total do
            emit_progress(emit, acc, total, started_ms)
          end

          acc
        end)

      summary = summarize(final.checkpoint, total, final, started_ms)

      case missing_known_positives(final.checkpoint, opts) do
        [] ->
          emit_summary(emit, summary)
          {:ok, summary}

        missing ->
          emit_void(emit, missing, summary)
          {:error, {:known_positives_missing, missing}}
      end
    else
      {:error, reason} ->
        emit.("SWEEP ABORTED reason=#{inspect(reason)} docs_scanned=0 commits_scanned=0")
        {:error, reason}
    end
  end

  defp scan_or_reuse_doc(doc_uuid, store, checkpoint, opts) do
    case fetch_commit_ids(store, doc_uuid, opts) do
      {:ok, commit_ids} ->
        commit_hexes = Enum.map(commit_ids, &hex/1)

        case get_in(checkpoint, ["docs", doc_uuid]) do
          %{"commit_ids" => ^commit_hexes, "skip_reasons" => []} = record ->
            {:reuse, doc_uuid, record}

          _ ->
            {:scanned, doc_uuid, scan_commits(doc_uuid, commit_ids, store, opts)}
        end

      {:error, reason} ->
        {:scanned, doc_uuid, failed_enumeration_record(reason)}
    end
  end

  defp scan_commits(doc_uuid, commit_ids, store, opts) do
    project = Keyword.get(opts, :project, &Projection.project_at/3)

    {hits, failures, attempted} =
      Enum.reduce(commit_ids, {[], [], 0}, fn commit_id, {hits, failures, attempted} ->
        case safe_project(project, doc_uuid, commit_id, store) do
          {:unknown, {:mixed_plane, details}} ->
            hit = %{"commit_id" => hex(commit_id), "details" => json_safe(details)}
            {[hit | hits], failures, attempted + 1}

          {:ok, _bytes, _verdict} ->
            {hits, failures, attempted + 1}

          other ->
            failure = %{"commit_id" => hex(commit_id), "reason" => inspect(other)}
            {hits, [failure | failures], attempted + 1}
        end
      end)

    %{
      "commit_ids" => Enum.map(commit_ids, &hex/1),
      "commits_scanned" => attempted,
      "hits" => Enum.reverse(hits),
      "skip_reasons" => Enum.reverse(failures)
    }
  end

  defp failed_enumeration_record(reason) do
    %{
      "commit_ids" => nil,
      "commits_scanned" => 0,
      "hits" => [],
      "skip_reasons" => [%{"reason" => "commit_enumeration_failed: #{inspect(reason)}"}]
    }
  end

  defp accept_result({kind, doc_uuid, record}, acc, checkpoint_path, emit) do
    Enum.each(record["hits"], fn hit ->
      emit.(
        "HIT doc=#{doc_uuid} commit=#{hit["commit_id"]} details=#{Jason.encode!(hit["details"])}"
      )
    end)

    Enum.each(record["skip_reasons"], fn reason ->
      commit = if reason["commit_id"], do: " commit=#{reason["commit_id"]}", else: ""
      emit.("SKIP doc=#{doc_uuid}#{commit} reason=#{reason["reason"]}")
    end)

    checkpoint = put_in(acc.checkpoint, ["docs", doc_uuid], record)
    :ok = write_checkpoint_record(checkpoint_path, doc_uuid, record)

    %{
      acc
      | checkpoint: checkpoint,
        processed: acc.processed + 1,
        reused: acc.reused + if(kind == :reuse, do: 1, else: 0),
        commits_this_run:
          acc.commits_this_run + if(kind == :scanned, do: record["commits_scanned"], else: 0)
    }
  end

  defp emit_progress(emit, acc, total, started_ms) do
    records = Map.values(acc.checkpoint["docs"])

    emit.(
      "PROGRESS docs=#{acc.processed}/#{total} commits_scanned=#{sum(records, "commits_scanned")} " <>
        "commits_this_run=#{acc.commits_this_run} resumed_docs=#{acc.reused} " <>
        "elapsed_ms=#{monotonic_ms() - started_ms}"
    )
  end

  defp summarize(checkpoint, total, run, started_ms) do
    records = Map.values(checkpoint["docs"])
    skipped = Enum.filter(records, &(&1["skip_reasons"] != []))
    hits = Enum.flat_map(records, & &1["hits"])

    %{
      docs_total: total,
      docs_scanned: total - length(skipped),
      commits_total: records |> Enum.flat_map(&(&1["commit_ids"] || [])) |> length(),
      commits_scanned: sum(records, "commits_scanned"),
      docs_skipped: length(skipped),
      affected_docs: Enum.count(records, &(&1["hits"] != [])),
      hits: length(hits),
      resumed_docs: run.reused,
      commits_this_run: run.commits_this_run,
      elapsed_ms: monotonic_ms() - started_ms
    }
  end

  defp emit_summary(emit, summary) do
    emit.(
      "SUMMARY docs_total=#{summary.docs_total} docs_scanned=#{summary.docs_scanned} " <>
        "commits_total=#{summary.commits_total} commits_scanned=#{summary.commits_scanned} " <>
        "docs_skipped=#{summary.docs_skipped} affected_docs=#{summary.affected_docs} " <>
        "hits=#{summary.hits} resumed_docs=#{summary.resumed_docs} " <>
        "commits_this_run=#{summary.commits_this_run} elapsed_ms=#{summary.elapsed_ms}"
    )
  end

  defp emit_void(emit, missing, summary) do
    emit.(
      "SWEEP VOID validity_condition=expected_known_positives_absent " <>
        "absent_known_positives=#{Enum.join(missing, ",")} " <>
        "docs_total=#{summary.docs_total} hits=#{summary.hits}"
    )

    emit.("SUMMARY SUPPRESSED run_valid=false exit_nonzero=true")
  end

  defp missing_known_positives(checkpoint, opts) do
    expected =
      case Keyword.get(opts, :mode, :live) do
        :fixture -> []
        :live -> Keyword.get(opts, :expected_known_positives, @default_known_positives)
      end
      |> MapSet.new()

    actual =
      checkpoint["docs"]
      |> Enum.filter(fn {_doc_uuid, record} -> record["hits"] != [] end)
      |> Enum.map(fn {doc_uuid, _record} -> doc_uuid end)
      |> MapSet.new()

    expected
    |> MapSet.difference(actual)
    |> MapSet.to_list()
    |> Enum.sort()
  end

  defp fetch_doc_uuids(store, opts) do
    result =
      safely(fn ->
        case Keyword.fetch(opts, :doc_uuids) do
          {:ok, fun} -> fun.()
          :error when store == CommitStore -> CommitStoreClient.all_doc_uuids()
          :error -> CommitStoreClient.all_doc_uuids(store)
        end
      end)

    case result do
      {:ok, %MapSet{} = uuids} -> {:ok, uuids}
      {:ok, other} -> {:error, {:all_doc_uuids_not_mapset, other}}
      {:error, _reason} = error -> error
    end
  end

  defp fetch_commit_ids(store, doc_uuid, opts) do
    result =
      safely(fn ->
        case Keyword.fetch(opts, :commit_ids) do
          {:ok, fun} -> fun.(doc_uuid)
          :error -> CommitStore.all_commit_ids_for_doc(store, doc_uuid)
        end
      end)

    case result do
      {:ok, %MapSet{} = ids} -> {:ok, ids |> MapSet.to_list() |> Enum.sort()}
      {:ok, other} -> {:error, {:all_commit_ids_not_mapset, other}}
      {:error, _reason} = error -> error
    end
  end

  defp safe_project(project, doc_uuid, commit_id, store) do
    case safely(fn -> project.(doc_uuid, commit_id, store: store) end) do
      {:ok, result} -> result
      {:error, reason} -> {:scanner_exception, reason}
    end
  end

  defp safe_positive_control(fun) do
    case safely(fun) do
      {:ok, {:ok, control}} -> {:ok, control}
      {:ok, {:error, reason}} -> {:error, reason}
      {:ok, other} -> {:error, {:invalid_control_result, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp safely(fun) do
    {:ok, fun.()}
  rescue
    exception -> {:error, {:exception, Exception.format(:error, exception, __STACKTRACE__)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp load_checkpoint(path, scan_id) do
    manifest_path = Path.join(path, "manifest.json")

    case File.read(manifest_path) do
      {:ok, bytes} ->
        with {:ok, decoded} <- Jason.decode(bytes),
             %{"version" => @checkpoint_version, "scan_id" => ^scan_id} <- decoded,
             :ok <- File.mkdir_p(Path.join(path, "docs")),
             {:ok, docs} <- load_checkpoint_records(path) do
          {:ok, %{"version" => @checkpoint_version, "scan_id" => scan_id, "docs" => docs}}
        else
          %{"scan_id" => other} ->
            {:error, {:checkpoint_scan_id_mismatch, expected: scan_id, got: other}}

          other ->
            {:error, {:invalid_checkpoint, other}}
        end

      {:error, :enoent} ->
        with :ok <- File.mkdir_p(Path.join(path, "docs")),
             :ok <-
               write_json_atomic(manifest_path, %{
                 "version" => @checkpoint_version,
                 "scan_id" => scan_id
               }) do
          {:ok, %{"version" => @checkpoint_version, "scan_id" => scan_id, "docs" => %{}}}
        else
          {:error, reason} -> {:error, {:checkpoint_create_failed, path, reason}}
        end

      {:error, reason} ->
        {:error, {:checkpoint_read_failed, manifest_path, reason}}
    end
  end

  defp load_checkpoint_records(path) do
    path
    |> Path.join("docs/*.json")
    |> Path.wildcard()
    |> Enum.reduce_while({:ok, %{}}, fn record_path, {:ok, docs} ->
      with {:ok, bytes} <- File.read(record_path),
           {:ok, %{"doc_uuid" => doc_uuid, "record" => record}} <- Jason.decode(bytes),
           true <- is_binary(doc_uuid) and is_map(record) do
        {:cont, {:ok, Map.put(docs, doc_uuid, record)}}
      else
        other -> {:halt, {:error, {:invalid_checkpoint_record, record_path, other}}}
      end
    end)
  end

  defp write_checkpoint_record(path, doc_uuid, record) do
    digest = :crypto.hash(:sha256, doc_uuid) |> Base.encode16(case: :lower)
    record_path = Path.join([path, "docs", digest <> ".json"])
    write_json_atomic(record_path, %{"doc_uuid" => doc_uuid, "record" => record})
  end

  defp write_json_atomic(path, value) do
    temporary = path <> ".tmp.#{System.unique_integer([:positive, :monotonic])}"

    bytes = Jason.encode!(value, pretty: true)

    with :ok <- File.write(temporary, bytes <> "\n", [:binary, :sync]),
         :ok <- File.rename(temporary, path) do
      :ok
    else
      {:error, reason} ->
        File.rm(temporary)
        {:error, reason}
    end
  end

  defp positive_integer!(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 ->
        value

      value ->
        raise ArgumentError, "#{inspect(key)} must be a positive integer, got: #{inspect(value)}"
    end
  end

  defp json_safe(value) when is_map(value),
    do: Map.new(value, fn {key, nested} -> {to_string(key), json_safe(nested)} end)

  defp json_safe(value) when is_list(value), do: Enum.map(value, &json_safe/1)
  defp json_safe(value) when is_atom(value), do: Atom.to_string(value)
  defp json_safe(value), do: value

  defp sum(records, key), do: Enum.sum(Enum.map(records, &(&1[key] || 0)))
  defp fixture_source_shape, do: "235d73b5-a44a-44de-91ad-a753c61f7407@5042f340"
  defp hex(bytes), do: Base.encode16(bytes, case: :lower)
  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
