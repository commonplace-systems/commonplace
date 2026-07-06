defmodule Commonplace.MUD.VerbSource do
  @moduledoc """
  Locate, compile, save, and run user-authored MUD verb source docs.

  Verb source lives at `<target_dir>/verbs/<verb_name>.elx` as a
  Yelixer text doc whose body is full Elixir source authoring a
  `Verb` module (or any module name) with a `run/1` function:

      defmodule UserVerb do
        def run(ctx) do
          Commonplace.MUD.World.broadcast_room(
            ctx.current_room_uuid,
            "Alice swirls dramatically.")
          :ok
        end
      end

  Compilation goes through `Commonplace.Code.SourceDoc.compile/2` which
  caches by content-hash in ETS. Editing a verb changes the hash → next
  call recompiles. That's the v0 hot-reload.
  """

  alias Commonplace.Code.SourceDoc
  alias Commonplace.Document.ContentType
  alias Commonplace.MUD.{Schemas, SignedWrite}
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.{DocBuilder, Schema}
  alias Yelixer.Doc, as: YDoc
  alias Yelixer.Encoding

  @verbs_dir "verbs"

  @doc """
  Find the source doc UUID for `verb_name` on `target_dir_uuid`. Returns
  `{:ok, source_uuid}`, `:not_found` if no verb file, or
  `{:error, reason}` on read failure.
  """
  def find_source(target_dir_uuid, verb_name, store \\ CommitStoreClient) do
    file = "#{verb_name}.elx"

    with {:ok, schema} <- Schemas.load_dir_schema(target_dir_uuid, store),
         {:ok, %Schema.Entry{node_id: verbs_uuid}} <- Schema.get_entry(schema, @verbs_dir),
         {:ok, verbs_schema} <- Schemas.load_dir_schema(verbs_uuid, store),
         {:ok, %Schema.Entry{node_id: source_uuid}} <- Schema.get_entry(verbs_schema, file) do
      {:ok, source_uuid}
    else
      :error -> :not_found
      {:error, _} = err -> err
    end
  end

  @doc """
  Compile (or fetch from cache) the verb at `target_dir_uuid` named
  `verb_name`. Returns `{:ok, module}`, `:not_found`, or
  `{:error, reason}`.
  """
  def compile_verb(target_dir_uuid, verb_name, store \\ CommitStoreClient) do
    case find_source(target_dir_uuid, verb_name, store) do
      {:ok, source_uuid} ->
        case SourceDoc.compile(source_uuid, store) do
          {:ok, module} ->
            if function_exported?(module, :run, 1) do
              {:ok, module}
            else
              {:error, {:no_run_export, module}}
            end

          {:error, _} = err ->
            err
        end

      other ->
        other
    end
  end

  @doc """
  Run the verb at `target_dir_uuid` named `verb_name` with the given
  ctx. Returns one of:

    * `{:ok, return_value}` — verb executed (return value is ignored
      by callers in v0; verbs use World handle for I/O)
    * `:not_found`
    * `{:error, {:compile_error, msg}}`
    * `{:error, {:runtime_error, formatted_message}}`

  Compile errors do not crash the caller. Runtime exceptions are
  rescued; callers can emit a verb_error red event with the message.
  """
  def run_verb(target_dir_uuid, verb_name, ctx, store \\ CommitStoreClient) do
    case compile_verb(target_dir_uuid, verb_name, store) do
      {:ok, module} ->
        try do
          {:ok, apply(module, :run, [ctx])}
        rescue
          e ->
            {:error, {:runtime_error, Exception.message(e)}}
        catch
          kind, reason ->
            {:error, {:runtime_error, "#{kind}: #{inspect(reason)}"}}
        end

      :not_found ->
        :not_found

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Save (create or overwrite) verb source for `target_dir_uuid` named
  `verb_name`. Validates by compiling immediately. If compilation fails
  the source is still written (so the author can keep editing) but
  returns `{:error, ...}` for the caller to surface.

  Returns `:ok` or `{:ok, :validated}` on success,
  `{:error, {:compile_error, msg}}` if it doesn't compile,
  `{:error, {:no_run_export, module}}` if it compiles but doesn't
  export run/1.

  `opts` (CX-lg06): `:signing_context`, `:cert_cids`, `:signer_id` — see
  `Commonplace.MUD.SignedWrite`.
  """
  def save_verb(target_dir_uuid, verb_name, source_text, store \\ CommitStoreClient, opts \\ [])
      when is_binary(source_text) do
    file = "#{verb_name}.elx"

    with {:ok, verbs_uuid} <- ensure_verbs_dir(target_dir_uuid, store, opts),
         {:ok, verbs_schema} <- Schemas.load_dir_schema(verbs_uuid, store),
         {:ok, source_uuid} <- save_source(verbs_uuid, verbs_schema, file, source_text, store, opts) do
      case SourceDoc.compile(source_uuid, store) do
        {:ok, module} ->
          if function_exported?(module, :run, 1), do: :ok, else: {:error, {:no_run_export, module}}

        {:error, _} = err ->
          err
      end
    end
  end

  defp save_source(verbs_uuid, verbs_schema, file, source_text, store, opts) do
    case Schema.get_entry(verbs_schema, file) do
      {:ok, %Schema.Entry{node_id: uuid}} ->
        case replace_source_doc(uuid, source_text, store, opts) do
          :ok -> {:ok, uuid}
          {:error, _} = err -> err
        end

      :error ->
        with {:ok, uuid} <- create_source_doc(source_text, store, opts),
             :ok <- add_file_entry(verbs_uuid, file, uuid, store, opts) do
          {:ok, uuid}
        end
    end
  end

  @doc "Read the current source text for a verb (for `@verb` editor pre-fill)."
  def read_source(target_dir_uuid, verb_name, store \\ CommitStoreClient) do
    case find_source(target_dir_uuid, verb_name, store) do
      {:ok, uuid} ->
        case DocBuilder.reconstruct_doc(store, uuid) do
          {:ok, doc} -> {:ok, ContentType.get_content(doc) || ""}
          :none -> {:ok, ""}
        end

      :not_found ->
        {:ok, ""}

      err ->
        err
    end
  end

  ## Private

  defp ensure_verbs_dir(target_dir_uuid, store, opts) do
    {:ok, schema} = Schemas.load_dir_schema(target_dir_uuid, store)

    case Schema.get_entry(schema, @verbs_dir) do
      {:ok, %Schema.Entry{node_id: uuid}} ->
        {:ok, uuid}

      :error ->
        with {:ok, uuid} <- Schemas.create_dir_with_meta(nil, nil, store, opts),
             :ok <- add_directory_entry(target_dir_uuid, @verbs_dir, uuid, store, opts) do
          {:ok, uuid}
        end
    end
  end

  defp create_source_doc(text, store, opts) do
    uuid = UUID.uuid4()
    doc = YDoc.new()
    doc = ContentType.create(doc, :text, "verb")
    doc = ContentType.insert_text(doc, 0, text)
    update = Encoding.encode_update(doc)
    {metadata, commit_opts} = SignedWrite.opts_for(uuid, Keyword.put(opts, :store, store))

    case CommitStoreClient.create_commit(store, uuid, update, nil, metadata, commit_opts) do
      {:error, _} = err -> err
      _commit -> {:ok, uuid}
    end
  end

  defp replace_source_doc(uuid, text, store, opts) do
    hand = SignedWrite.hand_for(uuid, opts)
    {:ok, doc} = DocBuilder.reconstruct_doc(store, uuid, client_id: hand)
    current = ContentType.get_content(doc) || ""
    doc = if current != "", do: ContentType.delete_text(doc, 0, String.length(current)), else: doc
    doc = ContentType.insert_text(doc, 0, text)
    update = Encoding.encode_update(doc)
    {metadata, commit_opts} = SignedWrite.opts_for(uuid, Keyword.put(opts, :store, store))

    case CommitStoreClient.create_chained_commit(store, uuid, update, metadata, commit_opts) do
      {:error, _} = err -> err
      _commit -> :ok
    end
  end

  defp add_file_entry(parent_uuid, name, child_uuid, store, opts) do
    {:ok, schema} = Schemas.load_dir_schema(parent_uuid, store)
    schema = Schema.add_file(schema, name, child_uuid)
    update = Encoding.encode_update(schema)
    {metadata, commit_opts} = SignedWrite.opts_for(parent_uuid, Keyword.put(opts, :store, store))

    case CommitStoreClient.create_chained_commit(store, parent_uuid, update, metadata, commit_opts) do
      {:error, _} = err -> err
      _commit -> :ok
    end
  end

  defp add_directory_entry(parent_uuid, name, child_uuid, store, opts) do
    {:ok, schema} = Schemas.load_dir_schema(parent_uuid, store)
    schema = Schema.add_directory(schema, name, child_uuid)
    update = Encoding.encode_update(schema)
    {metadata, commit_opts} = SignedWrite.opts_for(parent_uuid, Keyword.put(opts, :store, store))

    case CommitStoreClient.create_chained_commit(store, parent_uuid, update, metadata, commit_opts) do
      {:error, _} = err -> err
      _commit -> :ok
    end
  end
end
