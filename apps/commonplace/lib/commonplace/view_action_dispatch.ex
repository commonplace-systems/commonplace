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
  alias Commonplace.Crypto.Signing
  alias Commonplace.Dataflow.Magenta
  alias Commonplace.Document.ContentType
  alias Commonplace.Document.Diff
  alias Commonplace.Pulls.Template
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.{DocBuilder, Lookup, Merge, Schema}
  alias Commonplace.Trust
  alias Commonplace.Trust.ReadMeta
  alias Commonplace.Workspace
  alias Commonplace.WriterHand
  alias Yelixer.Encoding

  # CX-pr7.3b: the two preview-guard refusals, shared verbatim by
  # `pr_refresh_preview` and `pr_accept` (one derivation path, one pair
  # of messages). The read refusal is deliberately UNIFORM — it never
  # says WHICH of source/target refused, nor whether the doc exists at
  # all (thin-handle: no existence oracle).
  @not_readable_msg "cannot preview: source or target not readable"
  @no_ancestor_msg "cannot preview: no common ancestor — source and target are not fork-related"

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

  # CX-ajdx: the wiki `fork` <action> must sign BOTH commits it lands — the
  # fork's genesis (CommandRouter.fork/3, §7.3c signing plumb) AND the
  # root-schema attach — with the invoking session's signing_context
  # (`signing_opts(context)`, the same server-resolved plumbing pr_open uses),
  # or under enforce both are refused `:unsigned` and web fork is broken. The
  # signer still needs root-write authority for the attach to land (node/
  # trusted identity in the demo); a citizen-scoped fork target is a separate
  # concern, out of this fix.
  defp do_dispatch("fork", %{view_uuid: uuid} = context) when is_binary(uuid) do
    opts = signing_opts(context)

    case CommandRouter.fork(CommandRouter, uuid, opts) do
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
          case attach_to_root_schema(new_uuid, attach_name, opts) do
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

  # CX-pr7.0/pr7.2: intra-repo pull request `pr_open` (design doc
  # docs/plans/2026-07-16-intra-repo-pull-request-design.md §7.0/§7.2,
  # commonplace-plan). `view_uuid` is the source B (the fork; the
  # button lives in B's page chrome next to fork/edit/history).
  #
  # Target resolution: there is no cheap commit->doc reverse index in
  # CommitStore (only full `all_doc_uuids` enumeration), so target is
  # named explicitly via `args["target"]` — a uuid or a repo-root path
  # (resolved the same way `Commonplace.Tree.Lookup.lookup_doc_by_path/3`
  # resolves any other path). Designer ruling: regardless of how target
  # was named, `find_common_ancestor(target, source)` must not be
  # `:none` — one validation on every path, not just the path-form one.
  #
  # `opened_by` is resolved server-side from the dispatch signing
  # plumbing (`context.signing_context`, falling back to
  # `context.signer_id`) — never read from `args` (§6.3: no verb ever
  # trusts PR-doc-bound fields, and by the same logic no verb trusts a
  # client-asserted identity for a field it stamps into a doc).
  defp do_dispatch("pr_open", %{view_uuid: source_uuid, args: args} = context)
       when is_binary(source_uuid) and is_map(args) do
    with {:ok, target_uuid} <- resolve_pr_target(args),
         {:ok, ancestor_commit} <- validate_common_ancestor(target_uuid, source_uuid) do
      opts = signing_opts(context)
      opened_by = resolve_principal(context)
      base_hex = Base.encode16(ancestor_commit.id, case: :lower)

      with {:ok, pulls_uuid} <- ensure_pulls_dir(opts),
           {:ok, pr_uuid} <- create_pr_doc(source_uuid, target_uuid, base_hex, opened_by, opts) do
        attach_name = "pr-" <> String.slice(pr_uuid, 0, 8)

        case attach_entry(pulls_uuid, attach_name, pr_uuid, opts) do
          :ok ->
            {:ok, :tree_mutation,
             %{
               action: "pr_open",
               pr_uuid: pr_uuid,
               attached_as: attach_name,
               source_uuid: source_uuid,
               target_uuid: target_uuid
             }}

          {:error, reason} ->
            {:error, "pr_open failed to attach PR doc: #{inspect(reason)}"}
        end
      else
        {:error, reason} -> {:error, "pr_open failed: #{inspect(reason)}"}
      end
    else
      # Designer ruling (#8390): stringify at the dispatch boundary — the
      # LiveView adapter flashes reasons and MCP interpolates them; the
      # bare atom stays internal (validate_common_ancestor) for reuse.
      {:error, :no_common_ancestor} ->
        {:error, "pr_open failed: no common ancestor — target is not fork-related to source"}
      {:error, reason} -> {:error, "pr_open failed: #{inspect(reason)}"}
    end
  end

  defp do_dispatch("pr_open", _context) do
    {:error, "pr_open requires view_uuid (source) and args map with target"}
  end

  # CX-pr7.3: `pr_refresh_preview` — the scratch-fork preview mechanic
  # (design doc §7.3). `view_uuid` = the PR doc itself. Every step is
  # server-side and re-derived from the PR doc's OWN recorded
  # `<pr source=... target=... status=.../>` attributes — reading those
  # attributes back off the doc is fine (§6.3: nothing about the PR
  # doc is trusted for *enforcement*, but re-reading its own
  # server-authored fields to know which two docs to diff is not an
  # enforcement decision, just routing).
  #
  # Statelessness (design doc, end of §7.3): every invocation forks a
  # BRAND NEW scratch copy of the target and merges into *that* — never
  # into the real target. `Merge.merge/4`'s `target_uuid` positional
  # arg is the only doc `set_merge_point/4` ever writes to (see
  # merge.ex), so passing the scratch uuid there means the real target
  # accumulates no `(target, source)` merge-point and takes no commit
  # at all during a preview run. The scratch fork is never attached to
  # any schema (§7.3: "born unreachable = scratch by construction");
  # reachability GC (`CommandRouter.gc/2`), not this verb, owns
  # reclaiming it.
  defp do_dispatch("pr_refresh_preview", %{view_uuid: pr_uuid} = context)
       when is_binary(pr_uuid) do
    opts = signing_opts(context)

    with {:ok, doc} <- reconstruct_pr_doc(pr_uuid),
         content = ContentType.get_content(doc) || "",
         {:ok, attrs} <- parse_pr_attrs(content),
         :ok <- require_open(attrs) do
      refresh_preview(pr_uuid, doc, content, attrs, context, opts)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_dispatch("pr_refresh_preview", _context) do
    {:error, "pr_refresh_preview requires view_uuid (the PR doc)"}
  end

  # CX-pr7.4: `pr_accept` — the TRUST-GATE verb. Design doc §6 lists six
  # steps, IN ORDER, all server-side, all inside this handler; the
  # numbers below are literal citations so a reviewer can check this
  # code against that checklist line by line:
  #
  #   1. server-resolved source/target/base/status — `reconstruct_pr_doc/1`
  #      + `parse_pr_attrs/1` re-read the PR doc BY UUID (`view_uuid`);
  #      the click carries nothing else, `context.args` is never
  #      consulted for routing.
  #   2. status gate — `require_open/1`.
  #   3. staleness by RE-DERIVATION — `accept_pr/5` reruns the exact
  #      scratch-preview mechanics §7.3 already built (`derive_preview/3`,
  #      extracted below so `pr_refresh_preview` and `pr_accept` share
  #      ONE derivation path) and compares the fresh `result_hash`
  #      against `extract_committed_result_hash/1`'s read of the
  #      COMMITTED preview section — never against any doc-recorded head
  #      CID (forgeable, §6.3). A mismatch (or no committed hash at all —
  #      the placeholder path) auto-refreshes the section via the same
  #      `commit_preview_section/5` §7.3 uses, then refuses.
  #   4. authorization — `do_accept_merge/5` calls
  #      `Trust.writer_authorized?/6` (the commitless dispatch-site
  #      pre-check; same predicate other verbs' elevation checks use)
  #      on the ACCEPTOR's principal (`principal_identity/1`, derived
  #      from `context.signing_context`, never a client-asserted arg)
  #      against the target uuid. Refusal is sanitized before it leaves
  #      this module (CX-3x5a).
  #   5. signed merge — `Merge.merge/4` is called with the acceptor's
  #      own `signing_opts(context)`, so every commit the merge produces
  #      carries the acceptor's cert and the local write-gate evaluates
  #      the ACTUAL authority under enforce (closes the unsigned-merge
  #      gap §3/§7.1 fixed). A `{:write_refused, _, _}` surfaces through
  #      the 7.1b contract and is sanitized here rather than passed
  #      through raw.
  #   6. sanitized returns — every branch below returns a domain atom/
  #      string, never a raw `{:error, {:untrusted_signer, _}}"`-shaped
  #      trust tuple.
  #
  # On success (`finish_accept/5`): status → `:merged`, acceptor +
  # MergeReport summary recorded in the PR doc via `Template` helpers,
  # invoker(acceptor)-signed.
  defp do_dispatch("pr_accept", %{view_uuid: pr_uuid} = context) when is_binary(pr_uuid) do
    opts = signing_opts(context)

    with {:ok, doc} <- reconstruct_pr_doc(pr_uuid),
         content = ContentType.get_content(doc) || "",
         {:ok, attrs} <- parse_pr_attrs(content),
         :ok <- require_open(attrs) do
      accept_pr(pr_uuid, doc, content, attrs, context, opts)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_dispatch("pr_accept", _context) do
    {:error, "pr_accept requires view_uuid (the PR doc)"}
  end

  # CX-pr7.4: `pr_decline` — allowed for a target-`:write` holder OR the
  # PR's own opener, per designer ruling #8390-1 (cited at
  # `opener_may_decline?/2`): the opener branch matches ONLY when BOTH
  # the doc's recorded `opened_by` AND the current session's principal
  # are signing-context-derived — an anonymous-opened PR (the
  # `resolve_principal/1` fallback) confers NO opener rights, because
  # every anonymous session would otherwise "be" every anonymous opener.
  defp do_dispatch("pr_decline", %{view_uuid: pr_uuid} = context) when is_binary(pr_uuid) do
    opts = signing_opts(context)

    with {:ok, doc} <- reconstruct_pr_doc(pr_uuid),
         content = ContentType.get_content(doc) || "",
         {:ok, attrs} <- parse_pr_attrs(content),
         :ok <- require_open(attrs) do
      decline_pr(pr_uuid, doc, content, attrs, context, opts)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_dispatch("pr_decline", _context) do
    {:error, "pr_decline requires view_uuid (the PR doc)"}
  end

  # CX-pr7.4: `pr_comment` — any session may append a review comment
  # (attribution is honest: an anonymous session's principal shows as
  # the anonymous fallback, same as `pr_open`'s `opened_by`). Text comes
  # from `args["text"]` — the existing form-render path (`args="text:
  # string"` on the `<action>` element, same shape `post_message` etc.
  # use).
  defp do_dispatch("pr_comment", %{view_uuid: pr_uuid, args: args} = context)
       when is_binary(pr_uuid) and is_map(args) do
    opts = signing_opts(context)

    with {:ok, text} <- fetch_arg(args, "text"),
         {:ok, doc} <- reconstruct_pr_doc(pr_uuid),
         content = ContentType.get_content(doc) || "" do
      principal = resolve_principal(context)
      ts = DateTime.utc_now() |> DateTime.to_iso8601()
      new_content = Template.append_review(content, principal, ts, text)

      case commit_pr_update(pr_uuid, doc, content, new_content, opts) do
        :ok ->
          {:ok, :tree_mutation, %{action: "pr_comment", pr_uuid: pr_uuid, principal: principal}}

        {:error, reason} ->
          {:error, "pr_comment failed: #{sanitize_write_error(reason)}"}
      end
    end
  end

  defp do_dispatch("pr_comment", _context) do
    {:error, "pr_comment requires view_uuid (the PR doc) and args map with text"}
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

  # Bd P2 graph-vocabulary lift, Slice S1 Part 4: ticket-mutating verbs
  # that funnel through `Commonplace.Bd.WriteGuard` before landing a
  # commit — same shape as `pr_open`/`pr_refresh_preview` above (read
  # `context.signing_context`, land a signed commit via the plumbed
  # `Commonplace.Bd.Issue.update/5` opts, return
  # `{:ok, :tree_mutation, details}` | `{:error, reason_string}`).
  #
  # `Commonplace.Bd.*` has no notion of "the workspace root" the way
  # `pr_open` does (its `root_uuid` is an explicit caller-supplied
  # parameter in every test/CLI call), so these verbs resolve it the
  # same way `pr_open`'s `ensure_pulls_dir/1` does: the top-level
  # `Commonplace.Workspace.root_uuid/0` pointer file, then
  # `Commonplace.Bd.Workspace.issue_dir_uuid/3` to resolve a ticket id
  # to its directory.
  #
  # `ticket_add_needs`: dependent ticket id + prereq ref (ticket +
  # optional repo). Exercises ref-type shape checks AND the cycle gate
  # — `WriteGuard` walks the prereq's local-needs-ancestors to refuse
  # an edge that would close a cycle back to the dependent.
  defp do_dispatch("ticket_add_needs", %{args: args} = context) when is_map(args) do
    with {:ok, ticket_id} <- fetch_arg(args, "ticket"),
         {:ok, prereq_id} <- fetch_arg(args, "needs_ticket"),
         {:ok, root_uuid} <- Workspace.root_uuid(),
         {:ok, issue} <- load_bd_issue(root_uuid, ticket_id) do
      ref = build_need_ref(prereq_id, Map.get(args, "needs_repo"))
      new_needs = (issue.needs || []) ++ [ref]
      changes = %{needs: new_needs}

      case Commonplace.Bd.WriteGuard.check(issue, changes, root_uuid, CommitStoreClient, allow: []) do
        :ok ->
          opts = signing_opts(context)

          case Commonplace.Bd.Issue.update(root_uuid, ticket_id, changes, CommitStoreClient, opts) do
            {:ok, updated} ->
              {:ok, :tree_mutation,
               %{action: "ticket_add_needs", ticket: ticket_id, needs: updated.needs}}

            {:error, reason} ->
              {:error, "ticket_add_needs failed: #{inspect(reason)}"}
          end

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, "ticket_add_needs failed: #{inspect(reason)}"}
    end
  end

  defp do_dispatch("ticket_add_needs", _context) do
    {:error, "ticket_add_needs requires args map with ticket + needs_ticket"}
  end

  # `ticket_update`: ticket id + a map of field changes. `WriteGuard`
  # is called with `allow: []` — exercises protected-field refusal
  # (a change touching status/done_witness/claimed_by is refused) and
  # ref-type checks on any needs/done_witness/claimed_by field in the
  # same payload.
  defp do_dispatch("ticket_update", %{args: %{"ticket" => ticket_id, "changes" => changes_map}} = context)
       when is_binary(ticket_id) and is_map(changes_map) do
    with {:ok, root_uuid} <- Workspace.root_uuid(),
         {:ok, issue} <- load_bd_issue(root_uuid, ticket_id) do
      changes = atomize_ticket_changes(changes_map)

      case Commonplace.Bd.WriteGuard.check(issue, changes, root_uuid, CommitStoreClient, allow: []) do
        :ok ->
          opts = signing_opts(context)

          case Commonplace.Bd.Issue.update(root_uuid, ticket_id, changes, CommitStoreClient, opts) do
            {:ok, updated} ->
              {:ok, :tree_mutation, %{action: "ticket_update", ticket: ticket_id, issue: updated}}

            {:error, reason} ->
              {:error, "ticket_update failed: #{inspect(reason)}"}
          end

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, "ticket_update failed: #{inspect(reason)}"}
    end
  end

  defp do_dispatch("ticket_update", _context) do
    {:error, "ticket_update requires args map with ticket + changes"}
  end

  # Bd P2 Slice S3: `ticket_close` — the ONE status->closed path (S1's
  # `ticket_update` still refuses `status` unconditionally; there is no
  # other way to close a ticket). Args: ticket id + `witnesses` (a list
  # of CANDIDATE proof cids, hex strings — the client proposes proofs,
  # it never gets to name requirements; the requirement is whatever
  # `done_when` already says on the ticket).
  #
  # Flow: require `status == "open"` -> dispatch on the ticket's OWN
  # `done_when` (`Commonplace.Bd.CloseGate.validate_witnesses/4`, which
  # resolves the witness list to write or a sanitized refusal) ->
  # `WriteGuard.check/5` with `allow: [:status, :done_witness]` (the
  # gate-exclusivity check every protected-field write goes through) ->
  # `Issue.close/4` writes `status: "closed"` + `done_witness` +
  # `closed_at` in ONE commit (one field-bag JSON write — see
  # `Issue.close/4`'s moduledoc). Close is invoker-signed like every
  # other ticket-mutating verb (`signing_opts(context)`); v1 has no
  # separate close-ACL — whoever can write the ticket (signed commit +
  # enforce-mode trust evaluation) may close it WITH valid witnesses.
  defp do_dispatch("ticket_close", %{args: %{"ticket" => ticket_id} = args} = context)
       when is_binary(ticket_id) do
    witnesses = Map.get(args, "witnesses", [])

    with {:ok, root_uuid} <- Workspace.root_uuid(),
         {:ok, issue} <- load_bd_issue(root_uuid, ticket_id),
         :ok <- require_ticket_open(issue),
         {:ok, done_witness} <-
           Commonplace.Bd.CloseGate.validate_witnesses(issue.done_when, witnesses, root_uuid, CommitStoreClient) do
      changes = %{status: "closed", done_witness: done_witness}

      case Commonplace.Bd.WriteGuard.check(issue, changes, root_uuid, CommitStoreClient,
             allow: [:status, :done_witness]
           ) do
        :ok ->
          close_opts = signing_opts(context) ++ [done_witness: done_witness]

          case Commonplace.Bd.Issue.close(root_uuid, ticket_id, close_opts, CommitStoreClient) do
            {:ok, updated} ->
              {:ok, :tree_mutation,
               %{
                 action: "ticket_close",
                 ticket: ticket_id,
                 status: updated.status,
                 done_witness: updated.done_witness
               }}

            {:error, reason} ->
              {:error, "ticket_close failed: #{inspect(reason)}"}
          end

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, "ticket_close failed: #{inspect(reason)}"}
    end
  end

  defp do_dispatch("ticket_close", _context) do
    {:error, "ticket_close requires args map with ticket (+ optional witnesses)"}
  end

  # Bd P2 Slice S4: `ticket_claim` / `ticket_release` — claim/release via
  # the GREEN possession token (`Commonplace.Green.Bursar`'s exclusive
  # custody lock), not presence. Claiming does NOT move the ticket (it
  # stays in `/bd/issues/`); it takes the custody token keyed on the
  # ticket's stable claim path (`Commonplace.Bd.Workspace.claim_path/3`,
  # derived from the issue-dir uuid, 1:1 with the ticket) and mirrors the
  # winning holder into `claimed_by` — a DISPLAY field only. The token is
  # authoritative: `Commonplace.Bd.Frontier.eligible/2` reads the token,
  # never `claimed_by`, and a stale `claimed_by` left over from a
  # force-released or expired token does not block a fresh claim (see
  # `Frontier.eligible/2`'s moduledoc).
  #
  # The claimer identity is resolved server-side from
  # `context.signing_context` (`resolve_principal/1`, the same helper
  # `pr_open`/`pr_comment` use) — NEVER a client-supplied arg, so a
  # caller can't claim a ticket "as" someone else. `authenticated_as` is
  # passed to the Bursar so the effective holder is bound to that
  # authenticated principal (CX-tdkq.32) — the same spoof-proofing
  # `Commonplace.MUD.World`/`HolderMove` rely on.
  defp do_dispatch("ticket_claim", %{args: %{"ticket" => ticket_id}} = context)
       when is_binary(ticket_id) do
    claimer = resolve_principal(context)

    with {:ok, root_uuid} <- Workspace.root_uuid(),
         {:ok, _issue} <- load_bd_issue(root_uuid, ticket_id),
         {:ok, claim_path} <- resolve_claim_path(root_uuid, ticket_id) do
      case Commonplace.Green.BursarClient.acquire(Commonplace.Green.Bursar, claim_path, claimer,
             authenticated_as: claimer
           ) do
        {:ok, _token_info} ->
          mirror_claimed_by(root_uuid, ticket_id, claimer, context, "ticket_claim")

        {:denied, %{holder: other}} ->
          {:error, "ticket already claimed by #{other}"}

        {:error, _reason} ->
          {:error, "ticket_claim failed: could not acquire claim token"}
      end
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, "ticket_claim failed: #{inspect(reason)}"}
    end
  end

  defp do_dispatch("ticket_claim", _context) do
    {:error, "ticket_claim requires args map with ticket"}
  end

  defp do_dispatch("ticket_release", %{args: %{"ticket" => ticket_id}} = context)
       when is_binary(ticket_id) do
    claimer = resolve_principal(context)

    with {:ok, root_uuid} <- Workspace.root_uuid(),
         {:ok, _issue} <- load_bd_issue(root_uuid, ticket_id),
         {:ok, claim_path} <- resolve_claim_path(root_uuid, ticket_id) do
      case Commonplace.Green.BursarClient.release(Commonplace.Green.Bursar, claim_path, claimer,
             authenticated_as: claimer
           ) do
        :ok ->
          mirror_claimed_by(root_uuid, ticket_id, nil, context, "ticket_release")

        {:error, {:not_holder, other}} ->
          {:error, "ticket is claimed by #{other}, not you"}

        {:error, :not_held} ->
          {:error, "ticket is not claimed"}

        {:error, _reason} ->
          {:error, "ticket_release failed: could not release claim token"}
      end
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, "ticket_release failed: #{inspect(reason)}"}
    end
  end

  defp do_dispatch("ticket_release", _context) do
    {:error, "ticket_release requires args map with ticket"}
  end

  # CX-6cz3 (tix-authority migration design §7, rulings @6418506) —
  # `ticket_create` / `ticket_import`: the GATED write surface for
  # ticket creation. Before this, creation had two doors and neither
  # went past `Commonplace.Bd.WriteGuard`: MCP `bd_create` ->
  # `Bd.Issue.create/4` (minted id), and `Bd.Importer`'s private
  # `create_with_fixed_id` (supplied id, raw store writes). The
  # cutover's single-write-path property is dishonest while either is
  # open, so both move here.
  #
  # `ticket_create`: args `title` (+ optional `type` / `priority` /
  # `description` / `done_when` / `needs`). The id is minted first
  # (`IdMint.mint_issue_id/3`, which probes for existence, so ids are
  # collision-proof by construction) so the CYCLE GATE sees the real
  # dependent id rather than a placeholder, and so create and import
  # share ONE write primitive (`Issue.create_with_id/5`).
  #
  # `status` is FORCED to "open": creation is not a close. There is
  # exactly one status->closed path (`ticket_close`, S3), and a create
  # verb that accepted `status: "closed"` would be a second one that
  # skips the close gate entirely. The guard would refuse it anyway
  # (`allow: []`), but refusing a value we should never have read from
  # the client is worse than never reading it.
  defp do_dispatch("ticket_create", %{args: args} = context) when is_map(args) do
    store = Map.get(context, :store) || CommitStoreClient

    with {:ok, title} <- fetch_arg(args, "title"),
         {:ok, root_uuid} <- resolve_bd_root(context),
         {:ok, meta} <- Commonplace.Bd.Workspace.load_meta(root_uuid, store),
         {:ok, id} <- Commonplace.Bd.IdMint.mint_issue_id(root_uuid, meta.prefix, store) do
      attrs = %{
        title: title,
        type: Map.get(args, "type") || "task",
        priority: Map.get(args, "priority") || "p2",
        status: "open",
        done_when: Map.get(args, "done_when") || "manual",
        needs: Map.get(args, "needs") || []
      }

      issue = Commonplace.Bd.Issue.build_with_id(id, attrs)

      case Commonplace.Bd.WriteGuard.check_create(issue, root_uuid, store, allow: []) do
        :ok ->
          {:ok, created, _dir} =
            Commonplace.Bd.Issue.create_with_id(
              root_uuid,
              issue,
              Map.get(args, "description") || "",
              store,
              signing_opts(context)
            )

          {:ok, :tree_mutation, %{action: "ticket_create", ticket: created.id, issue: created}}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, "ticket_create failed: #{inspect(reason)}"}
    end
  end

  defp do_dispatch("ticket_create", _context) do
    {:error, "ticket_create requires args map with title"}
  end

  # `ticket_import`: a BATCH of supplied-id records (`args["records"]`,
  # already-decoded bd records; `args["jsonl"]` is the convenience form,
  # parsed by `Bd.Importer.parse_records/1` — the same parser, kept as
  # pure transformation). Per record: no-op check, then the gate, then
  # the write. See `run_import_batch/4` for the reporting contract.
  defp do_dispatch("ticket_import", %{args: args} = context) when is_map(args) do
    store = Map.get(context, :store) || CommitStoreClient

    with {:ok, records, parse_refusals} <- import_records(args),
         {:ok, root_uuid} <- resolve_bd_root(context) do
      {:ok, :tree_mutation,
       run_import_batch(records, parse_refusals, root_uuid, store, signing_opts(context))}
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, "ticket_import failed: #{inspect(reason)}"}
    end
  end

  defp do_dispatch("ticket_import", _context) do
    {:error, "ticket_import requires args map with records (or jsonl)"}
  end

  # CX-xmsd — `ticket_comment` / `ticket_comments_import`: the GATED
  # write surface for COMMENTS, extending the CX-6cz3 pattern to the
  # one ticket-adjacent write path the cutover left open.
  #
  # Before this, the only comment doors were `Bd.Comment.add/4` (no
  # signing opts, unchecked results — every write denied under Mode-B
  # enforce while returning `{:ok, %Comment{}}`) and
  # `Bd.Importer.import_comments_jsonl/4` (same, plus it counted its own
  # attempts). The migration reported "failed: 0" and landed zero.
  #
  # WHY NO WriteGuard CALL HERE. The guard exists for the properties a
  # TICKET write can violate: protected fields (`status`,
  # `done_witness`, `claimed_by`), the `needs` cycle gate, and the
  # single status->closed path. A comment carries none of them — no
  # protected field, no graph edge, no close semantics — so there is
  # nothing for the guard to check, and inventing a call to it would be
  # a check that cannot fail, which reads as evidence and is not.
  # The §3 ruling scoped the single-write-path property to TICKET
  # writes; these two verbs extend the gated SURFACE to comments, which
  # is what lets that property drop its qualifier: the signing context
  # is server-resolved (`signing_opts/1`), the shape is checked here,
  # and the library below reports the store's answer instead of its own
  # intentions.
  defp do_dispatch("ticket_comment", %{args: args} = context) when is_map(args) do
    store = Map.get(context, :store) || CommitStoreClient

    with {:ok, ticket_id} <- fetch_arg(args, "ticket"),
         {:ok, body} <- fetch_comment_body(args),
         {:ok, root_uuid} <- resolve_bd_root(context),
         :ok <- require_ticket_exists(root_uuid, ticket_id, store) do
      attrs =
        %{body: body}
        |> put_optional_binary(args, "author", :author)
        |> put_optional_binary(args, "reply_to", :reply_to)
        |> put_optional_binary(args, "id", :id)
        |> put_optional_binary(args, "created_at", :created_at)

      case Commonplace.Bd.Comment.add(root_uuid, ticket_id, attrs, store, signing_opts(context)) do
        {:ok, :noop} ->
          {:ok, :tree_mutation,
           %{action: "ticket_comment", ticket: ticket_id, comment: nil, op: :noop}}

        {:ok, comment} ->
          {:ok, :tree_mutation,
           %{action: "ticket_comment", ticket: ticket_id, comment: comment, op: :created}}

        {:error, reason} ->
          {:error, "ticket_comment failed: #{inspect(reason)}"}
      end
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, "ticket_comment failed: #{inspect(reason)}"}
    end
  end

  defp do_dispatch("ticket_comment", _context) do
    {:error, "ticket_comment requires args map with ticket + body"}
  end

  # `ticket_comments_import`: a batch, ONE TICKET PER DISPATCH.
  #
  # CX-hfxr's lesson, applied: the 524-record mega-batch cost a timeout
  # and certified nothing. Work per call is bounded by one ticket's
  # comment list (the archive's worst ticket carries a handful), so a
  # failure costs one ticket's retry rather than the whole run's
  # accounting.
  defp do_dispatch("ticket_comments_import", %{args: args} = context) when is_map(args) do
    store = Map.get(context, :store) || CommitStoreClient

    with {:ok, ticket_id} <- fetch_arg(args, "ticket"),
         {:ok, records} <- fetch_comment_records(args),
         {:ok, root_uuid} <- resolve_bd_root(context),
         :ok <- require_ticket_exists(root_uuid, ticket_id, store) do
      {:ok, :tree_mutation,
       run_comment_import_batch(ticket_id, records, root_uuid, store, signing_opts(context))}
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, "ticket_comments_import failed: #{inspect(reason)}"}
    end
  end

  defp do_dispatch("ticket_comments_import", _context) do
    {:error, "ticket_comments_import requires args map with ticket + records"}
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

  # --- ticket_add_needs / ticket_update / ticket_close helpers (Bd P2 S1 Part 4 / S3) ---

  # `ticket_close`'s status precondition: only an "open" ticket may be
  # closed (S3's close is the ONE status->closed path; there is no
  # reopen in v1, so a "closed" or any other status is refused, not
  # just "closed").
  defp require_ticket_open(%Commonplace.Bd.Schemas.Issue{status: "open"}), do: :ok
  defp require_ticket_open(%Commonplace.Bd.Schemas.Issue{}), do: {:error, "ticket is not open"}

  defp load_bd_issue(root_uuid, ticket_id) do
    case Commonplace.Bd.Workspace.issue_dir_uuid(root_uuid, ticket_id) do
      {:ok, dir_uuid} -> Commonplace.Bd.Schemas.load_issue(dir_uuid)
      :error -> {:error, "ticket not found: #{ticket_id}"}
    end
  end

  # `ticket_claim`/`ticket_release` helpers (Bd P2 S4) — resolve the
  # ticket's stable claim path and land the guarded `claimed_by` mirror
  # write through the same `WriteGuard.check/5` chokepoint every other
  # protected-field write goes through (`allow: [:claimed_by]`).
  defp resolve_claim_path(root_uuid, ticket_id) do
    case Commonplace.Bd.Workspace.claim_path(root_uuid, ticket_id) do
      {:ok, path} -> {:ok, path}
      :error -> {:error, "ticket not found: #{ticket_id}"}
    end
  end

  defp mirror_claimed_by(root_uuid, ticket_id, claimed_by, context, action) do
    with {:ok, issue} <- load_bd_issue(root_uuid, ticket_id) do
      changes = %{claimed_by: claimed_by}

      case Commonplace.Bd.WriteGuard.check(issue, changes, root_uuid, CommitStoreClient,
             allow: [:claimed_by]
           ) do
        :ok ->
          opts = signing_opts(context)

          case Commonplace.Bd.Issue.update(root_uuid, ticket_id, changes, CommitStoreClient, opts) do
            {:ok, _updated} ->
              {:ok, :tree_mutation, %{action: action, ticket: ticket_id, claimed_by: claimed_by}}

            {:error, reason} ->
              {:error, "#{action} failed: #{inspect(reason)}"}
          end

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, "#{action} failed: #{inspect(reason)}"}
    end
  end

  # --- ticket_comment / ticket_comments_import helpers (CX-xmsd) ---

  # The body is CLIENT DATA and is shape-checked here rather than
  # coerced: `to_string/1` on a number or a map would land a comment
  # nobody wrote. Empty is refused for the same reason the normalizer
  # refuses it — an empty body cannot be told apart from a dropped one.
  defp fetch_comment_body(args) do
    case Map.get(args, "body") do
      body when is_binary(body) and body != "" -> {:ok, body}
      "" -> {:error, "ticket_comment requires a non-empty body"}
      nil -> {:error, "ticket_comment requires args map with ticket + body"}
      other -> {:error, "ticket_comment body must be a string, got #{inspect(other)}"}
    end
  end

  defp fetch_comment_records(%{"records" => records}) when is_list(records), do: {:ok, records}

  defp fetch_comment_records(_),
    do: {:error, "ticket_comments_import requires args map with ticket + records (a list)"}

  defp put_optional_binary(attrs, args, arg_key, attr_key) do
    case Map.get(args, arg_key) do
      v when is_binary(v) and v != "" -> Map.put(attrs, attr_key, v)
      _ -> attrs
    end
  end

  # A comment on a ticket that does not exist would attach to nothing
  # (or, worse, to a stale dir uuid). Checked BEFORE any write, and
  # store-aware so in-process callers driving their own workspace get
  # the same check.
  defp require_ticket_exists(root_uuid, ticket_id, store) do
    case Commonplace.Bd.Workspace.issue_dir_uuid(root_uuid, ticket_id, store) do
      {:ok, dir_uuid} ->
        case Commonplace.Bd.Schemas.load_issue(dir_uuid, store) do
          {:ok, _issue} -> :ok
          {:error, reason} -> {:error, "ticket not readable: #{ticket_id} (#{inspect(reason)})"}
        end

      :error ->
        {:error, "ticket not found: #{ticket_id}"}
    end
  end

  # The SAME declared-denominator contract `run_import_batch/5` holds,
  # for comments: `declared` is built from what ARRIVED (the records
  # list as supplied), never from what survived normalization, and
  # `landed + noop + refused == declared` is checked HERE, at runtime,
  # not only in a test. `unaccounted` carries the names that fell
  # through; the identity is also asserted on the COUNTS, because two
  # records can share a declared name (a duplicate id in one batch) and
  # a set difference alone would call that accounted for.
  #
  # `{:ok, :noop}` from `Comment.add/5` is the idempotent re-run: the
  # comment is already stored with byte-identical content. It is NOT
  # counted as landed — landed means this call wrote it — and it is not
  # a refusal either, so it gets its own bucket, the same way
  # `ticket_import` treats a byte-identical record.
  defp run_comment_import_batch(ticket_id, records, root_uuid, store, opts) do
    declared_ids =
      records |> Enum.with_index() |> Enum.map(fn {r, i} -> declared_comment_id(r, i) end)

    {landed, refused, noop} =
      records
      |> Enum.with_index()
      |> Enum.reduce({[], [], []}, fn {record, idx}, acc ->
        import_one_comment(record, idx, ticket_id, root_uuid, store, opts, acc)
      end)

    landed = Enum.reverse(landed)
    refused = Enum.reverse(refused)
    noop = Enum.reverse(noop)

    accounted =
      MapSet.new(Enum.map(landed, & &1.id) ++ Enum.map(refused, & &1.id) ++ noop)

    counted = length(landed) + length(refused) + length(noop)

    %{
      action: "ticket_comments_import",
      ticket: ticket_id,
      declared: length(declared_ids),
      declared_ids: declared_ids,
      landed: landed,
      refused: refused,
      noop: noop,
      unaccounted:
        MapSet.difference(MapSet.new(declared_ids), accounted) |> MapSet.to_list() |> Enum.sort(),
      identity_holds?: counted == length(declared_ids)
    }
  end

  defp declared_comment_id(record, idx) when is_map(record) do
    case Map.get(record, "id") do
      id when is_binary(id) and id != "" -> id
      _ -> "<comment ##{idx}: no id>"
    end
  end

  defp declared_comment_id(_record, idx), do: "<comment ##{idx}: no id>"

  # Same per-record boundary as `import_one/6`, and for the same
  # reason: the write path under this can raise or exit (store reads
  # inside the library carry `{:ok, _} = ...` matches), and an uncaught
  # one would take the whole batch report with it.
  defp import_one_comment(record, idx, ticket_id, root_uuid, store, opts, {landed, refused, noop}) do
    try do
      do_import_one_comment(record, idx, ticket_id, root_uuid, store, opts, {landed, refused, noop})
    rescue
      e ->
        {landed,
         [
           %{id: declared_comment_id(record, idx), reason: "write failed: #{Exception.message(e)}"}
           | refused
         ], noop}
    catch
      :exit, reason ->
        {landed,
         [
           %{
             id: declared_comment_id(record, idx),
             reason: "write failed: exited with #{inspect(reason)}"
           }
           | refused
         ], noop}
    end
  end

  defp do_import_one_comment(
         record,
         idx,
         ticket_id,
         root_uuid,
         store,
         opts,
         {landed, refused, noop}
       ) do
    name = declared_comment_id(record, idx)

    case Commonplace.Bd.Importer.normalize_comment_record(record) do
      {:ok, attrs, _id} ->
        case Commonplace.Bd.Comment.add(root_uuid, ticket_id, attrs, store, opts) do
          {:ok, :noop} ->
            {landed, refused, [name | noop]}

          {:ok, comment} ->
            # Keyed by the DECLARED name, not the stored id: a record
            # that supplied no id is declared as "<comment #N: no id>"
            # and gets a minted id, and keying on the minted one would
            # leave its declared name unaccounted for.
            {[%{id: name, comment_id: comment.id} | landed], refused, noop}

          {:error, reason} ->
            {landed, [%{id: name, reason: "comment write refused: #{inspect(reason)}"} | refused],
             noop}
        end

      {:error, reason} ->
        {landed, [%{id: name, reason: "cannot import comment record: #{inspect(reason)}"} | refused],
         noop}
    end
  end

  # --- ticket_create / ticket_import helpers (CX-6cz3) ---

  # The bd root. Every other ticket verb reads
  # `Commonplace.Workspace.root_uuid/0`; these two additionally honor
  # a CONTEXT-supplied root/store so in-process callers
  # (`Bd.Importer`, the CLI, tests) can drive the gated path against
  # their own workspace. Context is assembled by the calling CODE —
  # unlike `args`, which is client data — so this is not a
  # client-steerable knob.
  defp resolve_bd_root(context) do
    case Map.get(context, :root_uuid) do
      root when is_binary(root) -> {:ok, root}
      _ -> Workspace.root_uuid()
    end
  end

  # RULED (CX-6cz3 build condition 1): import's declared allow posture
  # is ENUMERATED from the tix record spec (`Commonplace.Bd.Schemas.Issue`),
  # never inferred from whatever fields the migrating records happen to
  # carry — pins-from-spec, not-from-diff. These are the spec fields an
  # import is permitted to assert because a bd record legitimately
  # carries them:
  #
  #   :status         — a bd ticket may already be closed/in_progress.
  #   :closed_at      — the bd close timestamp.
  #   :closed_reason  — the bd close reason.
  #   :done_witness   — a witness list carried by an already-closed record.
  #   :claimed_by     — the display mirror of a bd assignee/claim.
  #
  # Everything else protected stays refused. NOTE (reviewed, not an
  # oversight): only `:status`, `:done_witness` and `:claimed_by` are in
  # `WriteGuard.protected_fields/0` today — `:closed_at` /
  # `:closed_reason` are declarative entries here, listing what an
  # import may carry per the spec, and are inert until/unless the
  # protected set widens. `Commonplace.Bd.TicketCreateImportVerbsTest`
  # asserts the enforced intersection, so a widening turns red here
  # rather than silently admitting a newly-protected field.
  @import_allow_posture [:status, :closed_at, :closed_reason, :done_witness, :claimed_by]

  @doc """
  The enumerated allow posture `ticket_import` declares (CX-6cz3
  build condition 1). Public so it is reviewable and testable as
  DATA rather than inferred from behavior.
  """
  @spec import_allow_posture() :: [atom()]
  def import_allow_posture, do: @import_allow_posture

  # Returns `{:ok, records, parse_refusals}`. For the `records` form
  # there is nothing to parse, so there are never any parse refusals —
  # the caller supplied decoded maps and every one of them is a declared
  # input already.
  defp import_records(%{"records" => records}) when is_list(records), do: {:ok, records, []}

  # For the `jsonl` form the DECLARED INPUT IS THE LINE, not the record
  # that survived parsing. `parse_records/1` reports per-line failures;
  # discarding them made the union invariant hold VACUOUSLY — a
  # malformed line never entered `declared_ids`, so "every input
  # accounted for" silently meant "every input we could parse accounted
  # for". That is the same silent drop ruling (b) forbids, just moved
  # earlier than the gate. Each parse failure becomes a NAMED refusal,
  # in the same shape as an id-less record's, and enters the
  # denominator.
  defp import_records(%{"jsonl" => jsonl}) when is_binary(jsonl) do
    {records, parse_errors} = Commonplace.Bd.Importer.parse_records(jsonl)
    {:ok, records, Enum.map(parse_errors, &parse_refusal/1)}
  end

  defp import_records(_), do: {:error, "ticket_import requires args map with records (or jsonl)"}

  defp parse_refusal({line, {:bad_json, detail}}) do
    %{line: line, id: "<line #{line}: bad json>", reason: "cannot parse line as JSON: #{detail}"}
  end

  defp parse_refusal({line, :malformed_line}) do
    %{
      line: line,
      id: "<line #{line}: not a JSON object>",
      reason: "line parsed as JSON but is not an object"
    }
  end

  defp parse_refusal({line, other}) do
    %{line: line, id: "<line #{line}: unparseable>", reason: "cannot parse line: #{inspect(other)}"}
  end

  # RULED reporting shape (CX-6cz3, ruling (b) + boss's denominator
  # rider): the batch DECLARES its expected-landed set — the declared
  # input, named — before it runs, and reports landed / refused / noop
  # against that denominator. `unaccounted` is the acceptance property
  # made checkable at runtime rather than only in a test: LANDED ∪
  # REFUSED ∪ NOOP must equal the declared input set. A refused record
  # is a named TODO, never a smaller denominator, and a refusal on
  # record N does NOT abort the batch.
  # `parse_refusals` are inputs that never became records at all (see
  # `import_records/1`). They are seeded into BOTH the denominator and
  # `refused` before the first record is touched, so a line that could
  # not be parsed is a named TODO exactly like a record the gate turned
  # down.
  defp run_import_batch(records, parse_refusals, root_uuid, store, opts) do
    indexed = Enum.with_index(records)
    declared_ids = declared_list(records, parse_refusals)

    seed = {[], parse_refusals |> Enum.map(&Map.take(&1, [:id, :reason])) |> Enum.reverse(), []}

    {landed, refused, noop} =
      Enum.reduce(indexed, seed, fn {record, idx}, acc ->
        import_one(record, idx, root_uuid, store, opts, acc)
      end)

    landed = Enum.reverse(landed)
    refused = Enum.reverse(refused)
    noop = Enum.reverse(noop)

    accounted =
      MapSet.new(Enum.map(landed, & &1.id) ++ Enum.map(refused, & &1.id) ++ noop)

    %{
      action: "ticket_import",
      declared: length(declared_ids),
      declared_ids: declared_ids,
      landed: landed,
      refused: refused,
      noop: noop,
      unaccounted:
        MapSet.difference(MapSet.new(declared_ids), accounted) |> MapSet.to_list() |> Enum.sort()
    }
  end

  # The declared input set, IN INPUT ORDER. Parse refusals carry the
  # line they failed on, and the surviving records are in line order, so
  # walking the line numbers interleaves the two back into the original
  # sequence — a 500-line report reads in the order the file did rather
  # than putting all the casualties at the top. With no parse refusals
  # (the `records` form) this is exactly `declared_id/2` over the
  # records, unchanged.
  defp declared_list(records, []), do: records |> Enum.with_index() |> Enum.map(fn {r, i} -> declared_id(r, i) end)

  defp declared_list(records, parse_refusals) do
    by_line = Map.new(parse_refusals, fn r -> {r.line, r.id} end)
    total = length(records) + length(parse_refusals)

    {ids, _leftover} =
      Enum.reduce(0..(total - 1)//1, {[], records}, fn line, {acc, rest} ->
        case Map.fetch(by_line, line) do
          {:ok, id} ->
            {[id | acc], rest}

          :error ->
            case rest do
              [record | tail] -> {[declared_id(record, line) | acc], tail}
              [] -> {acc, []}
            end
        end
      end)

    Enum.reverse(ids)
  end

  # A record with no usable id still gets a NAME in the denominator —
  # otherwise "every input accounted for" degrades into "every input
  # we could name accounted for", which is the silent drop the rider
  # exists to forbid.
  defp declared_id(record, idx) when is_map(record) do
    case Map.get(record, "id") do
      id when is_binary(id) and id != "" -> id
      _ -> "<record ##{idx}: no id>"
    end
  end

  defp declared_id(_record, idx), do: "<record ##{idx}: no id>"

  # THE PER-RECORD BOUNDARY. The ruled contract is "a refusal on record
  # N does not abort the batch; LANDED ∪ REFUSED ∪ NOOP == declared" —
  # and that has to hold when a WRITE BLOWS UP, not just when the gate
  # says no. The write path below it can raise (`Issue.create_with_id/5`
  # and `Schemas.write_text_doc/4` both carry `{:ok, _} = ...` matches
  # over store reads, so a dead or denying store surfaces as a
  # MatchError or a GenServer exit, never as an `{:error, _}` return).
  # Un-caught, any of those takes down the whole dispatch and the batch
  # report with it — every record that already landed loses its
  # accounting.
  #
  # So the boundary is here, around the whole per-record attempt: a
  # raise or an exit becomes a NAMED refusal for THAT record and the
  # batch continues. Proven load-bearing by removing it: the
  # blows-up-mid-batch test then dies with the raw
  # `Protocol.UndefinedError` and no report at all.
  defp import_one(record, idx, root_uuid, store, opts, {landed, refused, noop}) do
    try do
      do_import_one(record, idx, root_uuid, store, opts, {landed, refused, noop})
    rescue
      e ->
        {landed,
         [%{id: declared_id(record, idx), reason: "write failed: #{Exception.message(e)}"} | refused],
         noop}
    catch
      :exit, reason ->
        {landed,
         [
           %{id: declared_id(record, idx), reason: "write failed: exited with #{inspect(reason)}"}
           | refused
         ], noop}
    end
  end

  defp do_import_one(record, idx, root_uuid, store, opts, {landed, refused, noop}) do
    case Commonplace.Bd.Importer.normalize_record(record) do
      {:ok, attrs, id} ->
        case Commonplace.Bd.Issue.show(root_uuid, id, store) do
          {:ok, current} ->
            import_existing(record, current, id, attrs, root_uuid, store, opts, {landed, refused, noop})

          {:error, _not_found} ->
            import_absent(record, id, attrs, root_uuid, store, opts, {landed, refused, noop})
        end

      {:error, reason} ->
        {landed,
         [%{id: declared_id(record, idx), reason: "cannot import record: #{inspect(reason)}"} | refused],
         noop}
    end
  end

  # Absent -> CREATE through `WriteGuard.check_create/4` (every initial
  # `needs` edge walks the cycle gate) then the one supplied-id write
  # primitive, carrying the provenance stamp and — for a closed record
  # — the freeze pin.
  defp import_absent(record, id, attrs, root_uuid, store, opts, {landed, refused, noop}) do
    issue = Commonplace.Bd.Issue.build_with_id(id, attrs)

    description = Map.get(attrs, :description) || ""

    case Commonplace.Bd.WriteGuard.check_create(issue, root_uuid, store, allow: @import_allow_posture) do
      :ok ->
        write_opts = opts ++ [commit_metadata: import_commit_metadata(record, issue, description)]

        # `create_with_id/5` has NO representable failure return today —
        # the compiler's type checker rejects an `{:error, _}` clause
        # here as unreachable, because every failure inside it (a dead
        # store, a denied write, an unencodable field) surfaces as a
        # raise or a GenServer exit, not a value. So this branch's
        # failure handling lives at `import_one/6`'s per-record
        # try/rescue/catch boundary, which turns any of those into a
        # NAMED refusal for this record and lets the batch continue.
        #
        # This stays a `case` with a single clause rather than a bare
        # match so that IF the primitive's contract ever widens to return
        # a value, the mismatch raises a CaseClauseError the same
        # boundary catches — the record is refused, not silently counted
        # as landed, and the batch report survives either way.
        case Commonplace.Bd.Issue.create_with_id(root_uuid, issue, description, store, write_opts) do
          {:ok, _created, _dir} ->
            {[%{id: id, op: :created} | landed], refused, noop}
        end

      {:error, reason} ->
        {landed, [%{id: id, reason: reason} | refused], noop}
    end
  end

  # Present -> byte-identical NO-OP check first, then the gate.
  #
  # RULED (build condition 2): the no-op test is CONTENT-HASH EQUALITY
  # against the stored record, nothing weaker — a no-op skips the write
  # AND the gate, so a bug in this comparison is a gate bypass. Both
  # sides are hashed through `Schemas.canonical_issue_json/1`, the same
  # deterministic encoding the terminal pin uses (raw `encode_issue/1`
  # bytes depend on Erlang map iteration order, which is not a contract
  # and would make "byte-identical" mean "identical this run").
  #
  # The proposed state is derived with `Issue.apply_attrs/2` — the SAME
  # function `Issue.update/5` applies — so "what would be stored" cannot
  # drift from what is stored. `updated_at` is excluded from the delta
  # (it has no update clause; `update/5` re-stamps it itself), which
  # means a ticket edited locally since import will hash-differ and go
  # THROUGH the gate. That direction is the safe one: false negatives
  # cost a redundant guarded write, false positives would skip the gate.
  defp import_existing(record, current, id, attrs, root_uuid, store, opts, {landed, refused, noop}) do
    changes =
      attrs
      # `description` lives in a sibling doc, not the field bag; passing
      # it as a change would bury it in `extra`. It is compared and
      # written separately, below.
      |> Map.drop([:description, :created_at, :updated_at])
      |> Map.take(Commonplace.Bd.Issue.writable_fields())

    proposed = Commonplace.Bd.Issue.apply_attrs(current, changes)

    current_description =
      case Commonplace.Bd.Issue.description(root_uuid, id, store) do
        {:ok, body} -> body
        _ -> ""
      end

    # A record that says nothing about the description proposes the
    # current one — present-key semantics, so a field-only record can
    # never blank a body (and can never be dragged out of no-op by one).
    proposed_description = Map.get(attrs, :description, current_description)

    if content_hash(proposed, proposed_description) == content_hash(current, current_description) do
      {landed, refused, [id | noop]}
    else
      # Only the fields that actually DIFFER are proposed to the gate:
      # a closed ticket re-imported with an unchanged `status` must not
      # trip the post-close freeze on a value it isn't changing.
      delta = Map.filter(changes, fn {k, v} -> Map.fetch!(current, k) != v end)

      case Commonplace.Bd.WriteGuard.check(current, delta, root_uuid, store,
             allow: @import_allow_posture
           ) do
        :ok ->
          write_opts = opts ++ [commit_metadata: import_commit_metadata(record, proposed, proposed_description)]

          case Commonplace.Bd.Issue.update(root_uuid, id, delta, store, write_opts) do
            {:ok, _updated} ->
              # The description is a SECOND doc, so this record can land
              # by halves. If the body write fails after the field bag
              # landed, the record is REFUSED — reporting `op: :updated`
              # would call a partial landing a full one — and the reason
              # states the partiality honestly rather than implying the
              # field write was rolled back (it was not; there is no
              # transaction across two docs here).
              case write_description_if_changed(
                     root_uuid,
                     id,
                     proposed_description,
                     current_description,
                     store,
                     opts
                   ) do
                :ok ->
                  {[%{id: id, op: :updated} | landed], refused, noop}

                {:error, reason} ->
                  {landed,
                   [
                     %{
                       id: id,
                       reason:
                         "PARTIAL landing: field update landed, description write failed " <>
                           "(#{inspect(reason)}) — the stored body is still the old one"
                     }
                     | refused
                   ], noop}
              end

            {:error, reason} ->
              {landed, [%{id: id, reason: "write failed: #{inspect(reason)}"} | refused], noop}
          end

        {:error, reason} ->
          {landed, [%{id: id, reason: reason} | refused], noop}
      end
    end
  end

  defp write_description_if_changed(_root, _id, same, same, _store, _opts), do: :ok

  defp write_description_if_changed(root_uuid, id, proposed, _current, store, opts) do
    case Commonplace.Bd.Issue.write_description(root_uuid, id, proposed, store, opts) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_result, other}}
    end
  end

  # The ticket's full stored content: the canonical field bag PLUS the
  # description doc's bytes (a description is stored content too — a
  # no-op check that ignored it would skip a real change).
  defp content_hash(%Commonplace.Bd.Schemas.Issue{} = issue, description) do
    :crypto.hash(
      :sha256,
      Commonplace.Bd.Schemas.canonical_issue_json(issue) <> "\n" <> description
    )
    |> Base.encode16(case: :lower)
  end

  # RULED (c): every import commit carries the derivation record —
  # `source=bd`, a content hash of the SOURCE record (`sources_pin`),
  # the transform that produced it, and a hash of the OUTPUT state — so
  # the drift scanner and the round-trip check share one anchor. It
  # rides the `__issue.json` commit's `metadata`, which is
  # content-addressed and covered by the signer's signature, exactly
  # like the pr-provenance stamp and the terminal pin.
  #
  # RULED (a): an imported CLOSED ticket is pinned at import, and the
  # pin attests the state AS ADMITTED AT IMPORT — not bd's original
  # close, which is what the provenance stamp above is for. It is minted
  # by `Issue.terminal_pin_metadata/1`, the SAME function `ticket_close`
  # stamps through; there is no code-level pause knob on either (the
  # standing "validator to main, deploy to fleet, then pin resumes" rule
  # is operational), so import inherits close's condition exactly by
  # riding close's mechanism.
  defp import_commit_metadata(record, %Commonplace.Bd.Schemas.Issue{} = issue, description) do
    stamp = %{
      "source" => "bd",
      "sources_pin" => raw_record_hash(record),
      "transform" => "Commonplace.ViewActionDispatch ticket_import (CX-6cz3)",
      "output" => content_hash(issue, description),
      "imported_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    base = %{kind: :regular, bd_import: stamp}

    if issue.status == "closed" do
      Map.merge(base, Commonplace.Bd.Issue.terminal_pin_metadata(issue))
    else
      base
    end
  end

  defp raw_record_hash(record) do
    :crypto.hash(:sha256, Commonplace.Bd.Schemas.canonical_json(record))
    |> Base.encode16(case: :lower)
  end

  defp build_need_ref(prereq_id, nil), do: %{"ticket" => prereq_id}
  defp build_need_ref(prereq_id, ""), do: %{"ticket" => prereq_id}
  defp build_need_ref(prereq_id, repo) when is_binary(repo), do: %{"ticket" => prereq_id, "repo" => repo}

  # Whitelist of `ticket_update` field names — mirrors
  # `Commonplace.Bd.Issue.apply_update_field/3`'s explicit clauses
  # (everything else there falls into `extra`, which this verb
  # deliberately does not expose). `String.to_existing_atom/1` is safe
  # here because every name is already a `Schemas.Issue` struct field.
  @ticket_update_fields ~w(title status priority type owner labels needs done_when done_witness claimed_by legacy_id)

  defp atomize_ticket_changes(map) do
    map
    |> Enum.filter(fn {k, _v} -> k in @ticket_update_fields end)
    |> Enum.into(%{}, fn {k, v} -> {String.to_existing_atom(k), v} end)
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
  defp attach_to_root_schema(new_uuid, attach_name, opts) do
    with {:ok, root_uuid} <- Workspace.root_uuid(),
         {:ok, root_doc} <- load_root_schema(root_uuid) do
      updated = Schema.add_file(root_doc, attach_name, new_uuid)
      update_binary = Encoding.encode_update(updated)

      try do
        # CX-ajdx: signed like pr_open's attach_entry (explicit
        # CommitStoreClient server arg + metadata + opts) so it lands under
        # enforce; opts carries the invoker's :signing_context.
        case CommitStoreClient.create_chained_commit(
               CommitStoreClient,
               root_uuid,
               update_binary,
               %{},
               opts
             ) do
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

  # --- pr_open helpers (§7.0 registry + §7.2 verb) ---

  @pulls_dir_name "__pulls"
  @uuid_re ~r/^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/

  # `args["target"]` may be a bare uuid or a repo-root path. A path is
  # resolved through the same tree-walk every other path-taking verb
  # uses (`Commonplace.Tree.Lookup.lookup_doc_by_path/3`), rooted at
  # the workspace root schema.
  defp resolve_pr_target(args) do
    with {:ok, target} <- fetch_arg(args, "target") do
      if uuid_like?(target) do
        {:ok, target}
      else
        with {:ok, root_uuid} <- Workspace.root_uuid(),
             {:ok, uuid} <- Lookup.lookup_doc_by_path(root_uuid, target) do
          {:ok, uuid}
        else
          {:error, :not_found} -> {:error, "target path not found: #{target}"}
          {:error, reason} -> {:error, "target path resolution failed: #{inspect(reason)}"}
        end
      end
    end
  end

  defp uuid_like?(value) when is_binary(value), do: Regex.match?(@uuid_re, value)
  defp uuid_like?(_), do: false

  # Designer ruling (§7.2): unconditional on every path, whether target
  # arrived as a uuid or a path — `:none` is the one hard stop.
  defp validate_common_ancestor(target_uuid, source_uuid) do
    case CommitStoreClient.find_common_ancestor(target_uuid, source_uuid) do
      :none -> {:error, :no_common_ancestor}
      {:ok, commit} -> {:ok, commit}
    end
  end

  # §6.3/§6.4: the invoking principal is derived server-side from the
  # dispatch's signing plumbing, never from a client-supplied arg —
  # mirrors `InvokeViewAction.derive_signer_id/1`'s pattern of reading
  # straight off `signing_context.identity_uuid`/`public_key` rather
  # than trusting a separately-threaded string.
  defp resolve_principal(context) do
    case Map.get(context, :signing_context) do
      %Commonplace.Crypto.SigningContext{identity_uuid: id, public_key: pub} ->
        Signing.signer_id(id, pub)

      _ ->
        Map.get(context, :signer_id) || "anonymous@local"
    end
  end

  defp signing_opts(context) do
    case Map.get(context, :signing_context) do
      nil -> []
      ctx -> [signing_context: ctx]
    end
  end

  # `__pulls/` is a schema dir attached at the workspace root,
  # created on first use (idempotent: entry-presence check), via the
  # same attach move `attach_to_root_schema/2` uses for fork.
  defp ensure_pulls_dir(opts) do
    with {:ok, root_uuid} <- Workspace.root_uuid(),
         {:ok, root_doc} <- load_root_schema(root_uuid) do
      case Schema.get_entry(root_doc, @pulls_dir_name) do
        {:ok, entry} ->
          {:ok, entry.node_id}

        :error ->
          pulls_uuid = UUID.uuid4()
          dir_doc = Schema.new_schema()
          dir_update = Encoding.encode_update(dir_doc)

          with {:ok, _commit} <-
                 ok_commit(
                   CommitStoreClient.create_commit(
                     CommitStoreClient,
                     pulls_uuid,
                     dir_update,
                     nil,
                     %{},
                     opts
                   )
                 ) do
            updated_root = Schema.add_directory(root_doc, @pulls_dir_name, pulls_uuid)
            root_update = Encoding.encode_update(updated_root)

            case ok_commit(
                   CommitStoreClient.create_chained_commit(
                     CommitStoreClient,
                     root_uuid,
                     root_update,
                     %{},
                     opts
                   )
                 ) do
              {:ok, _commit} -> {:ok, pulls_uuid}
              {:error, _} = err -> err
            end
          end
      end
    end
  end

  # PR doc = a `<view>` doc per the design doc §1 template, freshly
  # minted (never chained — every PR gets a brand new uuid).
  defp create_pr_doc(source_uuid, target_uuid, base_hex, opened_by, opts) do
    pr_uuid = UUID.uuid4()

    content =
      Template.render(%{
        source: source_uuid,
        target: target_uuid,
        base: base_hex,
        status: :open,
        opened_by: opened_by
      })

    doc = ContentType.create(Yelixer.Doc.new(), :text, "pr.xml")
    doc = ContentType.insert_text(doc, 0, content)
    update = Encoding.encode_update(doc)

    case ok_commit(
           CommitStoreClient.create_commit(CommitStoreClient, pr_uuid, update, nil, %{}, opts)
         ) do
      {:ok, _commit} -> {:ok, pr_uuid}
      {:error, _} = err -> err
    end
  end

  # Attach `child_uuid` under `parent_uuid`'s schema as `attach_name`.
  # Same move as `attach_to_root_schema/2`, generalized to any schema
  # parent (here, the `__pulls/` dir rather than the workspace root)
  # and threaded with the invoker's signing opts.
  defp attach_entry(parent_uuid, attach_name, child_uuid, opts) do
    with {:ok, parent_doc} <- load_root_schema(parent_uuid) do
      updated = Schema.add_file(parent_doc, attach_name, child_uuid)
      update_binary = Encoding.encode_update(updated)

      case ok_commit(
             CommitStoreClient.create_chained_commit(
               CommitStoreClient,
               parent_uuid,
               update_binary,
               %{},
               opts
             )
           ) do
        {:ok, _commit} -> :ok
        {:error, _} = err -> err
      end
    end
  end

  defp ok_commit({:error, _} = err), do: err
  defp ok_commit(commit), do: {:ok, commit}

  # --- pr_refresh_preview helpers (§7.3) ---

  # CX-41qg.3: fetch the PR doc via the FULL-chain reconstructor
  # (`reconstruct_doc/2`, not `reconstruct_snapshot/2` — the PR doc's
  # commit chain isn't guaranteed to be all self-contained-snapshot
  # commits the way `reconstruct_snapshot/2`'s "latest commit only"
  # shortcut assumes) with a STABLE client_id, since this same `doc`
  # gets re-diffed and re-committed below (`commit_preview_section/4`)
  # — without a fixed hand every refresh would mint a fresh random
  # client_id and bloat the doc's state vector one slot per refresh.
  defp reconstruct_pr_doc(pr_uuid) do
    case DocBuilder.reconstruct_doc(CommitStoreClient, pr_uuid, client_id: WriterHand.for_doc(pr_uuid)) do
      {:ok, doc} -> {:ok, doc}
      :none -> {:error, "PR doc not found: #{pr_uuid}"}
    end
  end

  @pr_tag_re ~r/<pr\b([^>]*?)\/>/s

  # Read `source`/`target`/`status`/`opened_by` back off the PR doc's OWN
  # `<pr .../>` element. Per the module moduledoc's §6.3 note: fine for
  # ROUTING (which two docs does this preview diff? who opened it, for
  # the §7.4 decline-opener check?), never for authorization — the
  # opener check (`opener_may_decline?/2`) additionally requires the
  # CURRENT session to independently prove the same signing-context
  # identity, so a merely-recorded `opened_by` alone never grants
  # anything.
  defp parse_pr_attrs(content) do
    case Regex.run(@pr_tag_re, content) do
      [_, attrs_str] ->
        attrs = %{
          source: pr_attr(attrs_str, "source"),
          target: pr_attr(attrs_str, "target"),
          status: pr_attr(attrs_str, "status"),
          opened_by: pr_attr(attrs_str, "opened_by")
        }

        if is_binary(attrs.source) and is_binary(attrs.target) do
          {:ok, attrs}
        else
          {:error, "PR doc <pr> element missing source/target attributes"}
        end

      nil ->
        {:error, "PR doc has no <pr> element"}
    end
  end

  defp pr_attr(attrs_str, name) do
    case Regex.run(~r/\b#{name}="([^"]*)"/, attrs_str) do
      [_, value] -> unescape_attr(value)
      nil -> nil
    end
  end

  defp unescape_attr(value) do
    value
    |> String.replace("&quot;", "\"")
    |> String.replace("&gt;", ">")
    |> String.replace("&lt;", "<")
    |> String.replace("&amp;", "&")
  end

  defp require_open(%{status: "open"}), do: :ok
  defp require_open(_attrs), do: {:error, "PR is not open"}

  # The three tree-mutating/reading steps of §7.3, run only once the PR
  # doc has confirmed `status="open"`: derive a fresh preview (scratch-
  # fork the target, merge source into the scratch, project + hash),
  # then commit it into the PR doc's preview section. Split out of the
  # dispatch clause so the `with`-chain above stays flat.
  defp refresh_preview(
         pr_uuid,
         doc,
         content,
         %{source: source_uuid, target: target_uuid},
         context,
         opts
       ) do
    case derive_preview(source_uuid, target_uuid, context, opts) do
      {:ok, %{preview_body: preview_body, result_hash: result_hash}} ->
        case commit_preview_section(pr_uuid, doc, content, preview_body, opts) do
          :ok ->
            {:ok, :tree_mutation,
             %{action: "pr_refresh_preview", pr_uuid: pr_uuid, result_hash: result_hash}}

          {:error, reason} ->
            {:error, "pr_refresh_preview failed to update preview: #{inspect(reason)}"}
        end

      {:error, :not_readable} ->
        {:error, @not_readable_msg}

      {:error, :no_common_ancestor} ->
        {:error, @no_ancestor_msg}

      {:error, {:preview_fork_failed, reason}} ->
        {:error, "pr_refresh_preview failed to scratch-fork target: #{inspect(reason)}"}

      {:error, {:preview_merge_failed, reason}} ->
        {:error, "pr_refresh_preview failed to merge: #{inspect(reason)}"}

      {:error, reason} ->
        {:error, "pr_refresh_preview failed: #{inspect(reason)}"}
    end
  end

  # CX-pr7.4: the SHARED scratch-preview derivation §6 step 3 requires —
  # "re-run the scratch preview machinery" must be the SAME code path
  # `pr_refresh_preview` uses, not a re-implementation that could drift.
  # Forks the target (NOT attached anywhere — unreachable-by-construction,
  # reachability-GC owns cleanup), merges source into the scratch, and
  # returns the rendered preview body + its result_hash + the
  # `MergeReport` — WITHOUT touching the PR doc or the real target. The
  # scratch fork is throwaway, so signing it with the INVOKER's own
  # context is fine — nothing downstream trusts scratch-doc authorship.
  # `target_uuid` here is always `scratch_uuid`, never the real target,
  # which is exactly what keeps this from ever writing a
  # `(real_target, source)` merge-point (see merge.ex's
  # `set_merge_point/4` call sites — always keyed off the 2nd positional
  # `merge/4` arg).
  #
  # CX-pr7.3b (designer review of 7.3 — read-scoping leak): the guard
  # runs FIRST, before the scratch fork ever happens (never fork a doc
  # the invoker can't read — the fork copies gated content). Both
  # `pr_refresh_preview` and `pr_accept` inherit it by construction,
  # since this is their one shared derivation path.
  defp derive_preview(source_uuid, target_uuid, context, opts) do
    with :ok <- preview_guard(source_uuid, target_uuid, context) do
      # §7.3c: the scratch fork is signed with the INVOKER's context (the
      # same `opts` the merge uses) — nothing downstream trusts scratch
      # authorship (it's throwaway, born-unreachable), and under enforce
      # an unsigned fork silently lands NOTHING (fork's create_commit is
      # fire-and-forget), degenerating the preview to empty. Signing it as
      # the requester makes the whole preview attributable and lets it
      # actually land under `local_write_gate: :enforce`.
      # Explicit 3-arg form — `fork/3` is `fork(server \\ __MODULE__,
      # source_uuid, opts \\ [])`, so a 2-arg `fork(uuid, opts)` would bind
      # uuid as the SERVER. Name the server to reach the opts arg.
      case CommandRouter.fork(CommandRouter, target_uuid, opts) do
        {:ok, scratch_uuid} ->
          case Merge.merge(source_uuid, scratch_uuid, CommitStoreClient, opts) do
            {:ok, report} -> build_preview(source_uuid, target_uuid, scratch_uuid, report)
            {:error, reason} -> {:error, {:preview_merge_failed, reason}}
          end

        {:error, reason} ->
          {:error, {:preview_fork_failed, reason}}
      end
    end
  end

  # CX-pr7.3b — THE HOLE this closes: `derive_preview` re-reads
  # source/target uuids from the PR doc, which is an ORDINARY EDITABLE
  # doc — anyone who can write it can stamp `<pr source="ANY-UUID">`
  # and hit refresh/accept to project THAT doc's full text into a
  # preview section they can read: a durable read-oracle bypassing the
  # P2/P3 read-gating. Two re-validations, both BEFORE the fork:
  #
  #   1. ANCESTRY re-check on EVERY derive (refresh AND accept):
  #      `find_common_ancestor(target, source) ≠ :none` — `pr_open`
  #      validated this once (§7.2), but the PR doc's fields can't be
  #      trusted to have preserved that invariant (§6.3). Checked FIRST
  #      so an arbitrary stamped uuid — nonexistent, unrelated-public,
  #      or unrelated-gated alike — gets the SAME ancestry refusal
  #      (existence-hiding for the common probe: the more-specific
  #      read-gate message below only ever appears for docs that share
  #      fork lineage with the other endpoint).
  #   2. INVOKER READ-GATE on BOTH uuids via
  #      `Commonplace.Trust.Read.authorized?/3` (the P1/P2 read
  #      verifier, pinned-enforce — NOT the `:local_read_gate`-knobbed
  #      `gate/3`), with carried visibility/owner resolved by
  #      `Trust.ReadMeta.resolve/2` — the SAME canonical meta-read the
  #      other direct-by-uuid surfaces (MCP `cat`, GitBridge exporter)
  #      use. A plain wiki/text doc with no visibility field resolves
  #      `:public` → `:ok` (ReadMeta's documented no-regression
  #      default), so ungated docs preview exactly as before. The
  #      refusal is ONE uniform message for source-vs-target and
  #      exists-vs-unauthorized alike (thin-handle: no existence
  #      oracle).
  defp preview_guard(source_uuid, target_uuid, context) do
    with {:ok, _ancestor} <- validate_common_ancestor(target_uuid, source_uuid),
         :ok <- invoker_read_gate(source_uuid, context),
         :ok <- invoker_read_gate(target_uuid, context) do
      :ok
    else
      {:error, :no_common_ancestor} -> {:error, :no_common_ancestor}
      {:error, :read_denied} -> {:error, :not_readable}
    end
  end

  # The invoker's read authority over one doc. Identity/pub are the
  # SERVER-RESOLVED session signing context (`principal_identity/1` —
  # `{nil, nil}` for an anonymous session, which can read only public
  # docs under a strict config), never a client-claimed value — the
  # verifier's caller contract #1. visibility/owner come from the
  # target's own committed state via `ReadMeta.resolve/2` — caller
  # contract #2. `cert_cids: []` — same posture as this module's write
  # gates: the wiki/PR surface carries no cert plumbing yet.
  defp invoker_read_gate(uuid, context) do
    {identity, pub} = principal_identity(context)
    meta = ReadMeta.resolve(uuid, CommitStoreClient)

    Commonplace.Trust.Read.authorized?(identity, uuid,
      visibility: meta.visibility,
      owner: meta.owner,
      reader_pub: pub,
      cert_cids: [],
      cfg: Trust.config(),
      store: CommitStoreClient
    )
  end

  defp build_preview(source_uuid, target_uuid, scratch_uuid, report) do
    with {:ok, base_text} <- reconstruct_base_text(target_uuid, source_uuid),
         {:ok, source_text} <- reconstruct_leaf_text(source_uuid),
         {:ok, projected_text} <- reconstruct_leaf_text(scratch_uuid),
         {:ok, scratch_head_hex} <- scratch_head_hex(scratch_uuid) do
      result_hash = :crypto.hash(:sha256, projected_text) |> Base.encode16(case: :lower)

      preview_body =
        render_preview_body(%{
          report: report,
          base_text: base_text,
          source_text: source_text,
          projected_text: projected_text,
          result_hash: result_hash,
          scratch_head_hex: scratch_head_hex
        })

      {:ok, %{preview_body: preview_body, result_hash: result_hash, report: report}}
    end
  end

  # `base` = target's content at the source/target common ancestor
  # commit. Re-derived fresh every refresh (never cached) — same
  # "recorded fields are informational, live derivation is truth"
  # posture as everything else in this verb.
  defp reconstruct_base_text(target_uuid, source_uuid) do
    case CommitStoreClient.find_common_ancestor(target_uuid, source_uuid) do
      {:ok, ancestor} ->
        case DocBuilder.reconstruct_doc_at(CommitStoreClient, target_uuid, ancestor.id) do
          {:ok, ancestor_doc} -> {:ok, leaf_text_content(ancestor_doc)}
          :none -> {:ok, ""}
        end

      :none ->
        {:ok, ""}
    end
  end

  defp reconstruct_leaf_text(uuid) do
    case DocBuilder.reconstruct_doc(CommitStoreClient, uuid) do
      {:ok, doc} -> {:ok, leaf_text_content(doc)}
      :none -> {:ok, ""}
    end
  end

  # v1 is single-doc/leaf-only (design doc §7.7): the projection is
  # just the doc's text content. Kept deliberately simple rather than
  # reaching for a GitBridge doc->file projection helper — GitBridge's
  # projection machinery (`git_bridge/inbound.ex`) is shaped around
  # importing/exporting an actual git repo's working tree, not around
  # rendering an arbitrary doc as display text, so it would be a bigger
  # dependency for no v1 benefit. A non-text doc renders via `inspect/1`
  # as a visible fallback rather than silently going blank.
  defp leaf_text_content(doc) do
    case ContentType.get_content(doc) do
      text when is_binary(text) -> text
      other -> inspect(other)
    end
  end

  defp scratch_head_hex(scratch_uuid) do
    case CommitStoreClient.latest_commit(scratch_uuid) do
      {:ok, commit} -> {:ok, Base.encode16(commit.id, case: :lower)}
      :none -> {:ok, nil}
    end
  end

  defp render_preview_body(%{
         report: report,
         base_text: base_text,
         source_text: source_text,
         projected_text: projected_text,
         result_hash: result_hash,
         scratch_head_hex: scratch_head_hex
       }) do
    """
    <merge-summary merged="#{length(report.merged_docs)}" new="#{length(report.new_docs)}" deleted="#{length(report.deleted_docs)}" conflicts="#{length(report.conflicts)}" />
    #{render_conflicts(report.conflicts)}
    <diff from="base" to="source">
    #{preview_esc(line_diff(base_text, source_text))}
    </diff>
    <diff from="base" to="projected-result">
    #{preview_esc(line_diff(base_text, projected_text))}
    </diff>
    <projected-result>
    #{preview_esc(projected_text)}
    </projected-result>
    <result-hash>#{result_hash}</result-hash>
    <scratch-head note="informational-only per design doc §6.3 — pr_accept re-derives this, never trusts it">#{scratch_head_hex || ""}</scratch-head>
    """
  end

  defp render_conflicts([]), do: "<conflicts/>"

  defp render_conflicts(conflicts) do
    lines = Enum.map(conflicts, fn c -> "  <conflict>#{preview_esc(inspect(c))}</conflict>" end)
    Enum.join(["<conflicts>" | lines] ++ ["</conflicts>"], "\n")
  end

  # Line-level Myers diff, rendered unified-diff-style (`  ` unchanged,
  # `- ` removed, `+ ` added). Not the GitBridge projection helper (see
  # `leaf_text_content/1`'s comment) — a small self-contained renderer
  # reusing the same `List.myers_difference/2` stdlib primitive
  # `Commonplace.Document.Diff` already uses at grapheme granularity;
  # line granularity reads better for a human review surface.
  defp line_diff(old_text, new_text) do
    old_lines = String.split(old_text || "", "\n")
    new_lines = String.split(new_text || "", "\n")

    List.myers_difference(old_lines, new_lines)
    |> Enum.flat_map(fn
      {:eq, lines} -> Enum.map(lines, &("  " <> &1))
      {:del, lines} -> Enum.map(lines, &("- " <> &1))
      {:ins, lines} -> Enum.map(lines, &("+ " <> &1))
    end)
    |> Enum.join("\n")
  end

  defp preview_esc(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  @preview_section_re ~r/<section id="preview">.*?<\/section>/s

  # REPLACE the `<section id="preview">` region (mirrors the
  # `SessionView.replace_room/2` REPLACE-subtree pattern's *intent* —
  # swap one region's content wholesale without touching the rest of
  # the doc — but the PR doc is a plain Y.Text/XML-as-text leaf, not a
  # YXmlFragment with independently-addressable child subtrees, so
  # there's no separate CRDT subtree to tombstone-and-reinsert. Instead
  # this splices the new section into the full text and hands the
  # full old/new strings to `Commonplace.Document.Diff.apply_diff/3` —
  # the SAME minimal-diff machinery CX-k20z's write_meta_doc fix
  # established: Myers diff finds the common prefix/suffix (everything
  # outside `<section id="preview">`) and only the changed middle span
  # gets delete/insert ops, so — like `replace_room/2`'s region
  # isolation — untouched parts of the doc (the `<pr>` header, other
  # sections, the `<action>` elements) generate no ops on this commit.
  defp commit_preview_section(pr_uuid, doc, old_content, preview_body, opts) do
    new_section = "<section id=\"preview\">" <> preview_body <> "</section>"

    if Regex.match?(@preview_section_re, old_content) do
      new_content =
        Regex.replace(@preview_section_re, old_content, fn _whole -> new_section end, global: false)

      commit_pr_update(pr_uuid, doc, old_content, new_content, opts)
    else
      {:error, "PR doc missing <section id=\"preview\"> region"}
    end
  end

  # The shared low-level PR-doc committer: minimal-diff (`Diff.apply_diff/3`
  # — CX-k20z's fix) the full old/new content strings and land a chained,
  # invoker-signed commit. `commit_preview_section/5` (§7.3) and every
  # §7.4 write below (`finish_accept/6`, `decline_pr/6`, `pr_comment`)
  # share this one commit path.
  defp commit_pr_update(pr_uuid, doc, old_content, new_content, opts) do
    doc = Diff.apply_diff(doc, old_content, new_content)
    update = Encoding.encode_update(doc)

    case ok_commit(
           CommitStoreClient.create_chained_commit(CommitStoreClient, pr_uuid, update, %{}, opts)
         ) do
      {:ok, _commit} -> :ok
      {:error, _} = err -> err
    end
  end

  # --- pr_accept helpers (§7.4, design doc §6) ---

  @anonymous_principal "anonymous@local"

  # §6 step 3 (staleness by re-derivation): re-run the SAME scratch
  # preview `pr_refresh_preview` uses (`derive_preview/3`) and compare
  # its fresh `result_hash` against the hash actually committed in the
  # PR doc's preview section (`extract_committed_result_hash/1`) — NEVER
  # against any doc-recorded head CID (forgeable, §6.3). A mismatch, or
  # no committed hash at all (the still-a-placeholder case), takes the
  # SAME stale path: auto-refresh the section with the fresh preview,
  # then refuse.
  defp accept_pr(
         pr_uuid,
         doc,
         content,
         %{source: source_uuid, target: target_uuid},
         context,
         opts
       ) do
    # §6 REORDER (cp-plan #8403): AUTHORIZATION (step 4) runs BEFORE the
    # staleness re-derivation (step 3) now. Three reasons: (a) an
    # unauthorized invoker gets the honest "not authorized" refusal
    # instead of a downstream write-gate error; (b) we don't run a
    # write-heavy re-derivation (scratch fork + merge) on behalf of
    # someone who can't accept; (c) — the mandatory one — the stale path
    # COMMITS an auto-refreshed preview, so checking authz first stops an
    # unauthorized invoker from causing writes to the PR doc via accept.
    # No writes happen before this gate.
    {identity_uuid, pub} = principal_identity(context)

    if Trust.writer_authorized?(identity_uuid, pub, [], target_uuid, Trust.config(), CommitStoreClient) do
      accept_authorized(pr_uuid, doc, content, source_uuid, target_uuid, context, opts)
    else
      {:error, "you are not authorized to accept into the target"}
    end
  end

  # Post-authorization (§6 steps 3→5). The invoker is authorized to write
  # the target, so the staleness re-derivation's own writes (scratch fork,
  # and the stale-path auto-refresh commit) are legitimate.
  defp accept_authorized(pr_uuid, doc, content, source_uuid, target_uuid, context, opts) do
    case derive_preview(source_uuid, target_uuid, context, opts) do
      {:ok, %{preview_body: preview_body}} ->
        handle_accept_staleness(
          pr_uuid,
          doc,
          content,
          source_uuid,
          target_uuid,
          context,
          opts,
          preview_body
        )

      # CX-pr7.3b: the shared preview guard (ancestry re-check +
      # invoker read-gate) refuses BEFORE any fork/merge/write — a PR
      # doc whose <pr> fields were stamped with a foreign/unreadable
      # uuid can neither exfiltrate its text NOR reach the merge.
      {:error, :not_readable} ->
        {:error, @not_readable_msg}

      {:error, :no_common_ancestor} ->
        {:error, @no_ancestor_msg}

      {:error, {:preview_fork_failed, reason}} ->
        {:error, "pr_accept failed to derive fresh preview (scratch-fork): #{inspect(reason)}"}

      {:error, {:preview_merge_failed, reason}} ->
        {:error, "pr_accept failed to derive fresh preview (merge): #{inspect(reason)}"}

      {:error, reason} ->
        {:error, "pr_accept failed to derive fresh preview: #{inspect(reason)}"}
    end
  end

  defp handle_accept_staleness(
         pr_uuid,
         doc,
         content,
         source_uuid,
         target_uuid,
         context,
         opts,
         preview_body
       ) do
    # §7.4b (cp-plan #8403): the staleness comparand is the reviewer-
    # VISIBLE preview CONTENT, not the doc's self-declared <result-hash>.
    # A hash-vs-hash check only proves the projected TEXT is fresh; it
    # does NOT protect what the acceptor actually READ — an attacker can
    # leave <result-hash> honest but hand-edit the displayed <diff>/
    # <projected-result>/summary, so the reviewer approves benign text
    # while the real merge lands malicious content (what-you-see ≠
    # what-you-get, defeating the review-integrity property this feature
    # exists for). Comparand = the committed preview body with the
    # volatile/informational fields (scratch-head, result-hash) excluded,
    # vs the freshly-rendered body with the same exclusions. Any tamper
    # with what the reviewer saw → mismatch → the SAME stale path. The
    # determinism pin (§7.3) guarantees the fresh render is byte-stable
    # over exactly these non-volatile fields, so this is a comparand
    # swap, not new machinery.
    fresh_comparand = preview_comparand(preview_body)

    case extract_committed_preview_body(content) do
      {:ok, committed_body} when committed_body != :placeholder ->
        if preview_comparand(committed_body) == fresh_comparand do
          # WYSIWYG: what the acceptor reviewed IS what accepting produces.
          # Proceed to the REAL signed merge into target_uuid (never the
          # scratch copy derive_preview used).
          do_accept_merge(pr_uuid, doc, content, source_uuid, target_uuid, context, opts)
        else
          auto_refresh_and_refuse(pr_uuid, doc, content, preview_body, opts)
        end

      _stale_or_missing ->
        auto_refresh_and_refuse(pr_uuid, doc, content, preview_body, opts)
    end
  end

  defp auto_refresh_and_refuse(pr_uuid, doc, content, preview_body, opts) do
    case commit_preview_section(pr_uuid, doc, content, preview_body, opts) do
      :ok ->
        {:error, "preview is stale — refreshed; review and accept again"}

      {:error, reason} ->
        {:error, "pr_accept failed to auto-refresh stale preview: #{sanitize_write_error(reason)}"}
    end
  end

  # §6.6 (sanitized returns, CX-3x5a): the local write gate's own
  # refusal shape (`{:trust_rejected, reason}`, from
  # `CommitStore.local_write_gate_check/2` under `local_write_gate:
  # :enforce`) carries an internal trust-decision reason
  # (`:unsigned` / `{:untrusted_signer, _}` / ...) that must never
  # reach a flash message or MCP response text verbatim — every PR-doc
  # write below (`finish_accept/6`, `decline_pr/6`, `pr_comment`, and
  # the auto-refresh path here) that surfaces a raw commit-store error
  # runs it through this first.
  defp sanitize_write_error({:trust_rejected, _reason}), do: "write refused"
  defp sanitize_write_error(other), do: inspect(other)

  # Pull the inner body of the CURRENTLY COMMITTED `<section id="preview">`
  # region. Returns `{:ok, :placeholder}` when the section still holds the
  # §7.2 placeholder (`pr_refresh_preview` never ran — no real preview to
  # compare against), and `:error` when there is no preview section at all
  # (shouldn't happen post-§7.2 template). Both fold into the stale path.
  defp extract_committed_preview_body(content) do
    case Regex.run(~r/<section id="preview">(.*?)<\/section>/s, content) do
      [_, body] ->
        if String.contains?(body, "<result-hash>"),
          do: {:ok, body},
          else: {:ok, :placeholder}

      nil ->
        :error
    end
  end

  # §7.4b comparand: the reviewer-VISIBLE preview content, with the two
  # volatile/informational fields stripped so they never move the
  # comparison — `<scratch-head>` (a fresh scratch-fork uuid's commit id,
  # different every derive) and `<result-hash>` (deterministic, but ruled
  # informational-only by cp-plan #8403 — the review-integrity check is on
  # the DISPLAYED text, not a self-declared digest). What remains is the
  # merge summary + conflicts + diffs + projected-result — exactly what
  # the acceptor read, and byte-stable across derives (§7.3 determinism
  # pin). Direct string comparison (stronger than a hash — no collision
  # surface; both bodies are already in hand).
  defp preview_comparand(body) do
    body
    |> String.replace(~r/<scratch-head\b[^>]*>.*?<\/scratch-head>/s, "")
    |> String.replace(~r/<result-hash>.*?<\/result-hash>/s, "")
  end

  # §6 step 4 (authorization at the dispatch call-site): the commitless
  # `Trust.writer_authorized?/6` pre-check — same predicate other
  # elevation-adjacent call sites use — on the ACCEPTOR's
  # signing-context-derived identity (`principal_identity/1`), never a
  # client-asserted arg. `cert_cids: []` — the wiki/PR surface has no
  # citizenship-cert plumbing (that's a MUD-only concept), so only a
  # locally-pinned/node-trusted identity (or full-permissive
  # `accept_unsigned`) authorizes here; this is intentionally the SAME
  # bar the real merge's write-gate re-checks at commit time (step 5),
  # just checked first for a clean sanitized refusal instead of a
  # buried write-gate error.
  # §6 step 5 (signed merge). Authorization (step 4) already passed in
  # `accept_pr/6` — the write-gate re-checks it at commit time anyway
  # (belt-and-suspenders), but running the REAL merge only after the
  # WYSIWYG staleness check means we merge exactly the content the
  # acceptor reviewed. The ACCEPTOR's signing_context (captured in `opts`
  # by `signing_opts/1` at the dispatch clause) threads through, so every
  # commit the merge produces carries the acceptor's cert and the local
  # write-gate evaluates their ACTUAL authority under enforce (closes the
  # unsigned-merge-commit gap §7.1's signing plumb exists to fix).
  # Bd P2 Slice S3 (Part E, the pr_merge stamp): the merge commit(s)
  # this produces are tagged with `metadata: %{kind: :regular, pr_merge:
  # pr_uuid}` — `:kind` is REQUIRED (`Commit.new` rejects non-empty
  # kindless metadata) and `:regular` (not `:snapshot`) because this is
  # an ordinary delta, not a history-collapsing snapshot. Because
  # `metadata` is content-addressed (`Commit.content_address/4`), the
  # stamp is bound into the commit id and covered by the acceptor's
  # signature over that id — unforgeable without the acceptor's key, and
  # it needs no trust in the (editable) PR doc. `Commonplace.Bd.CloseGate`
  # requires this stamp (`metadata[:pr_merge]`) before accepting a
  # `done_when: pr_merge` witness — see its moduledoc for the semantic
  # gap this closes (exists+on-chain+signed+authorized alone only proves
  # "some authorized commit landed on target," not "a PR merge landed").
  defp do_accept_merge(pr_uuid, doc, content, source_uuid, target_uuid, context, opts) do
    merge_opts = Keyword.put(opts, :metadata, %{kind: :regular, pr_merge: pr_uuid})

    case Merge.merge(source_uuid, target_uuid, CommitStoreClient, merge_opts) do
      {:ok, report} ->
        finish_accept(pr_uuid, doc, content, report, context, opts)

      # §6 step 6 (sanitized returns): the 7.1b write-refusal tuple names
      # the doc uuid and raw trust reason — sanitize both away here
      # (CX-3x5a) rather than let a raw `{:untrusted_signer, _}`-shaped
      # tuple leak to a flash message or MCP response text.
      {:error, {:write_refused, _doc_uuid, _reason}} ->
        {:error, "pr_accept failed: write refused for target"}

      {:error, reason} ->
        {:error, "pr_accept failed to merge: #{inspect(reason)}"}
    end
  end

  # On success: status -> :merged, acceptor + a MergeReport summary
  # recorded in the PR doc via the `Template` helpers (§7.4), one
  # invoker(acceptor)-signed commit.
  defp finish_accept(pr_uuid, doc, content, report, context, opts) do
    acceptor = resolve_principal(context)
    ts = DateTime.utc_now() |> DateTime.to_iso8601()

    summary =
      "merged=#{length(report.merged_docs)} new=#{length(report.new_docs)} " <>
        "deleted=#{length(report.deleted_docs)} conflicts=#{length(report.conflicts)}"

    new_content =
      content
      |> Template.set_pr_attrs(%{status: "merged", merged_by: acceptor, merged_at: ts})
      |> Template.append_review("system", ts, "Accepted by #{acceptor} — #{summary}")

    case commit_pr_update(pr_uuid, doc, content, new_content, opts) do
      :ok ->
        {:ok, :tree_mutation, %{action: "pr_accept", pr_uuid: pr_uuid, result: :merged}}

      {:error, reason} ->
        {:error, "pr_accept failed to update PR doc after merge: #{sanitize_write_error(reason)}"}
    end
  end

  # §6.3/§6.4 (again, for the accept/decline gates): the invoking
  # principal's raw identity, as `{identity_uuid, public_key}`, derived
  # ONLY from `context.signing_context` — an anonymous/unresolved
  # session yields `{nil, nil}`, which `Trust.writer_authorized?/6`
  # correctly refuses (`not is_binary(identity_uuid) -> false`) under
  # enforce and correctly ignores under the permissive default
  # (`accept_unsigned` short-circuits before ever inspecting identity).
  defp principal_identity(context) do
    case Map.get(context, :signing_context) do
      %Commonplace.Crypto.SigningContext{identity_uuid: id, public_key: pub} -> {id, pub}
      _ -> {nil, nil}
    end
  end

  # --- pr_decline helpers (§7.4) ---

  # Allowed for a target-`:write` holder OR the PR's own opener — see
  # `opener_may_decline?/2` for designer ruling #8390-1's exact gate.
  defp decline_pr(
         pr_uuid,
         doc,
         content,
         %{target: target_uuid, opened_by: opened_by},
         context,
         opts
       ) do
    if can_decline?(target_uuid, opened_by, context) do
      decliner = resolve_principal(context)
      ts = DateTime.utc_now() |> DateTime.to_iso8601()

      new_content =
        content
        |> Template.set_pr_attrs(%{status: "declined", declined_by: decliner, declined_at: ts})
        |> Template.append_review("system", ts, "Declined by #{decliner}")

      case commit_pr_update(pr_uuid, doc, content, new_content, opts) do
        :ok ->
          {:ok, :tree_mutation, %{action: "pr_decline", pr_uuid: pr_uuid, result: :declined}}

        {:error, reason} ->
          {:error, "pr_decline failed to update PR doc: #{sanitize_write_error(reason)}"}
      end
    else
      {:error, "you are not authorized to decline this PR"}
    end
  end

  defp can_decline?(target_uuid, opened_by, context) do
    writer_holds_write?(target_uuid, context) or opener_may_decline?(opened_by, context)
  end

  defp writer_holds_write?(target_uuid, context) do
    {identity_uuid, pub} = principal_identity(context)

    Trust.writer_authorized?(
      identity_uuid,
      pub,
      [],
      target_uuid,
      Trust.config(),
      CommitStoreClient
    )
  end

  # Designer ruling (#8390-1): the opener-decline branch matches ONLY
  # when BOTH the PR's recorded `opened_by` AND the CURRENT session's
  # principal are signing-context-derived (real signer_ids) — an
  # `opened_by` equal to the anonymous fallback (`pr_open`'s
  # `resolve_principal/1` default, "anonymous@local") confers NO opener
  # rights, and `session_signing_principal/1` returns `nil` (never a
  # string, so it can never equal a recorded `opened_by`) for any
  # session that didn't itself resolve a signing_context. Without both
  # halves of this check, any two anonymous sessions would "be" the
  # same opener and could decline each other's anonymously-opened PRs —
  # such a PR is declinable only via the target-`:write` branch above.
  defp opener_may_decline?(opened_by, context) do
    is_binary(opened_by) and opened_by != @anonymous_principal and
      session_signing_principal(context) == opened_by
  end

  defp session_signing_principal(context) do
    case Map.get(context, :signing_context) do
      %Commonplace.Crypto.SigningContext{identity_uuid: id, public_key: pub} ->
        Signing.signer_id(id, pub)

      _ ->
        nil
    end
  end
end
