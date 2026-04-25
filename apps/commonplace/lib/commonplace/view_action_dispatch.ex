defmodule Commonplace.ViewActionDispatch do
  @moduledoc """
  Core dispatcher for view `<action>` invocations.

  Shared by `CommonplaceWebWeb.ViewActions` (the LiveView caller) and
  `Commonplace.MCP.Tools.InvokeViewAction` (the MCP meta-tool caller).
  Lives in the core `commonplace` app and has no Phoenix dependencies.

  Per `docs/views.md` (Pass A + Pass C), every invocation:

  1. Broadcasts a magenta audit event on the `view_actions` topic so
     the audit-trail property holds regardless of invocation surface.
  2. Validates required context (e.g. `view_uuid` for actions that
     need a target doc).
  3. Pattern-matches on action name to either:
     - Return a `{:ok, :ui_transition, details}` intent that the
       caller applies to their UI state.
     - Perform a tree mutation (via `Commonplace.CommandRouter`) and
       return `{:ok, :tree_mutation, details}`.
     - Return `{:error, reason}`.

  The dispatcher owns the "what does this action mean" logic. Callers
  own their own "how do I apply the result" translation.

  ## Context map

      %{
        view_path: "wiki/about-views",   # human-readable path, informational
        view_uuid: "abc-...",             # UUID of the view doc
        target: "section-1" | nil,        # optional entity id within the view
        args: %{},                        # action args
        signer_id: "wiki-user@local"      # invoker identity (placeholder)
      }

  ## Return tuples

  * `{:ok, :ui_transition, %{action: "edit" | "history"}}` — the action
    is UI-local. The caller should apply it to their own state. For
    MCP callers there is no UI state, so they report a no-op.
  * `{:ok, :tree_mutation, %{action: "fork", new_uuid: "...",
    short_uuid: "abc12345"}}` — a commit landed. Callers can surface
    the details (flash, MCP response text).
  * `{:error, reason_string}` — invalid context, unknown action, or
    downstream failure. The reason is a human-readable string.
  """

  alias Commonplace.CommandRouter
  alias Commonplace.Dataflow.Magenta
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.{DocBuilder, Schema}
  alias Commonplace.Workspace
  alias Yelixer.Encoding

  @type dispatch_ok ::
          {:ok, :ui_transition, map()}
          | {:ok, :tree_mutation, map()}

  @type dispatch_result :: dispatch_ok() | {:error, String.t()}

  @type context :: %{
          optional(:view_path) => String.t(),
          optional(:view_uuid) => String.t() | nil,
          optional(:target) => String.t() | nil,
          optional(:args) => map(),
          optional(:signer_id) => String.t()
        }

  @doc """
  Dispatch a view action by name.

  Broadcasts a magenta audit event before handling the action. Returns
  a typed result tuple — see module doc for the full shape.
  """
  @spec dispatch(String.t(), context()) :: dispatch_result()
  def dispatch(action_name, %{} = context) when is_binary(action_name) do
    broadcast_audit(action_name, context)
    do_dispatch(action_name, context)
  end

  def dispatch(_other, _context) do
    {:error, "invalid action name"}
  end

  @doc """
  Broadcast an audit event without dispatching. Used by callers that
  want to record an intent before running their own handler.
  """
  @spec broadcast_audit(String.t(), context()) :: :ok
  def broadcast_audit(action_name, %{} = context) do
    payload = %{
      "view_path" => Map.get(context, :view_path),
      "view_uuid" => Map.get(context, :view_uuid),
      "action" => action_name,
      "target" => Map.get(context, :target),
      "args" => Map.get(context, :args, %{}),
      "signer_id" => Map.get(context, :signer_id)
    }

    # Callers pass their invocation surface as :source so observers can
    # distinguish wiki-LiveView-initiated actions from MCP-tool-initiated
    # actions in the audit stream. Defaults to "view_action_dispatch"
    # when not set — that's the "unknown surface" marker.
    source = Map.get(context, :source, "view_action_dispatch")

    msg = Magenta.message("view_action_invoked", source, payload)
    Magenta.send("view_actions", msg)
    :ok
  end

  # --- Action handlers ---

  defp do_dispatch("edit", %{view_uuid: uuid}) when is_binary(uuid) do
    {:ok, :ui_transition, %{action: "edit"}}
  end

  defp do_dispatch("edit", _context) do
    {:error, "cannot edit: no page loaded"}
  end

  defp do_dispatch("history", _context) do
    {:ok, :ui_transition, %{action: "history"}}
  end

  defp do_dispatch("fork", %{view_uuid: uuid}) when is_binary(uuid) do
    case CommandRouter.fork(uuid) do
      {:ok, new_uuid} when is_binary(new_uuid) ->
        short_uuid = String.slice(new_uuid, 0, 8)
        attach_name = "fork-" <> short_uuid

        base = %{
          action: "fork",
          new_uuid: new_uuid,
          short_uuid: short_uuid,
          source_uuid: uuid
        }

        details =
          case attach_to_root_schema(new_uuid, attach_name) do
            :ok ->
              Map.merge(base, %{attached: true, attached_as: attach_name})

            {:error, reason} ->
              Map.merge(base, %{attached: false, attach_error: inspect(reason)})
          end

        {:ok, :tree_mutation, details}

      {:error, reason} ->
        {:error, "fork failed: #{inspect(reason)}"}
    end
  end

  defp do_dispatch("fork", _context) do
    {:error, "cannot fork: no view UUID in context"}
  end

  # CX-487i (V1+V2 of CX-p2qp): chat post_message routes through
  # Commonplace.Chat.Actions.post_message. Required args: messages_uuid,
  # room, author_path, text. Optional: reply_to. signer_id and
  # signing_context flow from session context (CX-o3r7 plumbing).
  defp do_dispatch("post_message", %{args: args} = context) when is_map(args) do
    with {:ok, messages_uuid} <- fetch_arg(args, "messages_uuid"),
         {:ok, room} <- fetch_arg(args, "room"),
         {:ok, author_path} <- fetch_arg(args, "author_path"),
         {:ok, text} <- fetch_arg(args, "text") do
      action_opts =
        [
          room: room,
          author_path: author_path,
          signer_id: Map.get(context, :signer_id) || "mcp-agent@local"
        ]
        |> maybe_kw(:reply_to, args["reply_to"])
        |> maybe_kw(:signing_context, Map.get(context, :signing_context))
        |> maybe_kw(:store, Map.get(context, :store))

      case Commonplace.Chat.Actions.post_message(messages_uuid, text, action_opts) do
        {:ok, %{message_id: id, ts: ts}} ->
          {:ok, :tree_mutation,
           %{action: "post_message", message_id: id, ts: ts, messages_uuid: messages_uuid}}

        {:error, reason} ->
          {:error, "post_message failed: #{inspect(reason)}"}
      end
    end
  end

  defp do_dispatch("post_message", _context) do
    {:error, "post_message requires args map with messages_uuid, room, author_path, text"}
  end

  # CX-ybhb (V3 of CX-p2qp): edit_message routes through
  # Commonplace.Chat.Actions.edit_message. Required args: messages_uuid,
  # room, author_path, message_id, text.
  defp do_dispatch("edit_message", %{args: args} = context) when is_map(args) do
    with {:ok, messages_uuid} <- fetch_arg(args, "messages_uuid"),
         {:ok, room} <- fetch_arg(args, "room"),
         {:ok, author_path} <- fetch_arg(args, "author_path"),
         {:ok, message_id} <- fetch_arg(args, "message_id"),
         {:ok, text} <- fetch_arg(args, "text") do
      action_opts =
        [
          room: room,
          author_path: author_path,
          signer_id: Map.get(context, :signer_id) || "mcp-agent@local"
        ]
        |> maybe_kw(:signing_context, Map.get(context, :signing_context))
        |> maybe_kw(:store, Map.get(context, :store))

      case Commonplace.Chat.Actions.edit_message(messages_uuid, message_id, text, action_opts) do
        {:ok, %{message_id: edit_id, ts: ts}} ->
          {:ok, :tree_mutation,
           %{
             action: "edit_message",
             message_id: edit_id,
             edit_of: message_id,
             ts: ts,
             messages_uuid: messages_uuid
           }}

        {:error, reason} ->
          {:error, "edit_message failed: #{inspect(reason)}"}
      end
    end
  end

  defp do_dispatch("edit_message", _context) do
    {:error,
     "edit_message requires args map with messages_uuid, room, author_path, message_id, text"}
  end

  # CX-ybhb (V3 of CX-p2qp): delete_message routes through
  # Commonplace.Chat.Actions.delete_message. Required args:
  # messages_uuid, room, author_path, message_id. (No `text` — a
  # tombstone is the act, not new content.)
  defp do_dispatch("delete_message", %{args: args} = context) when is_map(args) do
    with {:ok, messages_uuid} <- fetch_arg(args, "messages_uuid"),
         {:ok, room} <- fetch_arg(args, "room"),
         {:ok, author_path} <- fetch_arg(args, "author_path"),
         {:ok, message_id} <- fetch_arg(args, "message_id") do
      action_opts =
        [
          room: room,
          author_path: author_path,
          signer_id: Map.get(context, :signer_id) || "mcp-agent@local"
        ]
        |> maybe_kw(:signing_context, Map.get(context, :signing_context))
        |> maybe_kw(:store, Map.get(context, :store))

      case Commonplace.Chat.Actions.delete_message(messages_uuid, message_id, action_opts) do
        {:ok, %{message_id: tomb_id, ts: ts}} ->
          {:ok, :tree_mutation,
           %{
             action: "delete_message",
             message_id: tomb_id,
             tombstone_of: message_id,
             ts: ts,
             messages_uuid: messages_uuid
           }}

        {:error, reason} ->
          {:error, "delete_message failed: #{inspect(reason)}"}
      end
    end
  end

  defp do_dispatch("delete_message", _context) do
    {:error,
     "delete_message requires args map with messages_uuid, room, author_path, message_id"}
  end

  defp do_dispatch(other, _context) do
    {:error, "unknown view action: #{other}"}
  end

  defp fetch_arg(args, key) do
    case Map.get(args, key) do
      nil -> {:error, "missing required arg: #{key}"}
      "" -> {:error, "missing required arg: #{key}"}
      value when is_binary(value) -> {:ok, value}
      other -> {:error, "arg #{key} must be a string, got: #{inspect(other)}"}
    end
  end

  defp maybe_kw(kw, _key, nil), do: kw
  defp maybe_kw(kw, _key, ""), do: kw
  defp maybe_kw(kw, key, value), do: Keyword.put(kw, key, value)

  # Attach a freshly-forked doc to the workspace root schema under
  # `attach_name`. Returns `:ok` on success or `{:error, reason}` on
  # any failure along the way. The fork itself already landed before
  # this is called, so callers treat an error here as "forked but not
  # attached" rather than a hard failure.
  defp attach_to_root_schema(new_uuid, attach_name) do
    with {:ok, root_uuid} <- Workspace.root_uuid(),
         {:ok, root_doc} <- load_root_schema(root_uuid) do
      updated = Schema.add_file(root_doc, attach_name, new_uuid)
      update_binary = Encoding.encode_update(updated)

      try do
        _ = CommitStoreClient.create_chained_commit(root_uuid, update_binary)
        :ok
      rescue
        e -> {:error, Exception.message(e)}
      catch
        :exit, reason -> {:error, {:exit, reason}}
      end
    end
  end

  defp load_root_schema(root_uuid) do
    case DocBuilder.reconstruct_snapshot(CommitStoreClient, root_uuid) do
      {:ok, doc} -> {:ok, doc}
      :none -> {:error, :no_root_schema}
      {:error, reason} -> {:error, reason}
    end
  end
end
