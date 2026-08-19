defmodule Commonplace.MCP.Tools.InvokeViewAction do
  @moduledoc """
  MCP meta-tool: invoke an action declared in a commonplace View document.

  Per `docs/views.md` (Views Pass C, CX-c1i), this is the single tool
  MCP clients use to dispatch any view action. Rather than synthesizing
  one MCP tool per `<action>` declaration in every known view (which
  would require dynamic tool registration that Claude Code's MCP client
  does not support), we register ONE meta-tool at initialize time and
  route all invocations through it.

  The tool:

  1. Reads the view doc content from the commit store
  2. Verifies the content is actually a view (via `ViewDetect.is_view?`)
  3. Parses the view XML (via `ViewXml.parse`)
  4. Verifies the requested action is actually declared in the view
  5. Dispatches through `Commonplace.ViewActionDispatch` — the same
     core used by `CommonplaceWebWeb.ViewActions`, so the audit trail
     and side effects are identical across invocation surfaces
  6. Returns a text summary + structured result in the MCP response

  ## Result shapes

  * UI-local actions (`edit`, `history`) return a note saying the
    action has no MCP-side effect. These are still broadcast as audit
    events so observers can see that an agent asked for them.
  * Tree-mutating actions (`fork`) return the details of the mutation
    (`new_uuid`, `short_uuid`, `source_uuid`).
  * Unknown actions, not-a-view docs, missing view UUIDs, and
    undeclared actions all return `{:error, reason_string}`.

  ## Per-session signing context (CX-o3r7)

  `run/2` — the arity `AnubisServer` threads through `Tools.call` —
  carries the per-session context map. Its load-bearing field is
  `:signing_context`: a `Commonplace.Crypto.SigningContext` (or
  `:unsigned`) that flows into `ViewActionDispatch`'s context and on to
  the action handlers, so a resulting commit can be signed by the
  session's *bound* key instead of the global SecretStore. The audit
  `signer_id` is derived from that context when present. Legacy `run/1`
  callers (and unsigned sessions) get an empty context and fall back to
  the `"mcp-agent@local"` placeholder. (The session context also feeds
  `ArgResolver` — e.g. `:presence_path` resolves `$session.*` action
  args.)

  ## Not in this pass

  * Dynamic action discovery per view (commonplace-plan's "pattern 3"
    — focused per-view registration at session restart)
  * JSON-schema args validation on complex actions
  * The upstream key-*minting* that populates a session's
    `signing_context` (CX-88mw). The propagation path above is wired,
    but until minting lands real MCP sessions still fall back to the
    `"mcp-agent@local"` placeholder.
  """

  alias Commonplace.Document.{ContentType, ViewDetect, ViewXml}
  alias Commonplace.MCP.Tools.Response
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.DocBuilder
  alias Commonplace.View.ArgResolver
  alias Commonplace.ViewActionDispatch

  def descriptor do
    %{
      "name" => "invoke_view_action",
      "description" =>
        "Invoke an action declared in a commonplace View document. Pass the view's UUID (find with cat or via the tree:// resource) and the action name. Tree-mutating actions (e.g. fork) return the mutation details; UI-local actions (edit, history) return a no-op note since MCP has no UI context. All invocations are broadcast as magenta audit events on the view_actions topic.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "view_uuid" => %{
            "type" => "string",
            "description" => "UUID of the view document."
          },
          "action" => %{
            "type" => "string",
            "description" => "Action name — must be declared in the view's <action> elements."
          },
          "target" => %{
            "type" => "string",
            "description" =>
              "Optional entity id the action operates on (when the action has a target attribute)."
          },
          "args" => %{
            "type" => "object",
            "description" => "Optional args object for the action."
          }
        },
        "required" => ["view_uuid", "action"]
      }
    }
  end

  def run(args), do: run(args, %{})

  # CX-o3r7: run/2 accepts the per-MCP-session context map populated by
  # AnubisServer.init/2 and threaded through Tools.call. Today its
  # interesting field is :signing_context — a Commonplace.Crypto.SigningContext
  # struct (or :unsigned) that flows down to ViewActionDispatch.context
  # and onward to action handlers, so chat-action commits can be signed
  # by the session's bound key instead of the global SecretStore.
  # Existing callers using run/1 get an empty context and the
  # "mcp-agent@local" placeholder, preserving today's behavior.
  def run(%{"view_uuid" => uuid, "action" => action} = args, context)
      when is_binary(uuid) and is_binary(action) and is_map(context) do
    case read_view_content(uuid) do
      {:ok, content} -> run_with_content(content, uuid, action, args, context)
      {:error, reason} -> {:error, reason}
    end
  end

  def run(_, _),
    do: {:error, :invalid_params, "view_uuid (string) and action (string) are required"}

  @doc false
  # Split out so tests can exercise parse + validate + dispatch without
  # needing a live CommitStore. run/1 provides the store-read wrapper.
  def run_with_content(content, uuid, action, args),
    do: run_with_content(content, uuid, action, args, %{})

  def run_with_content(content, uuid, action, args, session_context)
      when is_binary(content) and is_map(session_context) do
    target = args["target"]
    extra_args = args["args"] || %{}

    with :ok <- verify_is_view(content),
         {:ok, view_node} <- parse_view(content),
         :ok <- verify_action_declared(view_node, action),
         {:ok, resolved_args} <-
           ArgResolver.resolve_action(
             view_node,
             action,
             extra_args,
             resolver_context(args, session_context)
           ) do
      context = %{
        view_path: args["view_path"],
        view_uuid: uuid,
        target: target,
        args: resolved_args,
        signer_id: derive_signer_id(session_context),
        signing_context: Map.get(session_context, :signing_context),
        source: "mcp"
      }

      case ViewActionDispatch.dispatch(action, context) do
        {:ok, :ui_transition, details} ->
          summary =
            "UI-local action '#{action}' invoked (no MCP-side effect). Audit event broadcast on view_actions."

          {:ok,
           Response.text(
             summary,
             Map.merge(
               %{"class" => "ui_transition", "view_uuid" => uuid},
               stringify_keys(details)
             )
           )}

        {:ok, :tree_mutation, details} ->
          summary = format_mutation_summary(action, details)

          {:ok,
           Response.text(
             summary,
             Map.merge(
               %{"class" => "tree_mutation", "view_uuid" => uuid},
               stringify_keys(details)
             )
           )}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  # CX-waid (M3 sub-bead iii): build the context map ArgResolver expects.
  # `:view_path` drives `..` and `../{name}` kinds; session keys (e.g.
  # `:presence_path`) drive `$session.X` kinds. We forward whatever the
  # MCP session populated; ArgResolver's `lookup_session_key` handles
  # both string and atom keys defensively.
  defp resolver_context(args, session_context) do
    Map.merge(session_context, %{view_path: args["view_path"]})
  end

  # --- Private helpers ---

  # CX-o3r7: derive the audit-payload signer_id from the session
  # SigningContext when present. Falls back to the placeholder for
  # legacy callers (run/1) and unsigned writes. The substrate-level
  # key-minting bead (CX-88mw) will populate signing_context for real
  # MCP sessions; until then most callers see "mcp-agent@local".
  defp derive_signer_id(%{signing_context: %Commonplace.Crypto.SigningContext{} = ctx}) do
    Commonplace.Crypto.Signing.signer_id(ctx.identity_uuid, ctx.public_key)
  end

  defp derive_signer_id(_), do: "mcp-agent@local"

  defp read_view_content(uuid) do
    case DocBuilder.reconstruct_snapshot(CommitStoreClient, uuid) do
      {:ok, doc} ->
        case ContentType.get_content(doc) do
          nil -> {:error, "view doc is empty: #{uuid}"}
          "" -> {:error, "view doc is empty: #{uuid}"}
          content -> {:ok, content}
        end

      :none ->
        {:error, "view not found: #{uuid}"}
    end
  end

  defp verify_is_view(content) do
    if ViewDetect.is_view?(content) do
      :ok
    else
      {:error, "document content is not a view (root element is not <view>)"}
    end
  end

  defp parse_view(content) do
    case ViewXml.parse(content) do
      {:ok, view} -> {:ok, view}
      {:error, reason} -> {:error, "view parse error: #{inspect(reason)}"}
    end
  end

  defp verify_action_declared(view_node, action_name) do
    names = collect_action_names(view_node)

    if action_name in names do
      :ok
    else
      available =
        case names do
          [] -> "(none)"
          _ -> Enum.join(names, ", ")
        end

      {:error,
       "action '#{action_name}' not declared in this view. Available actions: #{available}"}
    end
  end

  defp collect_action_names(%ViewXml.Node{tag: :action, attrs: %{"name" => name}}), do: [name]
  defp collect_action_names(%ViewXml.Node{tag: :action}), do: []

  defp collect_action_names(%ViewXml.Node{children: children}) do
    Enum.flat_map(children, fn
      %ViewXml.Node{} = child -> collect_action_names(child)
      _ -> []
    end)
  end

  defp collect_action_names(_), do: []

  defp format_mutation_summary("fork", %{short_uuid: short}),
    do: "Forked view to new UUID #{short}"

  defp format_mutation_summary(action, _), do: "Tree-mutating action '#{action}' completed"

  # Atom keys from the dispatcher result map → string keys for JSON
  # output in the MCP response.
  defp stringify_keys(%{} = map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end
end
