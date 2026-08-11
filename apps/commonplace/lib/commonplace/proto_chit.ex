defmodule Commonplace.ProtoChit do
  @moduledoc """
  Emits proto-chit punctuation events through the ordinary signed commit path.

  The event is advisory to git, but its substrate write is not advisory about
  identity: callers must supply a `SigningContext`. A failed sync, pin cut, or
  gated event write is returned to the caller so the PATH shim can WAL the
  intent and still execute real git.
  """

  alias Commonplace.Crypto.SigningContext
  alias Commonplace.Dataflow.RedLog
  alias Commonplace.Reflog.{Restore, Snapshot}
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Sync.Watcher

  @pin_format "commonplace-reflog-path-pin/v1"
  @state_file "predecessors.json"
  @sync_excludes [".git", ".commonplace", "_build", "deps"]
  @sync_scope_refusal "sync scope is undeclared; set PROTO_CHIT_SYNC_EXCLUDES " <>
                        "(set-but-empty declares defaults-only), repeat --sync-exclude NAME, " <>
                        "or pass --declare-empty-sync-excludes"

  @type event :: %{required(String.t()) => term()}

  @doc "Cut a sync-flushed pin, append one signed event, and advance its branch ref."
  @spec emit(Path.t(), [String.t()], keyword()) ::
          {:ok, %{event: event(), event_ref: String.t()}} | {:error, term()}
  def emit(repo, git_args, opts) when is_binary(repo) and is_list(git_args) do
    with :ok <- validate_sync_scope(opts),
         :ok <- validate_repo(repo),
         {:ok, signing_context} <- fetch_signing_context(opts),
         {:ok, root_uuid} <- fetch_binary(opts, :root_uuid),
         {:ok, event_log_uuid} <- fetch_binary(opts, :event_log_uuid),
         {:ok, state_dir} <- fetch_binary(opts, :state_dir),
         {:ok, verb} <- classify(git_args),
         {:ok, observation} <- observe_git(repo, git_args, opts),
         {:ok, exclusions} <- sync_flush(repo, root_uuid, signing_context, opts),
         {:ok, proto_pin} <- cut_pin(root_uuid, signing_context, exclusions, opts),
         {:ok, predecessor_ref} <- predecessor_ref(state_dir, observation, git_args),
         event <-
           build_event(verb, signing_context, git_args, observation, proto_pin, predecessor_ref),
         {:ok, event_ref} <- persist_event(event_log_uuid, event, signing_context, opts),
         :ok <- advance_predecessor(state_dir, observation, git_args, event_ref),
         :ok <- maybe_trace(opts[:trace_file], event) do
      {:ok, %{event: event, event_ref: event_ref}}
    end
  rescue
    error -> {:error, {:emission_failed, Exception.message(error)}}
  catch
    :exit, reason -> {:error, {:gated_write_unreachable, reason}}
  end

  @doc "Append a cheap signed post-exec witness without syncing, pinning, or advancing refs."
  @spec annotate(Path.t(), String.t(), non_neg_integer(), [String.t()], keyword()) ::
          {:ok, %{event: event(), event_ref: String.t()}} | {:error, term()}
  def annotate(repo, main_event_ref, exit_status, git_args, opts)
      when is_binary(repo) and is_binary(main_event_ref) and is_integer(exit_status) and
             exit_status >= 0 and is_list(git_args) do
    with :ok <- validate_repo(repo),
         {:ok, signing_context} <- fetch_signing_context(opts),
         {:ok, event_log_uuid} <- fetch_binary(opts, :event_log_uuid),
         {:ok, resulting_git_sha} <- resulting_git_sha(repo, opts),
         {:ok, message} <- final_message(repo, git_args, exit_status, opts),
         event <- %{
           "kind" => "post-exec",
           "author-principal" => signing_context.identity_uuid,
           "main-event-ref" => main_event_ref,
           "resulting-git-sha" => resulting_git_sha,
           "exit-status" => exit_status,
           "message" => message
         },
         {:ok, event_ref} <- persist_event(event_log_uuid, event, signing_context, opts),
         :ok <- maybe_trace(opts[:trace_file], event) do
      {:ok, %{event: event, event_ref: event_ref}}
    end
  rescue
    error -> {:error, {:annotation_failed, Exception.message(error)}}
  catch
    :exit, reason -> {:error, {:gated_write_unreachable, reason}}
  end

  @doc "Map an explicitly tapped git argv to the four schema verbs."
  def classify(["commit" | args]) do
    if Enum.any?(args, &(&1 == "--amend")), do: {:ok, "rewrite"}, else: {:ok, "commit"}
  end

  def classify([command | _]) when command in ["merge", "pull"], do: {:ok, "merge"}

  def classify([command | _])
      when command in ["branch", "checkout", "switch", "tag", "worktree"],
      do: {:ok, "branch"}

  def classify([command | _])
      when command in [
             "rebase",
             "reset",
             "filter-branch",
             "replace",
             "update-ref",
             "notes",
             "bisect",
             "reflog",
             "stash"
           ],
      do: {:ok, "rewrite"}

  def classify([command | _]) when command in ["cherry-pick", "revert"], do: {:ok, "commit"}
  def classify(args), do: {:error, {:untapped_git_argv, args}}

  defp validate_repo(repo) do
    if File.dir?(repo), do: :ok, else: {:error, {:repo_not_found, repo}}
  end

  defp validate_sync_scope(opts) do
    case Keyword.fetch(opts, :sync_excludes) do
      {:ok, excludes} when is_list(excludes) -> :ok
      _ -> {:error, {:sync_scope_undeclared, @sync_scope_refusal}}
    end
  end

  defp fetch_signing_context(opts) do
    case Keyword.get(opts, :signing_context) do
      %SigningContext{} = context -> {:ok, context}
      _ -> {:error, :no_signing_context}
    end
  end

  defp fetch_binary(opts, key) do
    case Keyword.get(opts, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing_option, key}}
    end
  end

  defp observe_git(repo, git_args, opts) do
    real_git = Keyword.get(opts, :real_git, "/usr/bin/git")

    with {:ok, branch} <-
           git_output(real_git, repo, ["symbolic-ref", "--quiet", "--short", "HEAD"], "DETACHED"),
         {:ok, sha} <- git_output(real_git, repo, ["rev-parse", "--verify", "HEAD"], nil) do
      {:ok, %{branch: branch, git_sha: sha, real_git: real_git, argv: git_args}}
    end
  end

  defp git_output(real_git, repo, args, fallback) do
    case System.cmd(real_git, args, cd: repo, stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {_output, _status} -> {:ok, fallback}
    end
  rescue
    error -> {:error, {:real_git_unreachable, Exception.message(error)}}
  end

  defp resulting_git_sha(repo, opts) do
    real_git = Keyword.get(opts, :real_git, "/usr/bin/git")
    git_output(real_git, repo, ["rev-parse", "--verify", "HEAD"], nil)
  end

  defp final_message(repo, [command | _] = git_args, 0, opts)
       when command in ["commit", "cherry-pick", "revert"] do
    real_git = Keyword.get(opts, :real_git, "/usr/bin/git")
    git_output(real_git, repo, ["log", "-1", "--format=%B"], human_message(git_args))
  end

  defp final_message(_repo, git_args, _exit_status, _opts), do: {:ok, human_message(git_args)}

  defp sync_flush(repo, root_uuid, signing_context, opts) do
    store = Keyword.get(opts, :store, CommitStoreClient)
    declared_excludes = Keyword.fetch!(opts, :sync_excludes)

    sync_opts =
      [
        signing_context: signing_context,
        exclude_names: Enum.uniq(@sync_excludes ++ declared_excludes)
      ] ++ Keyword.take(opts, [:artifact_store, :binary_extensions])

    report = Watcher.sync_recursive(root_uuid, repo, store, sync_opts)
    skipped_paths = MapSet.new(report.skipped, & &1.path)

    case Watcher.detect_changes(root_uuid, repo, store, sync_opts)
         |> Enum.reject(&MapSet.member?(skipped_paths, &1.path)) do
      [] -> {:ok, pin_exclusions(report.skipped, repo)}
      remaining -> {:error, {:sync_flush_incomplete, Enum.map(remaining, & &1.path)}}
    end
  end

  defp cut_pin(root_uuid, signing_context, exclusions, opts) do
    store = Keyword.get(opts, :store, CommitStoreClient)
    owner = Keyword.get(opts, :pin_owner, "proto-chit")

    with {:ok, checkpoint_commit_id} <-
           Snapshot.checkpoint(root_uuid, store, owner, signing_context: signing_context),
         {:ok, snapshot_doc_uuid} <- Restore.root_snapshot_uuid(store, root_uuid, owner),
         {:ok, resolved} <- Restore.resolve(store, snapshot_doc_uuid, checkpoint_commit_id) do
      entries =
        Map.new(resolved, fn {path, {:file, doc_uuid, commit_id}} ->
          entry = %{"doc" => doc_uuid, "commit" => commit_id}
          {path, maybe_put_classification(entry, store, doc_uuid, commit_id)}
        end)

      pin = %{
        "format" => @pin_format,
        "checkpoint" => %{
          "doc" => snapshot_doc_uuid,
          "commit" => hex(checkpoint_commit_id)
        },
        "entries" => entries
      }

      pin = if exclusions == [], do: pin, else: Map.put(pin, "exclusions", exclusions)
      {:ok, pin}
    end
  end

  defp maybe_put_classification(entry, store, doc_uuid, commit_id) do
    commit_id = decode_commit_id(commit_id)

    case Commonplace.Projection.project_doc_at(doc_uuid, commit_id,
           store: store,
           required: :any,
           head_path: :direct
         ) do
      {:ok, doc, _verdict} ->
        case Commonplace.Document.ContentType.get_type(doc) do
          :binary ->
            case Commonplace.Document.ContentType.get_content(doc) do
              %{classified_by: classified_by} ->
                Map.put(entry, "classified_by", Atom.to_string(classified_by))

              _ ->
                entry
            end

          _ ->
            entry
        end

      _ ->
        entry
    end
  end

  defp decode_commit_id(commit_id) when is_binary(commit_id) and byte_size(commit_id) == 64 do
    case Base.decode16(commit_id, case: :mixed) do
      {:ok, decoded} -> decoded
      :error -> commit_id
    end
  end

  defp decode_commit_id(commit_id), do: commit_id

  defp pin_exclusions(skipped, repo) do
    skipped
    |> Enum.map(fn %{path: path, reason: reason} ->
      %{"path" => Path.relative_to(path, repo), "reason" => reason}
    end)
    |> Enum.sort_by(& &1["path"])
  end

  defp build_event(verb, signing_context, git_args, observation, proto_pin, predecessor_ref) do
    %{
      "verb" => verb,
      "author-principal" => signing_context.identity_uuid,
      "message" => human_message(git_args),
      "proto-pin" => proto_pin,
      "predecessor-ref" => predecessor_ref,
      "git-sha" => observation.git_sha
    }
  end

  defp persist_event(event_log_uuid, event, signing_context, opts) do
    store = Keyword.get(opts, :store, CommitStoreClient)
    log = event_log_uuid |> RedLog.load(store) |> RedLog.append_raw(event)

    case RedLog.commit(log,
           signing_context: signing_context,
           metadata: %{kind: :regular, proto_chit: true}
         ) do
      {:ok, _log} ->
        case CommitStoreClient.latest_commit(store, event_log_uuid) do
          {:ok, commit} -> {:ok, hex(commit.id)}
          :none -> {:error, :event_write_vanished}
        end

      {:error, reason} ->
        {:error, {:gated_write_refused, reason}}
    end
  end

  defp predecessor_ref(state_dir, observation, git_args) do
    refs = read_refs(state_dir)
    branch = observation.branch

    event_refs =
      [Map.get(refs, branch), merge_source_ref(refs, git_args)]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    {:ok, %{"branch" => branch, "event-refs" => event_refs}}
  end

  defp merge_source_ref(refs, [command | args]) when command in ["merge", "pull"] do
    args
    |> Enum.reject(&String.starts_with?(&1, "-"))
    |> List.first()
    |> then(&Map.get(refs, &1))
  end

  defp merge_source_ref(_refs, _args), do: nil

  defp advance_predecessor(state_dir, observation, git_args, event_ref) do
    refs = read_refs(state_dir)
    refs = Map.put(refs, observation.branch, event_ref)

    refs =
      case branch_target(git_args) do
        nil -> refs
        target -> Map.put(refs, target, event_ref)
      end

    atomic_json_write(Path.join(state_dir, @state_file), refs)
  end

  defp branch_target([command | args]) when command in ["branch", "checkout", "switch"] do
    args
    |> Enum.reject(&(&1 in ["-b", "-B", "-c", "-C"]))
    |> Enum.reject(&String.starts_with?(&1, "-"))
    |> List.first()
  end

  defp branch_target(_args), do: nil

  defp read_refs(state_dir) do
    with {:ok, bytes} <- File.read(Path.join(state_dir, @state_file)),
         {:ok, refs} when is_map(refs) <- Jason.decode(bytes) do
      refs
    else
      _ -> %{}
    end
  end

  defp atomic_json_write(path, value) do
    :ok = File.mkdir_p(Path.dirname(path))
    tmp = path <> ".tmp.#{System.unique_integer([:positive])}"

    with :ok <- File.write(tmp, Jason.encode!(value)),
         :ok <- File.rename(tmp, path) do
      :ok
    end
  end

  defp maybe_trace(nil, _event), do: :ok

  defp maybe_trace(path, event) do
    :ok = File.mkdir_p(Path.dirname(path))
    File.write(path, Jason.encode!(event) <> "\n", [:append])
  end

  defp human_message([_command | args]) do
    case message_flag(args) do
      nil -> Enum.join(args, " ")
      message -> message
    end
  end

  defp human_message([]), do: ""

  defp message_flag(["-m", message | _]), do: message
  defp message_flag(["--message", message | _]), do: message
  defp message_flag(["--message=" <> message | _]), do: message
  defp message_flag([_ | rest]), do: message_flag(rest)
  defp message_flag([]), do: nil

  defp hex(bytes), do: Base.encode16(bytes, case: :lower)
end
