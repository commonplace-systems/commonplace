defmodule Commonplace.Chat.Actions do
  @moduledoc """
  Action handlers for chat-room views (CX-487i / V1+V2).

  Each public function here is the implementation of a chat-room action
  declared in `_view.xml` and dispatched through
  `Commonplace.ViewActionDispatch`. The dispatcher's chat clauses are
  thin — they unpack the context and delegate here.

  ## Why this module exists

  Per chat-room.md (commit a5f3f5e on commonplace-plan/main), the chat
  doc avoids a per-view declarative actions surface (that's CX-y3q's
  story). Instead, ViewActionDispatch grows new `do_dispatch` clauses
  per chat action; each clause delegates to a focused function here.
  Keeps the dispatcher pattern-match shallow and the action logic in a
  module testable on its own.

  V1+V2 ship `post_message/3`. V3 will add `edit_message/3` and
  `delete_message/3`. V4 (followup) adds `react/3`.

  ## Signing

  Until CX-88mw lands per-agent key minting, `:signing_context` in opts
  is the substrate seam (CX-o3r7) — when present, the resulting commit
  is signed with that context's key. When absent, falls back to the
  global SecretStore or unsigned, matching the existing CommitStore
  default-signing behavior.
  """

  alias Commonplace.Chat.Messages
  alias Commonplace.Dataflow.Magenta
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.{DocBuilder, Schema, Walk}
  alias Commonplace.Workspace

  @doc """
  Post a new message to the `_messages` doc identified by
  `messages_uuid`. Required opts: `:room`, `:signer_id`,
  `:author_path`. Optional: `:reply_to`, `:signing_context`, `:store`
  (defaults to `CommitStoreClient`).

  Returns `{:ok, %{message_id: id, ts: iso8601_string}}` on success.
  Returns `{:error, :not_found}` if the messages doc is unknown.
  Returns `{:error, reason_string}` on missing required opts.
  """
  def post_message(messages_uuid, text, opts)
      when is_binary(messages_uuid) and is_binary(text) and is_list(opts) do
    # CX-00ze: defense-in-depth — also reject whitespace-only at the
    # action layer so callers other than ChatRoomLive (MCP, CLI, etc.)
    # can't accidentally land blank messages.
    with :ok <- require_non_blank(text, "text"),
         :ok <- require_opt(opts, :room),
         :ok <- require_opt(opts, :signer_id),
         :ok <- require_opt(opts, :author_path) do
      store = Keyword.get(opts, :store, CommitStoreClient)

      case load_messages_doc(store, messages_uuid) do
        {:ok, doc} ->
          message_id = UUID.uuid4()
          ts = DateTime.utc_now() |> DateTime.to_iso8601()

          entry =
            %{
              "id" => message_id,
              "ts" => ts,
              "author_signer_id" => Keyword.fetch!(opts, :signer_id),
              "author_path" => Keyword.fetch!(opts, :author_path),
              "text" => text
            }
            |> maybe_put("reply_to", Keyword.get(opts, :reply_to))

          commit_entry(doc, store, messages_uuid, entry, opts)
          broadcast_chain(Keyword.fetch!(opts, :room), "post", entry, %{}, opts)

          {:ok, %{message_id: message_id, ts: ts}}

        :none ->
          {:error, :not_found}
      end
    end
  end

  @doc """
  Append an EDIT entry to the `_messages` doc, marking the new entry's
  `edit_of` as the target `message_id`. Append-only: the original
  entry is NOT mutated. Readers walk forward via `Messages.materialize/1`
  to compute current text.

  Required opts: `:room`, `:signer_id`, `:author_path`. Optional:
  `:signing_context`, `:store`. Returns `{:ok, %{message_id, ts}}`
  where `message_id` is the EDIT entry's id (a fresh UUID).
  """
  def edit_message(messages_uuid, target_message_id, new_text, opts)
      when is_binary(messages_uuid) and is_binary(target_message_id) and is_binary(new_text) and
             is_list(opts) do
    # CX-00ze: edits with whitespace-only text would silently blank
    # the rendered message. Reject at the action layer.
    with :ok <- require_non_blank(new_text, "new_text"),
         :ok <- require_opt(opts, :room),
         :ok <- require_opt(opts, :signer_id),
         :ok <- require_opt(opts, :author_path) do
      store = Keyword.get(opts, :store, CommitStoreClient)

      case load_messages_doc(store, messages_uuid) do
        {:ok, doc} ->
          edit_id = UUID.uuid4()
          ts = DateTime.utc_now() |> DateTime.to_iso8601()

          entry = %{
            "id" => edit_id,
            "ts" => ts,
            "author_signer_id" => Keyword.fetch!(opts, :signer_id),
            "author_path" => Keyword.fetch!(opts, :author_path),
            "text" => new_text,
            "edit_of" => target_message_id
          }

          commit_entry(doc, store, messages_uuid, entry, opts)

          broadcast_chain(
            Keyword.fetch!(opts, :room),
            "edit",
            entry,
            %{"edit_of" => target_message_id},
            opts
          )

          {:ok, %{message_id: edit_id, ts: ts}}

        :none ->
          {:error, :not_found}
      end
    end
  end

  @doc """
  Append a TOMBSTONE entry to the `_messages` doc. Monotone — concurrent
  tombstones converge (any tombstone hides the message; the second is a
  harmless no-op observable in `Messages.materialize/1`).

  Required opts: `:room`, `:signer_id`, `:author_path`. Optional:
  `:signing_context`, `:store`. Returns `{:ok, %{message_id, ts}}`
  where `message_id` is the TOMBSTONE entry's id.
  """
  def delete_message(messages_uuid, target_message_id, opts)
      when is_binary(messages_uuid) and is_binary(target_message_id) and is_list(opts) do
    with :ok <- require_opt(opts, :room),
         :ok <- require_opt(opts, :signer_id),
         :ok <- require_opt(opts, :author_path) do
      store = Keyword.get(opts, :store, CommitStoreClient)

      case load_messages_doc(store, messages_uuid) do
        {:ok, doc} ->
          tomb_id = UUID.uuid4()
          ts = DateTime.utc_now() |> DateTime.to_iso8601()

          entry = %{
            "id" => tomb_id,
            "ts" => ts,
            "author_signer_id" => Keyword.fetch!(opts, :signer_id),
            "author_path" => Keyword.fetch!(opts, :author_path),
            "tombstone_of" => target_message_id
          }

          commit_entry(doc, store, messages_uuid, entry, opts)

          broadcast_chain(
            Keyword.fetch!(opts, :room),
            "delete",
            entry,
            %{"tombstone_of" => target_message_id},
            opts
          )

          {:ok, %{message_id: tomb_id, ts: ts}}

        :none ->
          {:error, :not_found}
      end
    end
  end

  # --- Private ---

  defp require_opt(opts, key) do
    case Keyword.get(opts, key) do
      nil -> {:error, "missing required opt: #{inspect(key)}"}
      "" -> {:error, "missing required opt: #{inspect(key)}"}
      _ -> :ok
    end
  end

  # CX-00ze: reject empty-after-trim strings — accepts non-blank
  # content, rejects "" / "   " / "\t\n" / etc.
  defp require_non_blank(value, label) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, "#{label} is empty or whitespace-only"}
      _ -> :ok
    end
  end

  defp load_messages_doc(store, uuid) do
    case DocBuilder.reconstruct_snapshot(store, uuid) do
      {:ok, doc} -> {:ok, doc}
      :none -> :none
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # Append the entry, encode, commit. Shared by post/edit/delete so
  # signing-context threading and chain-commit semantics live in one
  # place.
  defp commit_entry(doc, store, messages_uuid, entry, opts) do
    doc = Messages.append(doc, entry)
    update = Yelixer.Encoding.encode_update(doc)

    commit_opts =
      case Keyword.get(opts, :signing_context) do
        nil -> []
        ctx -> [signing_context: ctx]
      end

    CommitStoreClient.create_chained_commit(store, messages_uuid, update, %{}, commit_opts)
  end

  # Magenta envelope for post/edit/delete events on chat:{room}:events.
  # Verb selects the type ("post" | "edit" | "delete"); extra_payload
  # carries verb-specific fields ({} for post, %{"edit_of" => …} for
  # edit, %{"tombstone_of" => …} for delete).
  #
  # CX-9zpb: also lazily ensures a red-onramp is running for this room
  # IF opts carries :messages_log_uuid. The onramp's init synchronously
  # subscribes to the topic, so by the time ensure_started returns the
  # subscriber is set — broadcasting after is safe (no first-message
  # drop).
  defp broadcast_chain(room, verb, entry, extra_payload, opts) do
    _ = ensure_room_onramp(room, opts)

    payload =
      %{
        "message_id" => entry["id"],
        "author_signer_id" => entry["author_signer_id"],
        "author_path" => entry["author_path"],
        "ts" => entry["ts"]
      }
      |> Map.merge(extra_payload)

    msg = Magenta.message(verb, "chat", payload)
    Magenta.send("chat:#{room}:events", msg)
    :ok
  end

  # Lazy onramp-start (per chat-room.md / msg #3042). Triggered on every
  # action; idempotent. Skipped when caller didn't supply a log uuid —
  # broadcast-only mode is fine for tests + flows that don't need the
  # red audit trail. Production code paths supply :messages_log_uuid via
  # the action args (resolved by C1 chrome / dispatcher).
  defp ensure_room_onramp(room, opts) do
    case Keyword.get(opts, :messages_log_uuid) do
      nil ->
        :ok

      log_uuid when is_binary(log_uuid) ->
        store_opt =
          case Keyword.get(opts, :store) do
            nil -> []
            store -> [store: store]
          end

        case Commonplace.Chat.OnrampSupervisor.ensure_started(room, log_uuid, store_opt) do
          {:ok, _pid} -> :ok
          {:error, _} -> :ok
        end
    end
  end

  # === CX-icc2 (sub-bead i of CX-8cw5) =====================================
  # invoke_view_action context auto-resolution. Per consensus #3115 → #3135:
  # shape (a) hardcoded resolvers, optional view_path, caller-wins, explicit
  # error on bad view_path (not silent fallback).
  #
  # Three branches per docstring:
  #   * view_path absent → {:ok, args_unchanged}
  #   * view_path supplied + clean → {:ok, args_with_substrate-derived-fields}
  #   * view_path supplied + bad   → {:error, reason}
  #
  # Substrate-derived fields for chat actions: messages_uuid, messages_log_uuid,
  # room (basename of parent dir), author_path (from session.presence_path).
  # ==========================================================================

  @doc """
  Resolve substrate-derived args for the named view action. Caller-supplied
  args win. Returns `{:ok, fully_resolved_args}` or `{:error, reason}`.

  Chat actions (`post_message`, `edit_message`, `delete_message`) resolve
  `messages_uuid` / `messages_log_uuid` / `room` / `author_path`. Unknown
  actions pass args through unchanged (so future view types can carry
  their own resolver clauses without affecting chat).
  """
  def resolve_args(action, args, view_uuid, context)

  def resolve_args(action, args, view_uuid, context)
      when action in ~w(post_message edit_message delete_message) do
    resolve_messages_doc_action(args, view_uuid, context)
  end

  def resolve_args(_action, args, _view_uuid, _context), do: {:ok, args}

  @substrate_derived_fields ~w(messages_uuid messages_log_uuid room author_path)

  defp resolve_messages_doc_action(args, _view_uuid, context) do
    cond do
      # Fully-explicit args (ChatRoomLive's path) — skip resolution
      # entirely. Avoids errors when view_path is informational-only
      # (e.g., legacy callers that supplied view_path before
      # auto-resolution existed) AND callers don't actually need any
      # substrate-derived fields.
      Enum.all?(@substrate_derived_fields, &Map.has_key?(args, &1)) ->
        {:ok, args}

      # No view_path → no resolution attempted. Caller's args pass
      # through unchanged; if they're missing required fields, the
      # dispatcher's existing fetch_arg validation surfaces it.
      Map.get(context, :view_path) in [nil, ""] ->
        {:ok, args}

      true ->
        view_path = Map.get(context, :view_path)

        with {:ok, parent_uuid} <- resolve_parent_dir(view_path),
             {:ok, messages_uuid} <- resolve_sibling_uuid(parent_uuid, "_messages"),
             {:ok, log_uuid} <- resolve_sibling_uuid(parent_uuid, "_messages.log") do
          room_name = view_path |> Path.dirname() |> Path.basename()
          author_path = Map.get(context, :presence_path)

          resolved =
            args
            |> maybe_resolve("messages_uuid", messages_uuid)
            |> maybe_resolve("messages_log_uuid", log_uuid)
            |> maybe_resolve("room", room_name)
            |> maybe_resolve("author_path", author_path)

          {:ok, resolved}
        else
          {:error, reason} ->
            {:error,
             "auto-resolution failed for view_path #{inspect(view_path)}: #{inspect(reason)}"}
        end
    end
  end

  defp resolve_parent_dir(view_path) do
    parent_path = Path.dirname(view_path)

    with {:ok, root_uuid} <- Workspace.root_uuid(),
         loader = &load_schema_for_walk/1,
         {:ok, parent_uuid} <- Walk.resolve_path(root_uuid, parent_path, loader) do
      {:ok, parent_uuid}
    end
  end

  defp resolve_sibling_uuid(parent_uuid, name) do
    doc = load_schema_for_walk(parent_uuid)

    case Schema.get_entry(doc, name) do
      {:ok, entry} -> {:ok, entry.node_id}
      :error -> {:error, {:no_sibling, name}}
    end
  end

  defp load_schema_for_walk(uuid) do
    case DocBuilder.reconstruct_snapshot(CommitStoreClient, uuid) do
      {:ok, doc} -> doc
      :none -> Schema.new_schema()
    end
  end

  # Caller-wins maybe_put: only set the key if the resolved value is non-nil
  # AND the caller didn't already supply it.
  defp maybe_resolve(args, _key, nil), do: args

  defp maybe_resolve(args, key, value) do
    if Map.has_key?(args, key), do: args, else: Map.put(args, key, value)
  end
end
