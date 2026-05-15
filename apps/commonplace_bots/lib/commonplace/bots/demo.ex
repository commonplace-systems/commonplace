defmodule Commonplace.Bots.Demo do
  @moduledoc """
  Demo-room bootstrap for v0 acceptance testing.

  Mints one chat room under a root directory and two bot
  directories (`alice.bot`, `bob.bot`) inside it. Returns the
  identifiers a test (or human demo session) needs to drive
  the system end-to-end:

      %{
        room: "<room-name>",
        room_dir_uuid: "<uuid>",
        messages_uuid: "<uuid>",
        bots: %{"alice" => "<dir-uuid>", "bob" => "<dir-uuid>"}
      }

  Two callers in mind:

    1. `apps/commonplace_bots/test/end_to_end_test.exs` — the
       acceptance test. Bootstraps + drives via stub
       Anthropic client.
    2. A future `mix bots.demo` script (filed against CX-q8nk's
       follow-up bead) that bootstraps the same shape against
       a live `commonplace serve` for a human-driven session.

  ## Personas

  Both bots' personas are intentionally minimal — enough to
  give the model a recognizable voice, light enough to fit in
  a few hundred tokens. The triggers are conservative
  regexes that match a leading `@<name>` mention.

  ## Substrate layout

      <root>/
        <room>/
          _messages          (Chat.Messages.new())
          __bot_activity     (minted lazily by Dispatcher.subscribe_room/3)
          alice.bot/
            persona.md
            memory.jsonl
            trigger.regex
          bob.bot/
            persona.md
            memory.jsonl
            trigger.regex

  Hook the result into the running `Commonplace.Bots.Dispatcher`
  via `Dispatcher.subscribe_room(room, room_dir_uuid,
  messages_uuid)`. The dispatcher will scan `*.bot/` entries on
  every chat event and wake matching bots.
  """

  alias Commonplace.Chat.Messages
  alias Commonplace.Document.ContentType
  alias Commonplace.Store.{CommitStore, CommitStoreClient}
  alias Commonplace.Tree.{DocBuilder, Schema}

  @default_alice_persona """
  You are Alice, a friendly bot in a chat room. Keep replies under three sentences.

  You have persistent memory across turns in a file called memory.jsonl. When someone asks you anything that depends on knowing them — gift ideas, "what do you know about me", "have we met", "what's my X", "do you remember Y" — call the read_memory tool BEFORE answering. Don't say "I don't know you yet" without checking first; you might.

  When you learn something about the human you're talking with — not just hard facts like name and favorites, but also patterns and quirks you notice (how they think, what they're curious about, their conversational style, recurring themes) — call remember to write it down. One line per observation. You don't need to be asked, and observations count even when they're soft.

  When you reply, use the post_message tool.
  """

  @default_bob_persona """
  You are Bob, a laconic bot in a chat room. Keep replies very short — one line if possible.

  You have persistent memory in memory.jsonl. Before saying you don't know the user on identity questions ("what's my name", "what do we have in common", "have we talked"), call read_memory. Brevity is no excuse for forgetting.

  When you learn something durable about the human — facts they tell you, patterns you notice, the way they ask questions, recurring themes in what they say — call remember. One line per fact or observation. Don't wait to be told.

  When you reply, use post_message.
  """

  @default_alice_trigger "(?i)@alice\\b"
  @default_bob_trigger "(?i)@bob\\b"

  @doc """
  Bootstrap the demo room + bots under `root_uuid`. Returns the
  identifier map.

  `opts`:
    * `:room` — room name (default `"demo"`)
    * `:store` — write store (default `Commonplace.Store.CommitStore`)
    * `:read_store` — read store (default `CommitStoreClient`)
    * `:bots` — list of `{name, persona, trigger}` triples
      (default the alice + bob pair).
  """
  @spec bootstrap(String.t(), keyword()) :: map()
  def bootstrap(root_uuid, opts \\ []) do
    write_store = Keyword.get(opts, :store, CommitStore)
    read_store = Keyword.get(opts, :read_store, CommitStoreClient)
    room_name = Keyword.get(opts, :room, "demo")
    bots = Keyword.get(opts, :bots, default_bots())

    messages_uuid = mint_messages_doc(write_store)

    bot_dir_uuids =
      Map.new(bots, fn {name, persona, trigger} ->
        {name, mint_bot_dir(write_store, persona, trigger)}
      end)

    room_dir_uuid =
      mint_room_dir(write_store, messages_uuid, bot_dir_uuids)

    link_room_under_root(write_store, read_store, root_uuid, room_name, room_dir_uuid)

    %{
      room: room_name,
      room_dir_uuid: room_dir_uuid,
      messages_uuid: messages_uuid,
      bots: bot_dir_uuids
    }
  end

  defp default_bots do
    [
      {"alice", @default_alice_persona, @default_alice_trigger},
      {"bob", @default_bob_persona, @default_bob_trigger}
    ]
  end

  defp mint_messages_doc(write_store) do
    uuid = UUID.uuid4()
    update = Yelixer.Encoding.encode_update(Messages.new())
    CommitStore.create_commit(write_store, uuid, update, nil)
    uuid
  end

  defp mint_bot_dir(write_store, persona, trigger) do
    persona_uuid = mint_text_doc(write_store, "persona.md", persona)
    memory_uuid = mint_text_doc(write_store, "memory.jsonl", "")
    trigger_uuid = mint_text_doc(write_store, "trigger.regex", trigger)

    schema =
      Schema.new_schema()
      |> Schema.add_file("persona.md", persona_uuid)
      |> Schema.add_file("memory.jsonl", memory_uuid)
      |> Schema.add_file("trigger.regex", trigger_uuid)

    uuid = UUID.uuid4()
    update = Yelixer.Encoding.encode_update(schema)
    CommitStore.create_commit(write_store, uuid, update, nil)
    uuid
  end

  defp mint_text_doc(write_store, name, body) do
    uuid = UUID.uuid4()
    doc = Yelixer.Doc.new()
    doc = ContentType.create(doc, :text, name)
    doc = if body == "", do: doc, else: ContentType.insert_text(doc, 0, body)
    update = Yelixer.Encoding.encode_update(doc)
    CommitStore.create_commit(write_store, uuid, update, nil)
    uuid
  end

  defp mint_room_dir(write_store, messages_uuid, bot_dir_uuids) do
    schema =
      Schema.new_schema()
      |> Schema.add_file("_messages", messages_uuid)
      |> add_bot_directories(bot_dir_uuids)

    uuid = UUID.uuid4()
    update = Yelixer.Encoding.encode_update(schema)
    CommitStore.create_commit(write_store, uuid, update, nil)
    uuid
  end

  defp add_bot_directories(schema, bot_dir_uuids) do
    Enum.reduce(bot_dir_uuids, schema, fn {name, dir_uuid}, acc ->
      Schema.add_directory(acc, "#{name}.bot", dir_uuid)
    end)
  end

  defp link_room_under_root(write_store, read_store, root_uuid, room_name, room_dir_uuid) do
    root_doc =
      case DocBuilder.reconstruct_snapshot(read_store, root_uuid) do
        {:ok, doc} -> doc
        _ -> Schema.new_schema()
      end

    new_root = Schema.add_directory(root_doc, room_name, room_dir_uuid)
    update = Yelixer.Encoding.encode_update(new_root)
    CommitStore.create_chained_commit(write_store, root_uuid, update)
    :ok
  end
end
