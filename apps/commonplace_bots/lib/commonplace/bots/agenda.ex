defmodule Commonplace.Bots.Agenda do
  @moduledoc """
  Camillo slice C3b — the per-bot **agenda doc** (the bot's "desk").

  A native-agent bot that wakes on a heartbeat (see
  `Commonplace.Bots.Dispatcher`'s heartbeat source) needs somewhere to
  keep the work it means to get to: pending consolidations, unfiled
  pins, candidate associations. That place is `agenda.jsonl` — a text
  doc that lives directly under the bot's `<name>.bot/` directory, the
  **sibling of `memory.jsonl`**.

  Like `memory.jsonl`, the agenda is append-only JSONL: one JSON object
  per line, each carrying at least a `"ts"`. The schema is deliberately
  minimal — items are free-form maps. Two axes, deliberately kept apart:

    * `memory.jsonl` — what the bot has learned / wants to recall.
    * `agenda.jsonl` — what the bot still means to *do*.

  ## Bot-signed writes (C1 discipline)

  Every write here is signed by the bot's OWN resolved key, exactly like
  the `remember` tool: the caller threads a `:signing_context` through
  `opts` and it is handed to `CommitStore.create_chained_commit`. A nil
  context degrades to an unsigned write (denied under `:enforce`, an
  honest failure) — never a crash.

  ## Helpers

    * `ensure/3` — return the agenda doc uuid, minting + linking it
      under the bot dir (bot-signed) if absent. Idempotent.
    * `read/2`  — the pending items, parsed JSONL (malformed lines
      skipped), oldest-first.
    * `append/4` — append one item (bot-signed), stamping `"ts"` if the
      caller didn't.
  """

  alias Commonplace.Document.ContentType
  alias Commonplace.Store.{CommitStore, CommitStoreClient}
  alias Commonplace.Tree.{DocBuilder, Schema}

  @doc_name "agenda.jsonl"

  @doc """
  Ensure the bot's `agenda.jsonl` exists; return `{:ok, uuid}`.

  If the entity already carries an `agenda.jsonl` child (or the bot
  directory schema does), that uuid is returned. Otherwise a fresh text
  doc is minted and linked into the bot directory — both writes signed
  with `opts[:signing_context]` when present.
  """
  @spec ensure(Commonplace.Bots.Entity.t(), module() | atom(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def ensure(entity, store \\ CommitStoreClient, opts \\ []) do
    case agenda_uuid(entity, store) do
      uuid when is_binary(uuid) -> {:ok, uuid}
      nil -> mint_and_link(entity, store, opts)
    end
  end

  @doc """
  Read the pending agenda items — parsed JSONL, oldest-first. Malformed
  lines are skipped. A missing / unreadable agenda doc yields `[]`.
  """
  @spec read(Commonplace.Bots.Entity.t(), module() | atom()) :: [map()]
  def read(entity, store \\ CommitStoreClient) do
    case agenda_uuid(entity, store) do
      uuid when is_binary(uuid) ->
        case DocBuilder.reconstruct_snapshot(store, uuid) do
          {:ok, doc} -> parse_lines(ContentType.get_content(doc))
          _ -> []
        end

      nil ->
        []
    end
  end

  @doc """
  Append one item (a free-form map) to the agenda, bot-signed.

  `"ts"` is stamped here if the caller omitted it. Ensures the doc
  exists first (mint-and-link, signed) so a first-ever append is safe.
  """
  @spec append(Commonplace.Bots.Entity.t(), map(), module() | atom(), keyword()) ::
          :ok | {:error, term()}
  def append(entity, item, store \\ CommitStoreClient, opts \\ []) when is_map(item) do
    with {:ok, uuid} <- ensure(entity, store, opts) do
      item =
        Map.put_new_lazy(item, "ts", fn -> DateTime.utc_now() |> DateTime.to_iso8601() end)

      line = Jason.encode!(item) <> "\n"

      case DocBuilder.reconstruct_snapshot(store, uuid) do
        {:ok, doc} ->
          doc = ContentType.insert_text(doc, end_index(doc), line)
          update = Yelixer.Encoding.encode_update(doc)

          CommitStore.create_chained_commit(write_store(store, opts), uuid, update, %{},
            signing_context: Keyword.get(opts, :signing_context)
          )

          :ok

        :none ->
          {:error, :agenda_doc_missing}

        {:error, _} = err ->
          err
      end
    end
  end

  # Resolve the agenda doc uuid: the load-time `entity.children` fast
  # path first, then a fresh reconstruct of the bot dir schema (covers
  # the case where `ensure/3` created it after the entity was loaded).
  defp agenda_uuid(entity, store) do
    case Map.get(entity.children || %{}, @doc_name) do
      uuid when is_binary(uuid) ->
        uuid

      _ ->
        case DocBuilder.reconstruct_snapshot(store, entity.dir_uuid) do
          {:ok, dir_doc} ->
            case Schema.get_entry(dir_doc, @doc_name) do
              {:ok, entry} -> entry.node_id
              :error -> nil
            end

          _ ->
            nil
        end
    end
  end

  defp mint_and_link(entity, store, opts) do
    sc = Keyword.get(opts, :signing_context)
    ws = write_store(store, opts)

    uuid = UUID.uuid4()
    doc = Yelixer.Doc.new()
    doc = ContentType.create(doc, :text, @doc_name)
    update = Yelixer.Encoding.encode_update(doc)
    CommitStore.create_commit(ws, uuid, update, nil, %{}, signing_context: sc)

    case DocBuilder.reconstruct_snapshot(store, entity.dir_uuid) do
      {:ok, dir_doc} ->
        dir_doc = Schema.add_file(dir_doc, @doc_name, uuid)
        dir_update = Yelixer.Encoding.encode_update(dir_doc)

        CommitStore.create_chained_commit(ws, entity.dir_uuid, dir_update, %{},
          signing_context: sc
        )

        {:ok, uuid}

      _ ->
        {:error, :bot_dir_unreadable}
    end
  end

  defp parse_lines(nil), do: []

  defp parse_lines(text) when is_binary(text) do
    text
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case Jason.decode(String.trim(line)) do
        {:ok, %{} = m} -> [m]
        _ -> []
      end
    end)
  end

  defp parse_lines(_), do: []

  defp end_index(doc) do
    case ContentType.get_content(doc) do
      text when is_binary(text) -> String.length(text)
      _ -> 0
    end
  end

  defp write_store(store, opts) do
    Keyword.get(opts, :write_store, real_store(store))
  end

  defp real_store(CommitStoreClient), do: CommitStore
  defp real_store(other), do: other
end
