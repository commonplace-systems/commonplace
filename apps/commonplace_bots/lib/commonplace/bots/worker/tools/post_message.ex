defmodule Commonplace.Bots.Worker.Tools.PostMessage do
  @moduledoc """
  `post_message` tool — publish a chat message to the worker's
  room as the bot.

  Routes through `Commonplace.Chat.Actions.post_message/3` — the
  same primitive every other client uses. The bot's
  `author_path` is the suffixed entity name (e.g. `"alice.bot"`)
  so subscribers can filter on the suffix per the loop-prevention
  contract.

  ## Cert threading (cp-plan #8833, gap 2)

  `signing_opts/1` threads `:cert_cids` — the UNION of (a) `state.opts`'s
  `:cert_cids` (the room-registration set threaded in by
  `Commonplace.Bots.Dispatcher.subscribe_room/4`'s opts, see that
  function's @doc) and (b) `state.mud_ctx.cert_cids` (the bot's own
  citizenship set) when `mud_ctx` resolved — into
  `Commonplace.Chat.Actions.post_message/3`. Without this, a
  cert-authorized (non-`trusted_identities`-pinned) bot's `_messages`
  post is DENIED under `local_write_gate: :enforce`: the commit is
  correctly bot-signed, but carries no `capability_proof`, so
  `Commonplace.Trust.authorized?/5` falls to its untrusted-signer branch.
  Presenting BOTH sets is harmless — `Commonplace.MUD.SignedWrite`'s
  cert selection (which `Chat.Actions.commit_entry/5` now also drives,
  CX-cy80) picks whichever cert actually covers `messages_uuid`; an
  irrelevant cert in the list is simply not selected. An empty union
  omits the `:cert_cids` key entirely — byte-identical behavior for a
  certless bot (unsigned or `trusted_identities`-pinned).

  ## Store threading (found alongside gap 2, same completeness bar)

  `call/2` also now threads `:store` — `Keyword.get(state.opts, :store,
  CommitStoreClient)` — into `Actions.post_message/3`'s opts. Previously
  ONLY `:messages_uuid` was read from `state.opts`; `:store` was silently
  never forwarded, so `Actions.post_message/3` fell through to ITS OWN
  `CommitStoreClient` default regardless of what store the dispatcher/worker
  were actually running against. Harmless (a no-op) for every default-store
  deployment (the dispatcher's own `state.store` already defaults to
  `CommitStoreClient`, so `state.opts[:store]` is that same value in the
  ordinary case) — but a REAL bug for any isolated/non-default store (a
  test harness with its own named `CommitStore`, or a future multi-store
  deployment): the post would silently target the WRONG store's
  `_messages` doc and come back `{:error, :not_found}`.
  """

  alias Commonplace.Bots.Entity
  alias Commonplace.Chat.Actions
  alias Commonplace.Crypto.{Signing, SigningContext}
  alias Commonplace.Store.CommitStoreClient

  def name, do: "post_message"

  def definition do
    %{
      "name" => "post_message",
      "description" =>
        "Post a chat message to the current room. Returns {message_id, ts} on success.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "text" => %{
            "type" => "string",
            "description" => "The message body."
          }
        },
        "required" => ["text"]
      }
    }
  end

  def call(state, %{"text" => text}) when is_binary(text) and text != "" do
    messages_uuid = get_messages_uuid(state)
    author_path = Entity.dir_entry_name(state.entity)

    opts =
      [room: state.room, author_path: author_path, store: get_store(state)] ++ signing_opts(state)

    case Actions.post_message(messages_uuid, text, opts) do
      {:ok, %{message_id: id, ts: ts}} ->
        record_post(state)
        {:ok, Jason.encode!(%{"message_id" => id, "ts" => ts})}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  def call(_state, _input), do: {:error, "post_message requires a non-empty 'text' field"}

  defp record_post(state) do
    if Process.whereis(Commonplace.Bots.RateLimit) do
      try do
        Commonplace.Bots.RateLimit.record_post(state.room, state.entity.name)
      catch
        :exit, _ -> :ok
      end
    end

    :ok
  end

  defp get_messages_uuid(state) do
    case Keyword.get(state.opts, :messages_uuid) do
      nil -> raise ArgumentError, "post_message requires :messages_uuid in worker opts"
      uuid when is_binary(uuid) -> uuid
    end
  end

  defp get_store(state), do: Keyword.get(state.opts, :store, CommitStoreClient)

  # Camillo C1: sign the post with the bot's OWN resolved Ed25519 identity
  # (threaded into `state.signing_context` by `Commonplace.Bots.Worker`).
  # The `signer_id` is derived from that context — the same derivation the
  # MCP `loom_send` surface uses — so the audit trail carries the bot's real
  # principal, not a placeholder. With no context resolved we pass neither
  # `signer_id` nor `signing_context`: the write is unsigned, an honest
  # failure that will be denied under enforce (never a fake identity).
  #
  # cp-plan #8833 (gap 2): also threads `:cert_cids` — see the moduledoc's
  # "Cert threading" section. Computed only in the signed branch (no
  # signing_context => no commit to authorize a cert for).
  defp signing_opts(%{signing_context: %SigningContext{} = sc} = state) do
    [signer_id: Signing.signer_id(sc.identity_uuid, sc.public_key), signing_context: sc] ++
      cert_cids_opt(state)
  end

  defp signing_opts(_state), do: []

  defp cert_cids_opt(state) do
    room_cert_cids = state.opts |> Keyword.get(:cert_cids, []) |> List.wrap()
    mud_cert_cids = mud_ctx_cert_cids(Map.get(state, :mud_ctx))

    case Enum.uniq(room_cert_cids ++ mud_cert_cids) do
      [] -> []
      union -> [cert_cids: union]
    end
  end

  # `Commonplace.Bots.MudContext.t()` is a plain map (see that module's
  # moduledoc), not a struct — matched loosely here since a nil/absent
  # mud_ctx is the common "unprovisioned bot" case.
  defp mud_ctx_cert_cids(%{cert_cids: cert_cids}) when is_list(cert_cids), do: cert_cids
  defp mud_ctx_cert_cids(_), do: []
end
