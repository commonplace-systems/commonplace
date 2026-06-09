defmodule Commonplace.Bots.Entity do
  @moduledoc """
  The bot doc-tree shape and read helpers.

  A bot is a *directory* in the substrate named `<botname>.bot/`. The
  `.bot` suffix is the existing honorific extension reserved by
  `Commonplace.Tree.Schema` (see `Schema.honorific_extension?/1`); it
  tags the entry as an AI-actor's doc-tree the same way `.usr` /
  `.exe` / `.who` tag human / process / generic actors.

  ## Required vs optional children

  A well-formed bot directory contains, at minimum:

      persona.md      — text doc; the system prompt the worker reads
                        as its persona / instructions.
      memory.jsonl    — text doc; newline-separated JSON entries that
                        the worker can read on wake and append to via
                        the `remember` tool. Append-by-end-insert is
                        safe under YText concurrent semantics.
      trigger.regex   — text doc; one regex per line, ANY match → wake.
                        Anchors and flag syntax follow Erlang :re.

  Optional:

      bot.json        — text doc with a JSON object; per-bot overrides
                        for the worker's hard caps and model choice:
                        `max_calls`, `max_output_tokens`, `max_wall_ms`,
                        `model`, `fallback_model`. `Entity` only decodes
                        this to a plain map (`bot_config`) — it does NOT
                        interpret the keys; `Commonplace.Bots.Worker`
                        does (see its `build_config/2`), and is the
                        authority on the knob set and the per-knob
                        defaults. Missing or unparseable → empty map →
                        worker defaults.
      trigger.code    — text doc with an Elixir expression evaluating
                        to `:skip | :wake | {:wake, priority}`. Slot
                        reserved; not consumed by v0 (the regex
                        adapter is the only one wired).

  ## v0 typing — convention, not schema codec

  Plan and I considered a typed schema entry (`kind: :bot` slot in
  the schema codec). Deferred for v0: `Tree.Schema`'s entry encoding
  is `"type:uuid[:nosync]"` with `type ∈ {doc, dir}`, no `kind` slot
  today. The `.bot` suffix on the entry name is the type tag (same
  as `.usr` / `.exe` / `.who`), and `Entity.load/2` does the
  required-child contract validation at read time. A future bead can
  extend the codec for write-time validation if/when needed.

  ## Read path

      iex> {:ok, entity} = Entity.load(store, bot_dir_uuid, "alice.bot")
      iex> entity.name      # display_name with the `.bot` suffix stripped
      "alice"
      iex> entity.persona
      "You are alice. ..."
      iex> entity.trigger_source
      "(?i)@alice\\b\\n^morning\\b"

  `list_in_room/2` enumerates the `*.bot/` entries in a room
  directory — the dispatcher uses it to scan candidates on each
  chat event.
  """

  alias Commonplace.Document.ContentType
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.{DocBuilder, Schema}

  defstruct [
    :name,
    :dir_uuid,
    :persona,
    :memory_uuid,
    :trigger_source,
    :trigger_kind,
    :bot_config,
    :children
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          dir_uuid: String.t(),
          persona: String.t(),
          memory_uuid: String.t(),
          trigger_source: String.t(),
          trigger_kind: :regex | :code,
          bot_config: map(),
          children: %{String.t() => String.t()}
        }

  @required_children ~w(persona.md memory.jsonl trigger.regex)
  @bot_suffix ".bot"

  @doc """
  Load a bot entity from its directory UUID.

  Reconstructs the directory's schema, validates the required
  children are present, reads `persona.md` and `trigger.regex` as
  text, and packages everything as an `%Entity{}`. `memory.jsonl`'s
  UUID is captured (not its contents — the worker reads memory
  lazily through the `read_memory` tool).

  Returns `{:error, {:missing, name}}` for the first missing
  required child, `{:error, :not_a_directory}` if the schema can't
  be reconstructed, or `{:ok, %Entity{}}` on success.

  The `name` field is the bot's display name, with the `.bot`
  suffix stripped. Callers pass it down with the *suffixed* form
  via `dir_entry_name/1` when they need to address the directory
  in a parent schema (e.g. for `author_path`).
  """
  @spec load(module() | atom(), String.t(), String.t()) ::
          {:ok, t()} | {:error, term()}
  def load(store \\ CommitStoreClient, dir_uuid, display_name)
      when is_binary(dir_uuid) and is_binary(display_name) do
    with {:ok, dir_doc} <- reconstruct(store, dir_uuid),
         children <- enumerate_children(dir_doc),
         :ok <- validate_required(children),
         {:ok, persona} <- read_text_child(store, children, "persona.md"),
         {:ok, trigger_source} <- read_text_child(store, children, "trigger.regex"),
         bot_config <- read_bot_config(store, children) do
      {:ok,
       %__MODULE__{
         name: strip_suffix(display_name),
         dir_uuid: dir_uuid,
         persona: persona,
         memory_uuid: Map.fetch!(children, "memory.jsonl"),
         trigger_source: trigger_source,
         trigger_kind: :regex,
         bot_config: bot_config,
         children: children
       }}
    end
  end

  @doc """
  Enumerate the `*.bot/` entries directly under a room directory.

  Returns a list of `%{name: <suffixed-name>, dir_uuid: <uuid>}`
  maps, one per honorific-bot entry. Non-`.bot` entries and
  non-directory entries are filtered out — `.usr` users,
  `.exe` processes, and ordinary files do not participate.
  """
  @spec list_in_room(module() | atom(), String.t()) ::
          {:ok, [%{name: String.t(), dir_uuid: String.t()}]} | {:error, term()}
  def list_in_room(store \\ CommitStoreClient, room_dir_uuid)
      when is_binary(room_dir_uuid) do
    case reconstruct(store, room_dir_uuid) do
      {:ok, doc} ->
        bots =
          doc
          |> Schema.list_entries()
          |> Enum.filter(fn entry ->
            entry.type == :dir and String.ends_with?(entry.name, @bot_suffix)
          end)
          |> Enum.map(fn entry -> %{name: entry.name, dir_uuid: entry.node_id} end)

        {:ok, bots}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Return the suffixed entry-name for an entity (e.g. `"alice.bot"`).

  Useful when constructing an `author_path` for a bot-posted chat
  message — the chat layer's `author_path` is the presence-suffixed
  form, not the stripped display name.
  """
  @spec dir_entry_name(t()) :: String.t()
  def dir_entry_name(%__MODULE__{name: name}), do: name <> @bot_suffix

  defp reconstruct(store, uuid) do
    case DocBuilder.reconstruct_snapshot(store, uuid) do
      {:ok, doc} -> {:ok, doc}
      :none -> {:error, :not_a_directory}
      {:error, _} = err -> err
    end
  end

  defp enumerate_children(dir_doc) do
    dir_doc
    |> Schema.list_entries()
    |> Map.new(fn entry -> {entry.name, entry.node_id} end)
  end

  defp validate_required(children) do
    case Enum.find(@required_children, fn n -> not Map.has_key?(children, n) end) do
      nil -> :ok
      missing -> {:error, {:missing, missing}}
    end
  end

  defp read_text_child(store, children, name) do
    uuid = Map.fetch!(children, name)

    case DocBuilder.reconstruct_snapshot(store, uuid) do
      {:ok, doc} ->
        text = ContentType.get_content(doc) || ""
        {:ok, text}

      :none ->
        {:error, {:unreadable, name}}

      {:error, _} = err ->
        err
    end
  end

  defp read_bot_config(store, children) do
    case Map.get(children, "bot.json") do
      nil ->
        %{}

      uuid ->
        case DocBuilder.reconstruct_snapshot(store, uuid) do
          {:ok, doc} ->
            text = ContentType.get_content(doc) || "{}"

            case Jason.decode(text) do
              {:ok, %{} = m} -> m
              _ -> %{}
            end

          _ ->
            %{}
        end
    end
  end

  defp strip_suffix(name) do
    if String.ends_with?(name, @bot_suffix) do
      String.replace_suffix(name, @bot_suffix, "")
    else
      name
    end
  end
end
