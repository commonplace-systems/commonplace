defmodule Commonplace.ViewActionDispatch do
  @moduledoc """
  Core dispatcher for view `<action>` invocations.

  Shared by `CommonplaceWebWeb.ViewActions` (the LiveView caller) and
  `Commonplace.MCP.Tools.InvokeViewAction` (the MCP meta-tool caller).
  Lives in the core `commonplace` app and has no Phoenix dependencies.

  Per `docs/views.md` (Pass A + Pass C), every invocation:

  1. Broadcasts an audit event on the *magenta* channel's
     `view_actions` topic — magenta is Commonplace's color-named
     convention for audit / provenance events (the color vocabulary is
     owned by `Commonplace.Dataflow.Channel`). This fires *before*
     validation and for *every* action, including ones that go on to
     fail, so the audit trail records every attempt from either
     invocation surface — not just the successes.
  2. Validates required context (e.g. `view_uuid` for actions that
     need a target doc).
  3. Pattern-matches on action name to either:
     - Return a `{:ok, :ui_transition, details}` intent that the
       caller applies to their UI state.
     - Perform a tree mutation — a change to the document tree that
       lands a commit, via `Commonplace.CommandRouter` — and return
       `{:ok, :tree_mutation, details}`.
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

  No key is globally required — the `context` type marks them all
  optional, and each action validates only what it needs: `edit` and
  `fork` require `view_uuid`; the chat actions (`post_message`,
  `edit_message`, `delete_message`) require an `args` map.

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
  alias Commonplace.WriterHand
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
          optional(:signer_id) => String.t(),
          optional(:signing_context) => Commonplace.Crypto.SigningContext.t() | nil,
          optional(:hand) => non_neg_integer() | nil
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
  # CX-qat5.2 §2.4: `:hand` (the session's stable W4 client-id, when the
  # caller resolved one) flows through as `:client_id` — see
  # `Chat.Actions.load_messages_doc/3`'s hand-selection order.
  #
  # CX-waid (M3 sub-bead iii): args arrive PRE-RESOLVED by
  # `Commonplace.View.ArgResolver` running in InvokeViewAction (MCP
  # path) and CommonplaceWebWeb.ViewActions (HTML path). The dispatcher
  # no longer calls Chat.Actions.resolve_args/4 — substrate resolution
  # happens upstream now. Caller-wins precedence is preserved by
  # ArgResolver's maybe_put semantics.
  defp do_dispatch("post_message", %{args: args} = context)
       when is_map(args) do
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
        |> maybe_kw(:messages_log_uuid, args["messages_log_uuid"])
        |> maybe_kw(:signing_context, Map.get(context, :signing_context))
        |> maybe_kw(:client_id, Map.get(context, :hand))
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
  # room, author_path, message_id, text. (CX-waid: args pre-resolved
  # by ArgResolver upstream.)
  defp do_dispatch("edit_message", %{args: args} = context)
       when is_map(args) do
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
        |> maybe_kw(:messages_log_uuid, args["messages_log_uuid"])
        |> maybe_kw(:signing_context, Map.get(context, :signing_context))
        |> maybe_kw(:client_id, Map.get(context, :hand))
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
  # tombstone is the act, not new content.) (CX-waid: args pre-resolved
  # by ArgResolver upstream.)
  defp do_dispatch("delete_message", %{args: args} = context)
       when is_map(args) do
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
        |> maybe_kw(:messages_log_uuid, args["messages_log_uuid"])
        |> maybe_kw(:signing_context, Map.get(context, :signing_context))
        |> maybe_kw(:client_id, Map.get(context, :hand))
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

  # CX-2qjd: outline actions route through Commonplace.Outline.* — the
  # SAME mutation implementation OutlineLive's keybinds call directly
  # (outliner.md §5: one implementation, two entry points). The agent's
  # signing_context threads through, so MCP-driven restructuring is
  # signed with the agent's own key (CX-88mw).
  @outline_actions ~w(add_item set_text indent_item outdent_item reorder_item toggle_collapse delete_item)

  defp do_dispatch(action, %{args: args} = context)
       when action in @outline_actions and is_map(args) do
    with {:ok, uuid} <- fetch_arg(args, "outline_uuid") do
      store = Map.get(context, :store) || CommitStoreClient

      opts =
        []
        |> maybe_kw(:signing_context, Map.get(context, :signing_context))

      case run_outline_action(action, store, uuid, args, opts) do
        {:ok, details} ->
          {:ok, :tree_mutation, Map.merge(%{action: action, outline_uuid: uuid}, details)}

        :ok ->
          {:ok, :tree_mutation, %{action: action, outline_uuid: uuid}}

        {:error, reason} ->
          {:error, "#{action} failed: #{inspect(reason)}"}
      end
    end
  end

  defp do_dispatch(action, _context) when action in @outline_actions do
    {:error, "#{action} requires args map with outline_uuid (+ per-action args)"}
  end

  defp do_dispatch(other, _context) do
    {:error, "unknown view action: #{other}"}
  end

  defp run_outline_action("add_item", store, uuid, args, opts) do
    attrs =
      %{text: Map.get(args, "text", "")}
      |> then(fn m -> if args["parent"] in [nil, ""], do: m, else: Map.put(m, :parent, args["parent"]) end)
      |> then(fn m -> if args["after"] in [nil, ""], do: m, else: Map.put(m, :after, args["after"]) end)

    with {:ok, id} <- Commonplace.Outline.add_item(store, uuid, attrs, opts), do: {:ok, %{id: id}}
  end

  defp run_outline_action("set_text", store, uuid, args, opts) do
    with {:ok, id} <- fetch_arg(args, "id"),
         {:ok, text} <- fetch_arg(args, "text") do
      Commonplace.Outline.set_text(store, uuid, id, text, opts)
    end
  end

  defp run_outline_action("indent_item", store, uuid, args, opts) do
    with {:ok, id} <- fetch_arg(args, "id"), do: Commonplace.Outline.indent(store, uuid, id, opts)
  end

  defp run_outline_action("outdent_item", store, uuid, args, opts) do
    with {:ok, id} <- fetch_arg(args, "id"), do: Commonplace.Outline.outdent(store, uuid, id, opts)
  end

  defp run_outline_action("reorder_item", store, uuid, args, opts) do
    with {:ok, id} <- fetch_arg(args, "id"),
         {:ok, dir} <- fetch_arg(args, "direction") do
      Commonplace.Outline.reorder(store, uuid, id, String.to_existing_atom(dir), opts)
    end
  end

  defp run_outline_action("toggle_collapse", store, uuid, args, opts) do
    with {:ok, id} <- fetch_arg(args, "id") do
      item = Commonplace.Outline.items(store, uuid) |> Enum.find(&(&1.id == id))

      if item,
        do: Commonplace.Outline.set_collapsed(store, uuid, id, not item.collapsed, opts),
        else: {:error, :no_such_item}
    end
  end

  defp run_outline_action("delete_item", store, uuid, args, opts) do
    with {:ok, id} <- fetch_arg(args, "id"),
         do: Commonplace.Outline.delete_item(store, uuid, id, opts)
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
        case CommitStoreClient.create_chained_commit(root_uuid, update_binary) do
          {:error, _} = err -> err
          _commit -> :ok
        end
      rescue
        e -> {:error, Exception.message(e)}
      catch
        :exit, reason -> {:error, {:exit, reason}}
      end
    end
  end

  # CX-41qg.3: stable per-doc hand — this is the doc `attach_to_root_schema/2`
  # re-encodes a new commit onto, and the workspace root schema gets a
  # fork-attach commit on every fork. Without a fixed client_id each
  # attach minted a fresh random one, unboundedly bloating the root
  # schema's state vector.
  defp load_root_schema(root_uuid) do
    case DocBuilder.reconstruct_snapshot(CommitStoreClient, root_uuid,
           client_id: WriterHand.for_doc(root_uuid)
         ) do
      {:ok, doc} -> {:ok, doc}
      :none -> {:error, :no_root_schema}
      {:error, reason} -> {:error, reason}
    end
  end
end
