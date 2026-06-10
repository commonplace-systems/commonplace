defmodule Commonplace.Chat.ComputeRehydrator do
  @moduledoc """
  Boot-time re-hydration of chat view-computes (architecture-review R3,
  CX-tdkq.3).

  A `Commonplace.ViewCompute` keeps a chat room's `_view.xml` in sync with
  its `_messages` doc. Those computes are otherwise started *lazily* — only
  when a `ChatRoomLive` mounts (see `ChatRoomLive.mount/3`). That means a
  BEAM restart leaves every room's rendered view frozen at whatever
  `_view.xml` last held until a human happens to open the room. The review
  calls this out: "computed views ... should survive a BEAM restart without
  a human remembering them."

  This module is the registry that re-hydrates them from the substrate on
  boot. It scans the `/chat` directory the operator's workspace declares,
  and `ensure_started`s a ViewCompute for every room carrying a `_compute`
  spec. `ChatViewComputeSupervisor.ensure_started/2` is idempotent (per-room
  ETS index), so re-running — including a supervisor restart of this
  process — never duplicates a compute.

  ## Scope (why only chat)

  Chat rooms are the only computed views that exist in the substrate today.
  The generic `Commonplace.Process.Orchestrator` path (`__processes.json` +
  `SmartDoc`) is the broader "malleable software" engine, but supervising it
  in the general application tree would execute arbitrary substrate-declared
  code (including `:sandbox_exec` OS processes) on every boot — exactly the
  trust-boundary surface the federation-gated recommendations (R1/R2) cover.
  This rehydrator deliberately stays within the already-running local-chat
  trust model: it only resumes computes the LiveView would have started
  anyway.

  ## Lifecycle

  Started workspace-gated from `Commonplace.Application` (mirroring the
  presence Reaper): no child when there's no workspace root (test runs,
  fresh installs). The scan runs in `handle_continue/2` so boot isn't
  blocked, and is crash-isolated — a failure to rehydrate one workspace
  must never take down application startup. The root is resolved at scan
  time (not pinned at child-spec build) so a `cp checkout` re-root is
  followed without a restart, matching `Presence.Reaper`'s CX-4wl pattern.
  """

  use GenServer
  require Logger

  alias Commonplace.Chat.{ChatViewComputeSupervisor, Rooms}
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.{DocBuilder, Lookup, Schema}

  @chat_dir "chat"

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    {:ok, opts, {:continue, :rehydrate}}
  end

  @impl true
  def handle_continue(:rehydrate, opts) do
    case resolve_root(opts) do
      nil ->
        :ok

      root ->
        try do
          {:ok, n} = rehydrate(root, opts)
          if n > 0, do: Logger.info("ComputeRehydrator: resumed #{n} chat view-compute(s) on boot")
        rescue
          e -> Logger.warning("ComputeRehydrator: rehydration failed: #{inspect(e)}")
        catch
          kind, reason ->
            Logger.warning("ComputeRehydrator: rehydration #{kind}: #{inspect(reason)}")
        end
    end

    {:noreply, opts}
  end

  @doc """
  Scan `/chat` and `ensure_started` a ViewCompute for every room that
  declares a `_compute`. Idempotent. Returns `{:ok, started_count}`;
  `{:ok, 0}` when the workspace has no `/chat` directory yet.
  """
  def rehydrate(root_uuid, opts \\ []) when is_binary(root_uuid) do
    store = Keyword.get(opts, :store, CommitStoreClient)

    case Lookup.lookup_doc_by_path(root_uuid, @chat_dir, opts) do
      {:ok, chat_dir_uuid} ->
        {:ok, chat_doc} = DocBuilder.reconstruct_snapshot(store, chat_dir_uuid)

        count =
          chat_doc
          |> Schema.list_entries()
          |> Enum.filter(&room_dir?/1)
          |> Enum.reduce(0, fn entry, acc ->
            case start_room_compute(root_uuid, entry.name, opts) do
              {:ok, _pid} -> acc + 1
              _ -> acc
            end
          end)

        {:ok, count}

      {:error, _} ->
        {:ok, 0}
    end
  end

  defp resolve_root(opts) do
    case Keyword.fetch(opts, :root_uuid) do
      {:ok, root} ->
        root

      :error ->
        case Commonplace.Workspace.root_uuid() do
          {:ok, root} -> root
          {:error, _} -> nil
        end
    end
  end

  # A room is a directory entry under /chat other than the fork template.
  defp room_dir?(%Schema.Entry{type: :dir, name: name}), do: name != "__template"
  defp room_dir?(_), do: false

  defp start_room_compute(root_uuid, room_name, opts) do
    with {:ok, room} <- Rooms.lookup(root_uuid, room_name, opts),
         compute_uuid when is_binary(compute_uuid) <- room.compute_uuid do
      ChatViewComputeSupervisor.ensure_started(room_name,
        source_uuid: room.messages_uuid,
        target_uuid: room.view_uuid,
        spec_uuid: compute_uuid
      )
    else
      # No compute spec (pre-M5 room) or the room dir didn't resolve —
      # nothing to resume; skip without counting.
      _ -> {:skip, room_name}
    end
  end
end
