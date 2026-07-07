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

  Compilation goes through `Commonplace.Code.SourceDoc.compile/3` which
  caches by content-hash in ETS. Editing a verb changes the hash → next
  call recompiles. That's the v0 hot-reload.

  CX-9f62: every verb compile passes `unique_module: source_uuid`, so the
  author's `defmodule` name is rewritten to a name derived from the verb
  source doc's own uuid before compiling. Two verbs authored under the
  identical `defmodule UserVerb` name (a common author habit — see the
  example above) therefore compile to two DISTINCT modules instead of
  colliding in the global BEAM module table (the "verb-name hijack"
  symptom, where firing verb A on object A could execute verb B's body
  because both had clobbered the same module atom). Callers only ever see
  the returned module atom, so this is fully transparent.

  ## CX-ndvi §4 — this is the LEGACY (trusted) path, UNCHANGED

  Everything above and below this note is the pre-CX-ndvi behavior,
  byte-for-byte: full author-written `defmodule`, gated on `:execute`
  (permissive by default — see `Commonplace.Code.SourceDoc.compile/3`),
  no lint, no facade, ambient `ctx` (today's `World`/`CommitStoreClient`
  reach). This path stays available for TRUSTED/legacy verbs (a
  single-writer jes-prototype world, or any verb an operator has
  reviewed) — CX-ndvi does not remove it or change its gate, its
  compile behavior, or its error shapes in any way.

  The NEW, capability-bounded path lives ALONGSIDE it in this same
  module: `save_safe_verb/6`, `find_safe_source/3`, `compile_safe_verb/4`,
  `run_safe_verb/6` — see `Commonplace.MUD.SafeVerb` for what's
  different (bare `run/1` body instead of `defmodule`, lint, the
  `{:verb, section_scope}` define-gate instead of `:execute`, and a
  `Commonplace.MUD.World.Facade` instead of ambient `ctx`/store reach).
  Safe verbs are stored under a DISTINCT filename
  (`<name>.safe.elx`, vs. legacy's `<name>.elx`) in the same
  `verbs/` directory, so a legacy verb and a safe verb never collide on
  the same name, and existing legacy verb docs are completely
  unaffected by the new path's existence.
  """

  alias Commonplace.Code.SourceDoc
  alias Commonplace.Document.ContentType
  alias Commonplace.MUD.{SafeVerb, Schemas, SignedWrite}
  alias Commonplace.MUD.World.Facade
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
    find_named_source(target_dir_uuid, "#{verb_name}.elx", store)
  end

  # CX-ndvi: shared lookup for both the legacy (`<name>.elx`) and safe
  # (`<name>.safe.elx`) filenames — the directory-registry walk is
  # identical either way, only the filename differs.
  defp find_named_source(target_dir_uuid, file, store) do
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
  CX-ndvi §4 — find the SAFE verb source doc uuid (`<verb_name>.safe.elx`,
  distinct from the legacy `find_source/3`'s `<verb_name>.elx`). Same
  return shape as `find_source/3`.
  """
  @spec find_safe_source(String.t(), String.t(), GenServer.server()) ::
          {:ok, String.t()} | :not_found | {:error, term()}
  def find_safe_source(target_dir_uuid, verb_name, store \\ CommitStoreClient) do
    find_named_source(target_dir_uuid, "#{verb_name}.safe.elx", store)
  end

  @doc """
  Compile (or fetch from cache) the verb at `target_dir_uuid` named
  `verb_name`. Returns `{:ok, module}`, `:not_found`, or
  `{:error, reason}`.
  """
  def compile_verb(target_dir_uuid, verb_name, store \\ CommitStoreClient, opts \\ []) do
    case find_source(target_dir_uuid, verb_name, store) do
      {:ok, source_uuid} ->
        compile_opts = Keyword.merge([unique_module: source_uuid], opts)

        case SourceDoc.compile(source_uuid, store, compile_opts) do
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
  def run_verb(target_dir_uuid, verb_name, ctx, store \\ CommitStoreClient, opts \\ []) do
    case compile_verb(target_dir_uuid, verb_name, store, opts) do
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
      case SourceDoc.compile(source_uuid, store, unique_module: source_uuid) do
        {:ok, module} ->
          if function_exported?(module, :run, 1), do: :ok, else: {:error, {:no_run_export, module}}

        {:error, _} = err ->
          err
      end
    end
  end

  @doc """
  CX-ndvi §3/§4 — compile (or fetch from cache) the SAFE verb at
  `target_dir_uuid` named `verb_name`, gated on `{:verb, section_scope}`
  (CX-ndvi §1.1) rather than `:execute`. `section_scope` is the list of
  anchor uuids (typically `[target_dir_uuid]`, or a wider section list)
  that the verb's owner's `:define_verb` cert must cover — see
  `Commonplace.Trust.DefineVerbGate` for why the anchor is the host
  object/room rather than the verb doc's own fresh uuid.

  Returns `{:ok, module}`, `:not_found`, or `{:error, reason}` —
  `{:error, {:execution_denied, reason}}` on a define-gate denial (a
  revoked/unauthorized definer's verb stops dispatching here, verify-
  time, consistent with CX-bepn).
  """
  @spec compile_safe_verb(String.t(), String.t(), [String.t()], GenServer.server()) ::
          {:ok, module()} | :not_found | {:error, term()}
  def compile_safe_verb(target_dir_uuid, verb_name, section_scope, store \\ CommitStoreClient)
      when is_list(section_scope) do
    case find_safe_source(target_dir_uuid, verb_name, store) do
      {:ok, source_uuid} ->
        case SafeVerb.compile(source_uuid, section_scope, store) do
          {:ok, module} ->
            if function_exported?(module, :run, 2) do
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
  CX-ndvi §2 — run the SAFE verb at `target_dir_uuid` named `verb_name`,
  bound ONLY to `facade` (a `%Commonplace.MUD.World.Facade{}` — the
  invoker's identity + the owner's grant, already closed over) and
  `args`. No `ctx`, no store, no raw uuid reach beyond what the facade
  itself exposes. See `Commonplace.MUD.SafeVerb.run/3` for the
  bounds/error shapes (timeout, heap-kill, runtime error).
  """
  @spec run_safe_verb(String.t(), String.t(), [String.t()], Facade.t(), map(), GenServer.server()) ::
          {:ok, term()} | :not_found | {:error, term()}
  def run_safe_verb(target_dir_uuid, verb_name, section_scope, %Facade{} = facade, args \\ %{}, store \\ CommitStoreClient) do
    case compile_safe_verb(target_dir_uuid, verb_name, section_scope, store) do
      {:ok, module} -> SafeVerb.run(module, facade, args)
      other -> other
    end
  end

  @doc """
  CX-ndvi §4 — save (create or overwrite) a SAFE verb: `body_text` is a
  bare `run/1` BODY (no `defmodule` — see `Commonplace.MUD.SafeVerb`),
  lint-checked before anything is written. Stored (wrapped, per
  `SafeVerb.wrap_and_lint/1`) at `<target_dir_uuid>/verbs/<verb_name>.safe.elx`
  — distinct from the legacy `save_verb/5`'s `<verb_name>.elx`, so the
  two paths never collide on the same verb name.

  Validates by compiling immediately under the `{:verb, section_scope}`
  gate. A lint violation is refused BEFORE anything is written (unlike
  the legacy path, which persists even on a compile error so the author
  can keep editing — a lint violation is a clear, mechanical author
  mistake, not worth round-tripping through a persisted-but-broken doc).

  Returns `:ok`, `{:error, {:lint_violation, reasons}}`,
  `{:error, {:compile_error, msg}}`, `{:error, {:execution_denied, reason}}`
  (define-gate denial), or `{:error, {:no_run_export, module}}`.
  """
  @spec save_safe_verb(String.t(), String.t(), String.t(), [String.t()], GenServer.server(), keyword()) ::
          :ok | {:error, term()}
  def save_safe_verb(target_dir_uuid, verb_name, body_text, section_scope, store \\ CommitStoreClient, opts \\ [])
      when is_binary(body_text) and is_list(section_scope) do
    file = "#{verb_name}.safe.elx"

    with {:ok, wrapped} <- SafeVerb.wrap_and_lint(body_text),
         {:ok, verbs_uuid} <- ensure_verbs_dir(target_dir_uuid, store, opts),
         {:ok, verbs_schema} <- Schemas.load_dir_schema(verbs_uuid, store),
         {:ok, source_uuid} <- save_source(verbs_uuid, verbs_schema, file, wrapped, store, opts) do
      case SafeVerb.compile(source_uuid, section_scope, store) do
        {:ok, module} ->
          if function_exported?(module, :run, 2), do: :ok, else: {:error, {:no_run_export, module}}

        {:error, _} = err ->
          err
      end
    end
  end

  @doc """
  CX-9plf — remove a verb from `target_dir_uuid` (drops BOTH the safe
  `<name>.safe.elx` and legacy `<name>.elx` verbs-dir entries, whichever
  exist). Returns `:ok` if at least one was removed, `:not_found` if
  neither exists / there's no verbs dir, or `{:error, reason}` on a write
  failure. Append-only store: the source docs stay in history; only the
  directory entry is dropped so the verb no longer resolves/dispatches.
  """
  @spec delete_verb(String.t(), String.t(), GenServer.server(), keyword()) ::
          :ok | :not_found | {:error, term()}
  def delete_verb(target_dir_uuid, verb_name, store \\ CommitStoreClient, opts \\ []) do
    with {:ok, schema} <- Schemas.load_dir_schema(target_dir_uuid, store),
         {:ok, %Schema.Entry{node_id: verbs_uuid}} <- Schema.get_entry(schema, @verbs_dir),
         {:ok, verbs_schema} <- Schemas.load_dir_schema(verbs_uuid, store) do
      present =
        ["#{verb_name}.safe.elx", "#{verb_name}.elx"]
        |> Enum.filter(fn f -> match?({:ok, _}, Schema.get_entry(verbs_schema, f)) end)

      if present == [] do
        :not_found
      else
        new_schema = Enum.reduce(present, verbs_schema, fn f, acc -> Schema.remove_entry(acc, f) end)
        update = Encoding.encode_update(new_schema)
        {metadata, commit_opts} = SignedWrite.opts_for(verbs_uuid, Keyword.put(opts, :store, store))

        case CommitStoreClient.create_chained_commit(store, verbs_uuid, update, metadata, commit_opts) do
          {:error, _} = err -> err
          _commit -> :ok
        end
      end
    else
      :error -> :not_found
      {:error, _} = err -> err
      _ -> :not_found
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
