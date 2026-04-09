defmodule Commonplace.CommandRouter do
  @moduledoc """
  Singleton GenServer that routes mutating command verbs through a single
  surface, emitting magenta command.initiated / command.completed / command.failed
  events around each handler call.

  Every command verb (fork, merge, gc, branch_activate, …) is a handle_call
  clause here. The CLI and the MCP server both call through this router instead
  of calling the underlying modules (Fork / Merge / GC / …) directly, so that
  every invocation lands on the `__commands` magenta topic and — via the
  standard magenta→red onramp — on a gold-attested audit chain.

  ## Why this exists

  Commonplace's color-channel design wants a single observable command surface.
  Direct module calls from the CLI bypass magenta entirely, leaving MCP with
  no way to "participate in the graph" beyond blind writes. Full magenta
  pub/sub routing would rebuild GenServer.call from scratch — so we use
  GenServer.call natively here and emit magenta events as a side-effect.
  """

  use GenServer
  require Logger

  alias Commonplace.CommandRouter.Events
  alias Commonplace.Document.{ContentType, Diff}
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Store.GC
  alias Commonplace.Tree.{DocBuilder, Fork, Merge, Schema}

  defstruct [:store]

  # --- Client API ---

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Fork a directory subtree by DAG-branching from `source_uuid`.
  Returns {:ok, new_uuid} or {:error, reason}.
  """
  def fork(server \\ __MODULE__, source_uuid) do
    GenServer.call(server, {:fork, source_uuid})
  end

  @doc """
  Three-way CRDT merge from `source_uuid` into `target_uuid`.
  Returns {:ok, summary_map} or {:error, reason}. The summary map has
  keys "merged_count", "new_count", "deleted_count", "conflict_count",
  "auto_renamed" (list of maps), and "conflicts" (list).
  """
  def merge(server \\ __MODULE__, source_uuid, target_uuid) do
    GenServer.call(server, {:merge, source_uuid, target_uuid})
  end

  @doc """
  Run reachability GC starting from `root_uuid`.
  Returns {:ok, report_map} with keys "reachable_count", "orphaned_count",
  and "orphaned_uuids" (list of strings).
  """
  def gc(server \\ __MODULE__, root_uuid) do
    GenServer.call(server, {:gc, root_uuid})
  end

  @doc """
  Activate a named child directory on `parent_uuid` (sets sync=true so the
  sync agent exports it to disk). Returns {:ok, %{...}} or {:error, :not_found}.
  """
  def branch_activate(server \\ __MODULE__, parent_uuid, name) do
    GenServer.call(server, {:branch_set_sync, parent_uuid, name, true})
  end

  @doc """
  Deactivate a named child directory on `parent_uuid` (sets sync=false).
  Returns {:ok, %{...}} or {:error, :not_found}.
  """
  def branch_deactivate(server \\ __MODULE__, parent_uuid, name) do
    GenServer.call(server, {:branch_set_sync, parent_uuid, name, false})
  end

  @doc """
  Update the text content of an existing blue doc identified by `uuid` to
  `new_content`, using a Myers-diff smart merge (character-level insert/delete
  ops) so concurrent CRDT edits are preserved. Returns {:ok, %{...}} or
  {:error, :not_found} if the doc does not exist.
  """
  def write(server \\ __MODULE__, uuid, new_content) when is_binary(new_content) do
    GenServer.call(server, {:write, uuid, new_content})
  end

  # --- GenServer ---

  @impl true
  def init(opts) do
    store = Keyword.get(opts, :store, CommitStoreClient)
    {:ok, %__MODULE__{store: store}}
  end

  @impl true
  def handle_call({:fork, source_uuid}, _from, state) do
    result =
      Events.run("fork", %{"source_uuid" => source_uuid}, fn ->
        new_uuid = Fork.fork_directory(source_uuid, state.store)
        {:ok, new_uuid, %{"new_uuid" => new_uuid}}
      end)

    {:reply, result, state}
  end

  @impl true
  def handle_call({:merge, source_uuid, target_uuid}, _from, state) do
    args = %{"source_uuid" => source_uuid, "target_uuid" => target_uuid}

    result =
      Events.run("merge", args, fn ->
        case Merge.merge(source_uuid, target_uuid, state.store) do
          {:ok, report} ->
            summary = merge_report_summary(report)
            {:ok, summary}

          {:error, reason} ->
            {:error, reason}
        end
      end)

    {:reply, result, state}
  end

  @impl true
  def handle_call({:write, uuid, new_content}, _from, state) do
    args = %{"uuid" => uuid, "new_bytes" => byte_size(new_content)}

    result =
      Events.run("write", args, fn ->
        case DocBuilder.reconstruct_snapshot(state.store, uuid) do
          {:ok, doc} ->
            old_content = ContentType.get_content(doc) || ""
            doc = Diff.apply_diff(doc, old_content, new_content)
            update = Yelixer.Encoding.encode_update(doc)
            CommitStoreClient.create_chained_commit(state.store, uuid, update)

            audit = %{
              "uuid" => uuid,
              "old_bytes" => byte_size(old_content),
              "new_bytes" => byte_size(new_content)
            }

            {:ok, audit, audit}

          :none ->
            {:error, :not_found}
        end
      end)

    {:reply, result, state}
  end

  @impl true
  def handle_call({:branch_set_sync, parent_uuid, name, sync?}, _from, state) do
    verb = if sync?, do: "branch_activate", else: "branch_deactivate"
    args = %{"parent_uuid" => parent_uuid, "name" => name}

    result =
      Events.run(verb, args, fn ->
        case DocBuilder.reconstruct_snapshot(state.store, parent_uuid) do
          {:ok, doc} ->
            case Schema.get_entry(doc, name) do
              {:ok, _entry} ->
                doc = Schema.set_sync(doc, name, sync?)
                update = Yelixer.Encoding.encode_update(doc)
                CommitStoreClient.create_chained_commit(state.store, parent_uuid, update)
                {:ok, %{"parent_uuid" => parent_uuid, "name" => name, "sync" => sync?}}

              :error ->
                {:error, :not_found}
            end

          :none ->
            {:error, :not_found}
        end
      end)

    {:reply, result, state}
  end

  @impl true
  def handle_call({:gc, root_uuid}, _from, state) do
    args = %{"root_uuid" => root_uuid}

    result =
      Events.run("gc", args, fn ->
        report = GC.report(root_uuid, state.store)

        summary = %{
          "reachable_count" => report.reachable_count,
          "orphaned_count" => report.orphaned_count,
          "orphaned_uuids" => Enum.to_list(report.orphaned_uuids)
        }

        {:ok, summary}
      end)

    {:reply, result, state}
  end

  # --- Merge report → audit-friendly summary ---

  defp merge_report_summary(%Merge.MergeReport{} = report) do
    %{
      "merged_count" => length(report.merged_docs),
      "new_count" => length(report.new_docs),
      "deleted_count" => length(report.deleted_docs),
      "conflict_count" => length(report.conflicts),
      "auto_renamed" =>
        Enum.map(report.auto_renamed, fn {:auto_renamed, original, renamed, _src, _new} ->
          %{"original" => original, "renamed" => renamed}
        end),
      "conflicts" =>
        Enum.map(report.conflicts, fn conflict ->
          inspect(conflict)
        end)
    }
  end
end
