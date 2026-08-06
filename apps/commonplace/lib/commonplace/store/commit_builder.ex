defmodule Commonplace.Store.CommitBuilder do
  @moduledoc """
  CX-3erd: the single commit-build pipeline, shared by every write path
  so build/sign semantics can never fork between the legacy
  server-serialized path and the hoisted caller-side path.

  This module owns exactly the CPU-bound steps `CommitStore`'s
  `do_write_commit/6` used to run entirely inside its `handle_call`:

    * genesis resolution (CX-fzi / CX-m3x / CX-a04) — including the
      legacy pre-umbrella hatch (nil parent + an existing `:latest`
      keeps the nil parent).
    * `snapshot_parent` metadata stamping (CX-a04) — runs BEFORE
      `Commit.new/4` so the stamped metadata is part of the
      content-addressed hash, never bolted on after.
    * `Commit.new/4` — the content-addressing itself.
    * signing (CX-hoj / CX-tdkq.24/25) — explicit `signing_context`,
      `:unsigned`, or the ambient global-key fallback (with its
      `[:commonplace, :commit, :ambient_signed]` telemetry).

  ## Read-only, never writes

  `build/6` performs only point-reads against `db` (`CubDB.get/2`) —
  the same "reads are safe in any process" contract `CommitStore`
  already relies on for its R4(a) caller-process reads (see that
  module's moduledoc, "CX-tdkq.4"). It writes NOTHING. Callers that
  build caller-side (`CommitStoreClient`, CX-3erd) hand the built
  commit — and, when a genesis was newly resolved, the pure
  `Commit.genesis/1` struct — to `CommitStore.put_built_commit/4`,
  which lands everything atomically inside the store's serialized
  section. `CommitStore.do_write_commit/6` (the retained legacy path)
  calls this same `build/6` and then persists inline, since it's
  already running inside the GenServer.

  There must only ever be ONE implementation of this pipeline —
  duplicating it between the server-side and caller-side paths is
  exactly the bug class this bead exists to prevent.
  """

  alias Commonplace.Store.Commit

  @type build_result :: %{
          commit: Commit.t(),
          genesis: Commit.t() | nil,
          build_ns: non_neg_integer(),
          sign_ns: non_neg_integer()
        }

  @doc """
  Build (and sign) a commit against `db`.

  `parent_id` is the caller-chosen parent — `nil` for genesis-eligible
  writes (`create_commit`'s default, or `create_chained_commit` when
  the doc has no `:latest` yet), or an explicit id otherwise
  (`create_chained_commit`'s observed `:latest`, or any caller-supplied
  explicit parent).

  Returns a map with the built+signed commit; `:genesis` — the pure
  `Commit.genesis/1` struct IFF this build newly resolved a genesis
  parent, `nil` otherwise (see `resolve_genesis/3`); and the CX-9hql
  build/sign phase timings (native time units, per `timed/1`).
  """
  @spec build(term(), String.t(), binary(), binary() | nil, map(), keyword()) :: build_result()
  def build(db, doc_uuid, update, parent_id, metadata, opts \\ []) do
    {resolved_parent_id, genesis} = resolve_genesis(db, doc_uuid, parent_id)
    metadata = stamp_snapshot_parent(db, resolved_parent_id, metadata, genesis)
    post_state_hash = mint_post_state(opts)

    {commit, build_ns} =
      timed(fn ->
        Commit.new(doc_uuid, update, resolved_parent_id, metadata, [], post_state_hash)
      end)

    {commit, sign_ns} =
      timed(fn -> maybe_sign_commit(commit, Keyword.get(opts, :signing_context)) end)

    %{commit: commit, genesis: genesis, build_ns: build_ns, sign_ns: sign_ns}
  end

  # ── Post-state minting (CX-6scm) ──────────────────────────────────
  #
  # The carried expectation must live INSIDE the signed content, so it
  # must exist at `Commit.new`/signing time — which is why minting lives
  # HERE, at the build pipeline, and not at the `put_latest` funnel that
  # writes rows AFTER build+sign.
  #
  # It is per-site THREADING, not one field at one funnel: for a delta
  # writer the post-state is not free (the writer's in-memory doc must be
  # canonically encoded), so the writer that already holds the resulting
  # doc passes it as `post_state:`. Callers that do not — the named
  # legacy-compatible sites, enumerated and guarded by
  # `test/commonplace/projection/mint_source_scan_test.exs` — mint no
  # hash, and their commits project at the corroboration ceiling. That is
  # the whole rollout: observe-then-require, no flag day, the two-grade
  # verdict IS the migration plan.
  defp mint_post_state(opts) do
    case Keyword.get(opts, :post_state) do
      nil -> nil
      state -> Commonplace.Projection.PostState.mint(state)
    end
  end

  @doc "Time a zero-arg function, returning `{result, elapsed_native_time}`."
  @spec timed((-> result)) :: {result, non_neg_integer()} when result: var
  def timed(fun) do
    start = System.monotonic_time()
    result = fun.()
    {result, System.monotonic_time() - start}
  end

  # CX-m3x: if a caller hands us `parent_id=nil` for a doc_uuid that has
  # never been written before, resolve the deterministic genesis and use
  # its id as the parent. Pre-umbrella docs with an existing :latest
  # retain legacy behavior (parent_id stays nil).
  #
  # Unlike the old `CommitStore.maybe_stamp_genesis/3`, this NEVER writes
  # the genesis row — `Commit.genesis/1` is a pure function of doc_uuid,
  # so the struct alone is enough; whichever caller ends up persisting
  # (do_write_commit inline, or put_built_commit's atomic put_multi for
  # the hoisted path) lands the row.
  defp resolve_genesis(_db, _doc_uuid, parent_id) when parent_id != nil, do: {parent_id, nil}

  defp resolve_genesis(db, doc_uuid, nil) do
    case CubDB.get(db, {:latest, doc_uuid}) do
      nil ->
        genesis = Commit.genesis(doc_uuid)
        {genesis.id, genesis}

      _existing ->
        {nil, nil}
    end
  end

  # CX-a04: when the caller produces a `:regular` commit without an
  # explicit `:snapshot_parent`, stamp it from the parent's
  # `current_namespace` (snapshot.id / genesis.id / inherited). Callers
  # that set their own snapshot_parent keep it. Non-`:regular` and
  # legacy `%{}` metadata are untouched.
  #
  # `genesis` (from `resolve_genesis/3`) is threaded through so a
  # freshly-resolved genesis parent can be consulted directly — it is
  # NOT yet persisted to `db` at this point (this function never
  # writes; see the moduledoc), so a plain `CubDB.get` lookup for it
  # would miss.
  defp stamp_snapshot_parent(db, parent_id, %{kind: :regular} = metadata, genesis) do
    if Map.has_key?(metadata, :snapshot_parent) do
      metadata
    else
      case stamp_target(db, parent_id, genesis) do
        nil -> metadata
        sp_id -> Map.put(metadata, :snapshot_parent, sp_id)
      end
    end
  end

  defp stamp_snapshot_parent(_db, _parent_id, metadata, _genesis), do: metadata

  defp stamp_target(_db, nil, _genesis), do: nil

  # The freshly-resolved (not-yet-persisted) genesis IS the parent —
  # consult the in-memory struct instead of reading `db`.
  defp stamp_target(_db, parent_id, %Commit{id: parent_id} = genesis) do
    Commonplace.Store.Namespace.current_namespace(genesis)
  end

  defp stamp_target(db, parent_id, _genesis) do
    case CubDB.get(db, {:commit, parent_id}) do
      nil -> nil
      parent -> Commonplace.Store.Namespace.current_namespace(parent)
    end
  end

  # ── Signing (CX-hoj, CX-o3r7) ─────────────────────────────────────────

  @doc """
  Sign (or deliberately skip signing) `commit` per `signing_context` —
  see `CommitStore`'s moduledoc "Signing" section for the full contract.
  Exposed publicly because the CAS write paths (`write_snapshot_cas/5`,
  `write_prebuilt_commit_cas/2`) call it directly with no context.
  """
  def maybe_sign_commit(commit, signing_context \\ nil)

  # Never re-sign: a commit that already carries a signature (e.g. a
  # remote/prebuilt commit re-written idempotently) keeps its signer.
  def maybe_sign_commit(%Commit{signature: sig} = commit, _) when not is_nil(sig), do: commit

  def maybe_sign_commit(commit, :unsigned), do: commit

  def maybe_sign_commit(commit, %Commonplace.Crypto.SigningContext{} = ctx) do
    sign_with_context(commit, ctx)
  end

  # CX-tdkq.25: system-minted commits (snapshot/merge) are SYSTEM actions —
  # always node-sign them, even when a global user key is configured.
  def maybe_sign_commit(%Commit{metadata: %{kind: kind}} = commit, nil)
      when kind in [:snapshot, :merge] do
    node_sign_if_system(commit)
  end

  # CX-hoj: the global SecretStore fallback is AMBIENT identity. Every
  # actual ambient-sign is made ENUMERABLE via telemetry so un-threaded
  # callers can be found and migrated to an explicit `signing_context`.
  def maybe_sign_commit(commit, nil) do
    case global_secret_context() do
      {:ok, ctx} ->
        signed = sign_with_context(commit, ctx)

        :telemetry.execute(
          [:commonplace, :commit, :ambient_signed],
          %{system_time: System.system_time()},
          %{doc_uuid: signed.doc_uuid, commit_id: signed.id}
        )

        signed

      :none ->
        commit
    end
  end

  defp sign_with_context(commit, ctx) do
    signer_id = Commonplace.Crypto.Signing.signer_id(ctx.identity_uuid, ctx.public_key)
    Commonplace.Crypto.Signing.sign_commit(commit, ctx.private_key, signer_id)
  end

  # Node-sign a system-minted commit; on a node-identity failure the
  # commit is left unchanged (visible under strict mode, not silent).
  defp node_sign_if_system(%Commit{metadata: %{kind: kind}} = commit)
       when kind in [:snapshot, :merge] do
    case Commonplace.Crypto.NodeIdentity.signing_context() do
      {:ok, ctx} -> sign_with_context(commit, ctx)
      {:error, _} -> commit
    end
  end

  defp global_secret_context do
    with pid when is_pid(pid) <- Process.whereis(Commonplace.Store.SecretStore),
         {:ok, encoded_key} <- Commonplace.Store.SecretStore.get("signing_key:default"),
         {:ok, private_key} <- Base.decode64(encoded_key),
         {:ok, encoded_pub} <- Commonplace.Store.SecretStore.get("signing_pub:default"),
         {:ok, public_key} <- Base.decode64(encoded_pub) do
      identity_uuid =
        case Commonplace.Store.SecretStore.get("signing_identity") do
          {:ok, uuid} -> uuid
          :not_found -> "anonymous"
        end

      {:ok,
       %Commonplace.Crypto.SigningContext{
         identity_uuid: identity_uuid,
         private_key: private_key,
         public_key: public_key
       }}
    else
      _ -> :none
    end
  end
end
