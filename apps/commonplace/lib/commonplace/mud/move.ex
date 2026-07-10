defmodule Commonplace.MUD.Move do
  @moduledoc """
  Cross-doc moves guarded by green tokens — the green channel for real.

  Replaces the retired `MoveServer` (move #4, CX-tdkq.7), whose own
  moduledoc called it a "v0 stand-in for the green channel": instead of
  serializing every move through one `{:global, …}`-registered process
  (the split-brain hazard — `:global` name-conflict resolution on node
  join could kill or orphan the singleton, and a netsplit allowed two),
  each move takes exclusive green tokens on the two directory schemas it
  mutates and runs the same check-then-write sequence under them. No
  singleton, no election; disjoint moves parallelize.

  ## Locking discipline

    * Token names are the source/dest dir-schema UUIDs under a dedicated
      `"move-lock:"` PREFIX (CX-j2wt), acquired in CANONICAL (sorted)
      order. The prefix keeps this EPHEMERAL move-lock in a namespace
      DISJOINT from the DURABLE possession token (`Take`/`HolderMove`
      key those on the bare object uuid, ttl:nil). Without the prefix a
      CONTAINER's own possession token — an `.obj` that both holds a
      permanent token AND is a move endpoint when you `put`/`get ...
      from` it — would squat on the move-lock path at the same uuid, so
      every deposit/withdrawal from a token-holding container would
      `:busy` forever. Deny-on-contention cannot deadlock, but two
      overlapping moves each holding one token could livelock retrying;
      canonical order makes one of them win both.
    * On deny: release whatever was acquired, retry bounded
      (`retries:` × `retry_ms:`), then `{:error, :busy}`.
    * Tokens are released on EVERY exit path — success, `:gone`,
      `:collision`, crash — via `try/after`. The short token TTL
      (`ttl:`, default #{5_000}ms) is only the crash net for a mover
      whose whole BEAM dies mid-move.
    * No bursar reachable → `{:error, :bursar_unavailable}`: fail
      closed, never move unlocked (see `Commonplace.Green.BursarClient`).

  Write ordering within the move is unchanged from v0: dest-add FIRST,
  then source-remove. A crash between the two writes leaves the entry in
  both rooms (recoverable: reaper / manual scrub) rather than nowhere
  (silently lost). See spec §2.4.

  ## Nested containers (CX-cj3t.1.1)

  v1 containers (bags/chests — an `.obj` that can itself hold `.obj`
  children) inherit the tree's concurrent-cross-replica move-cycle
  limitation: `put A in B` on node1 racing `put B in A` on node2 can
  still merge into a self-containing cycle, the same limitation the
  outliner has. Single-replica/single-writer is resolved today by move
  serialization (the bursar move-lock this module already takes, plus
  the `:precheck` cycle-guard hook above); the federated
  multi-replica case is deferred to Kleppmann-move (CX-liim).
  """

  alias Commonplace.Green.{Bursar, BursarClient}
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.Schema
  alias Commonplace.MUD.Schemas, as: MudSchemas
  alias Yelixer.Encoding

  @move_ttl_ms 5_000
  @retries 20
  @retry_ms 50

  @doc """
  Move `thing_uuid` (entry named `name`) from `source_dir_uuid` to
  `dest_dir_uuid` under green tokens.

  Options: `:store` (default `CommitStoreClient`), `:bursar` (default
  the locally/remotely routed `Bursar` — see `BursarClient`), `:ttl`,
  `:retries`, `:retry_ms`.

  Returns `:ok`, `{:error, :gone}` if the entry isn't where we think it
  is, `{:error, :collision}` on a dest name clash, `{:error, :busy}` if
  the dir tokens stayed contended through the retry budget, or
  `{:error, :bursar_unavailable}` when no lock authority is reachable.

  `opts[:precheck]` (CX-cj3t.1.1, nested containers): an optional
  0-arity fun run INSIDE the locked section — after both dir tokens are
  acquired, before `do_move` touches anything. Returning `{:error,
  reason}` aborts the move (no writes happen; tokens still release via
  the existing `after`) and that reason is returned to the caller.
  Absent (the default) preserves prior behavior exactly. This is how
  the container cycle-guard (`Verbs.cycle_guard/3`) gets to run
  atomically under the same bursar lock the move already takes on
  `{source, dest}` — a check-then-move outside the lock would leave a
  TOCTOU window for a concurrent `put` to open a cycle between the
  check and the write.
  """
  def move(thing_uuid, name, source_dir_uuid, dest_dir_uuid, opts \\ [])

  def move(_thing_uuid, _name, source, dest, _opts) when source == dest, do: :ok

  def move(thing_uuid, name, source_dir_uuid, dest_dir_uuid, opts) do
    store = Keyword.get(opts, :store, CommitStoreClient)
    bursar = Keyword.get(opts, :bursar, Bursar)
    ttl = Keyword.get(opts, :ttl, @move_ttl_ms)
    retries = Keyword.get(opts, :retries, @retries)
    retry_ms = Keyword.get(opts, :retry_ms, @retry_ms)
    precheck = Keyword.get(opts, :precheck, fn -> :ok end)

    # CX-lg06: :signing_context / :cert_cids / :signer_id ride along in
    # `opts` (already accepted, previously unused) so both writes below
    # (dest-add, source-remove) land signed/capability-proofed for the
    # target doc each one touches — see `Commonplace.MUD.SignedWrite`.
    # CX-ndvi: :via_verb rides along too (facade-mediated moves tag the
    # resulting commits with `{verb_doc_ref, owner}` for causal audit —
    # see `Commonplace.MUD.SignedWrite.opts_for/2`); absent for every
    # existing (non-facade) caller, so this is additive.
    write_opts = Keyword.take(opts, [:signing_context, :cert_cids, :signer_id, :via_verb])

    holder = default_holder()
    paths = Enum.sort([lock_path(source_dir_uuid), lock_path(dest_dir_uuid)])

    case acquire_all(paths, holder, bursar, ttl, retries, retry_ms) do
      :ok ->
        try do
          case precheck.() do
            :ok -> do_move(thing_uuid, name, source_dir_uuid, dest_dir_uuid, store, write_opts)
            {:error, _} = err -> err
          end
        after
          release_all(paths, holder, bursar)
        end

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Run `fun` while holding the canonical (sorted) bursar move-lock over
  `paths` — the SAME ephemeral, TTL-crash-net, retry-with-backoff lock
  `move/5` takes over its source+dest dirs. Returns `fun`'s result, or
  `{:error, :busy}` if the lock can't be acquired within the retry
  budget.

  This is the SMITH saga's serialization primitive (CX-cj3t items phase
  2): the craft holds ONE lock over the crafter's inventory dir across
  its ENTIRE critical section (validate → mint → consume), so a
  concurrent `move`-backed op on that dir (GIVE/DROP/TAKE, which all lock
  the same dir via `move/5`) cannot slip an input out mid-craft (attack
  S4). The lock is released in an `after` on normal completion; a crash
  mid-craft is released by the TTL crash-net (`:ttl`, default
  `#{@move_ttl_ms}ms`) so a crashed craft never wedges the crafter's
  inventory. Keep the saga well under the TTL (it's a handful of commits).
  """
  @spec with_lock([String.t()], (-> result), keyword()) :: result | {:error, :busy} when result: term()
  def with_lock(paths, fun, opts \\ []) when is_list(paths) and is_function(fun, 0) do
    bursar = Keyword.get(opts, :bursar, Bursar)
    ttl = Keyword.get(opts, :ttl, @move_ttl_ms)
    retries = Keyword.get(opts, :retries, @retries)
    retry_ms = Keyword.get(opts, :retry_ms, @retry_ms)

    holder = default_holder()
    sorted = paths |> Enum.map(&lock_path/1) |> Enum.uniq() |> Enum.sort()

    case acquire_all(sorted, holder, bursar, ttl, retries, retry_ms) do
      :ok ->
        try do
          fun.()
        after
          release_all(sorted, holder, bursar)
        end

      {:error, _} = err ->
        err
    end
  end

  # CX-tdkq.32: the default holder is a NAMED principal, never a free
  # string — prefixed with the node identity so the Bursar's
  # `authenticated_as` binding ties this ephemeral per-move holder to
  # an accountable signer. The pid/ref suffix keeps it unique per
  # concurrent move (multiple moves must not collide on one holder
  # string). Falls back to the old unprefixed form only if the node
  # identity is unavailable, so a move still fails closed rather than
  # crashing.
  defp default_holder do
    case Commonplace.Crypto.NodeIdentity.identity() do
      {:ok, node_identity} -> "#{node_identity}/move-#{inspect(self())}@#{node()}"
      {:error, _} -> "move:#{inspect(self())}@#{node()}"
    end
  end

  # CX-j2wt — the ephemeral move-lock lives under a dedicated prefix, DISJOINT
  # from the durable possession-token namespace (bare object uuid). This is what
  # lets a CONTAINER hold a permanent possession token (mint-at-create) AND still
  # accept `put`/`get ... from` deposits: the deposit's move-lock on the
  # container dir no longer collides with the container's own possession token.
  # Mirrors Mint's `"vein-lock:"` prefix precedent.
  defp lock_path(uuid), do: "move-lock:" <> uuid

  # --- Token discipline ---

  defp acquire_all(paths, holder, bursar, ttl, retries, retry_ms) do
    case try_acquire(paths, holder, bursar, ttl, []) do
      :ok ->
        :ok

      {:denied, got} ->
        release_all(got, holder, bursar)

        if retries > 0 do
          Process.sleep(retry_ms)
          acquire_all(paths, holder, bursar, ttl, retries - 1, retry_ms)
        else
          {:error, :busy}
        end

      {:error, reason, got} ->
        release_all(got, holder, bursar)
        {:error, reason}
    end
  end

  defp try_acquire([], _holder, _bursar, _ttl, _got), do: :ok

  defp try_acquire([path | rest], holder, bursar, ttl, got) do
    case BursarClient.acquire(bursar, path, holder, ttl: ttl, authenticated_as: holder) do
      {:ok, _} -> try_acquire(rest, holder, bursar, ttl, [path | got])
      {:denied, _} -> {:denied, got}
      {:error, reason} -> {:error, reason, got}
    end
  end

  defp release_all(paths, holder, bursar) do
    Enum.each(paths, fn path ->
      BursarClient.release(bursar, path, holder, authenticated_as: holder)
    end)
  end

  # --- The move itself (unchanged from MoveServer v0) ---

  # CX-93ea: dest-add and source-remove are each checked now — if the
  # dest-add is rejected (trust gate under :enforce, or any other
  # create_commit error) we stop before touching source at all. If
  # dest-add lands but source-remove is THEN rejected, the entry is left
  # in both dirs (no rollback — append-only store, no rollback exists;
  # this is the existing crash-recovery case from the moduledoc's
  # "Write ordering" note, just now also reachable via denial instead of
  # only via a mid-move crash) and the error propagates to the caller
  # rather than a false `:ok`.
  defp do_move(thing_uuid, name, source_dir_uuid, dest_dir_uuid, store, write_opts) do
    with {:ok, source_schema} <- MudSchemas.load_dir_schema(source_dir_uuid, store),
         {:ok, %Schema.Entry{} = entry} <- check_still_there(source_schema, name, thing_uuid),
         {:ok, dest_schema} <- MudSchemas.load_dir_schema(dest_dir_uuid, store),
         :ok <- check_no_collision(dest_schema, name),
         :ok <- add_to_dest(dest_dir_uuid, name, entry, store, write_opts),
         :ok <- remove_from_source(source_dir_uuid, name, store, write_opts) do
      :ok
    else
      {:error, _} = err -> err
      :error -> {:error, :gone}
      :none -> {:error, :gone}
    end
  end

  defp check_still_there(schema, name, thing_uuid) do
    case Schema.get_entry(schema, name) do
      {:ok, %Schema.Entry{node_id: ^thing_uuid} = entry} -> {:ok, entry}
      {:ok, %Schema.Entry{}} -> {:error, :gone}
      :error -> {:error, :gone}
    end
  end

  defp check_no_collision(schema, name) do
    case Schema.get_entry(schema, name) do
      :error -> :ok
      {:ok, _} -> {:error, :collision}
    end
  end

  defp add_to_dest(dest_dir_uuid, name, %Schema.Entry{type: type, node_id: node_id}, store, write_opts) do
    {:ok, doc} = MudSchemas.load_dir_schema(dest_dir_uuid, store)

    doc =
      case type do
        :dir -> Schema.add_directory(doc, name, node_id)
        _ -> Schema.add_file(doc, name, node_id)
      end

    update = Encoding.encode_update(doc)

    {metadata, commit_opts} =
      Commonplace.MUD.SignedWrite.opts_for(dest_dir_uuid, Keyword.put(write_opts, :store, store))

    case CommitStoreClient.create_chained_commit(store, dest_dir_uuid, update, metadata, commit_opts) do
      {:error, _} = err -> err
      _commit -> :ok
    end
  end

  defp remove_from_source(source_dir_uuid, name, store, write_opts) do
    {:ok, doc} = MudSchemas.load_dir_schema(source_dir_uuid, store)
    doc = Schema.remove_entry(doc, name)
    update = Encoding.encode_update(doc)

    {metadata, commit_opts} =
      Commonplace.MUD.SignedWrite.opts_for(source_dir_uuid, Keyword.put(write_opts, :store, store))

    case CommitStoreClient.create_chained_commit(store, source_dir_uuid, update, metadata, commit_opts) do
      {:error, _} = err -> err
      _commit -> :ok
    end
  end
end
