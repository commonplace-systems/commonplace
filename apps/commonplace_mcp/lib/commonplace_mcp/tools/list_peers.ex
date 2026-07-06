defmodule Commonplace.MCP.Tools.ListPeers do
  @moduledoc """
  MCP tool: roster of visible actors (peers) with online/offline state
  (CX-6sf2.5, Messaging port B3).

  This is the substrate-native replacement for clod-squad's SQLite peer
  registry: instead of a side database, peers ARE presence documents
  already living in the document tree (`Commonplace.Presence`).

  ## Scope: root schema, one level, non-recursive

  Presence docs are created under whatever `dir_uuid` the calling actor
  passes to `Presence.create/4` — the workspace root for most agents,
  but a MUD room or a git-bridge mount for others. There is no single
  registry directory to deep-walk, and existing hot-presence consumers
  don't attempt one: `Commonplace.Presence.Reaper.find_stale/3` and
  `Commonplace.CLI.Who.run_with_store/3` (`who` with no `--all`) both
  scan only `Schema.list_entries/1` on the WORKSPACE ROOT schema via
  `Presence.discover/2` — root-level, non-recursive. This tool follows
  that same precedent rather than inventing a broader (and more
  expensive) tree walk: a peer registry answers "who's around", which
  is exactly what the root-level presence files already model.

  `__identities__` (`Commonplace.Presence.Identity`) is a DIFFERENT,
  cold/permanent registry (survives restarts, multi-writer) — not the
  hot heartbeat-bearing presence docs this tool reports on, so it's out
  of scope here.

  ## Online/offline

  A peer is `online` when its heartbeat is within
  `Commonplace.Presence.Reaper.default_stale_threshold/0` — the SAME
  threshold the reaper uses to decide what to reap, reused rather than
  reinvented so "online" here and "about to be reaped" there never
  disagree.
  """

  alias Commonplace.MCP.Tools.Response
  alias Commonplace.Presence
  alias Commonplace.Presence.Reaper
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.{DocBuilder, Schema}

  @honorific_types Map.values(Presence.type_to_ext())

  def descriptor do
    %{
      "name" => "list_peers",
      "description" =>
        "List visible actors (peers) as presence documents under the workspace root, with online/offline derived from heartbeat freshness. Optional `type` filters to one honorific (\"exe\", \"usr\", \"bot\", \"who\"); omit for all.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "type" => %{
            "type" => "string",
            "enum" => @honorific_types,
            "description" => "Filter to one actor type. Omit to return all types."
          }
        },
        "additionalProperties" => false
      }
    }
  end

  def run(args, context \\ %{})

  def run(args, _context) when is_map(args) do
    with {:ok, type_filter} <- parse_type(Map.get(args, "type")),
         {:ok, root_uuid} <- Commonplace.Workspace.root_uuid() do
      root_doc = load_schema(root_uuid, CommitStoreClient)
      entries = Presence.discover(root_doc, type_filter)
      threshold = Reaper.default_stale_threshold()

      peers =
        entries
        |> Enum.map(&build_peer(&1, threshold))
        |> Enum.reject(&is_nil/1)

      {:ok, Response.text(summary(peers), %{"peers" => peers})}
    else
      {:error, :invalid_type} ->
        {:error, :invalid_params, "list_peers: unknown type — expected one of #{inspect(@honorific_types)}"}

      {:error, reason} ->
        {:error, :invalid_params, "list_peers failed: #{inspect(reason)}"}
    end
  end

  defp parse_type(nil), do: {:ok, :all}

  defp parse_type(type) when is_binary(type) do
    case Presence.parse_honorific("x.#{type}") do
      {:ok, "x", atom} -> {:ok, atom}
      _ -> {:error, :invalid_type}
    end
  end

  defp parse_type(_), do: {:error, :invalid_type}

  defp build_peer(entry, threshold) do
    case Presence.read(entry.node_id, CommitStoreClient) do
      %{} = fields ->
        case Presence.parse_honorific(entry.name) do
          {:ok, name, type} ->
            %{
              "name" => name,
              "type" => Atom.to_string(type),
              "status" => Map.get(fields, "status"),
              "online" => online?(Map.get(fields, "heartbeat"), threshold),
              "last_seen" => Map.get(fields, "heartbeat")
            }
            |> maybe_put_activity(Map.get(fields, "activity"))

          :error ->
            nil
        end

      _ ->
        nil
    end
  end

  defp maybe_put_activity(peer, nil), do: peer
  defp maybe_put_activity(peer, ""), do: peer
  defp maybe_put_activity(peer, activity), do: Map.put(peer, "activity", activity)

  defp online?(nil, _threshold), do: false

  defp online?(heartbeat, threshold) when is_binary(heartbeat) do
    case DateTime.from_iso8601(heartbeat) do
      {:ok, hb_time, _} ->
        DateTime.diff(DateTime.utc_now(), hb_time, :millisecond) <= threshold

      _ ->
        false
    end
  end

  defp summary([]), do: "No peers present."
  defp summary(peers), do: "#{length(peers)} peer(s)."

  defp load_schema(uuid, store) do
    case DocBuilder.reconstruct_snapshot(store, uuid) do
      {:ok, doc} -> doc
      :none -> Schema.new_schema()
    end
  end
end
