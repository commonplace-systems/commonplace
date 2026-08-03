defmodule Commonplace.MUD.Verbs do
  @moduledoc """
  Built-in verbs for MUD v0.

  Verbs receive a `ctx` map (see `Commonplace.MUD.PlayerSession` for the
  shape) and return one of:

    * `:ok` — verb completed, no state change
    * `{:moved, new_room_uuid}` — player moved rooms; session updates
    * `{:reply, text}` — print text to the player's local stdout
    * `{:error, reason_text}` — show error to the player
    * `:unhandled` — verb name unknown to this module

  The session is responsible for interpreting move outcomes and updating
  its in-memory state + Phoenix PubSub subscriptions. All world-visible
  side effects go through `Commonplace.MUD.World`.
  """

  alias Commonplace.MUD.{
    Build,
    ChildMutation,
    EngineModule,
    HelpDoc,
    Mint,
    Parser,
    Render,
    Resolver,
    Schemas,
    SignedWrite,
    VerbSource,
    World
  }
  alias Commonplace.MUD.Schemas.{Object, Player, Room}
  alias Commonplace.MUD.World.Facade
  alias Commonplace.Tree.Schema
  alias Commonplace.Store.{CommitStore, CommitStoreClient}
  alias Commonplace.Trust.{Capability, VerifyChain}

  require Logger

  @builders ~w(@dig @create @destroy @desc @name @alias @listen @dump @verb @unverb @link @unlink @teleport @go @container @private @public)

  # CX-cj3t.5 §1a (CX-66ca) — single source of truth for "is this verb
  # word a builtin" at DISPATCH TIME (not define-time reservation — a
  # user verb named e.g. "take" is simply never reachable, it does not
  # fail to define). Derived from the explicit `dispatch_builtin/3`
  # heads below plus the direction words. MVP FLOOR: builtins-first
  # dispatch (see `dispatch/2`) structurally guarantees a user-authored
  # `@verb` can never shadow/disable a builtin — no player is ever
  # locked out of core commands. The explicit `@builtin take` escape
  # syntax (for a builder who WANTS the builtin despite an override) is
  # plan's Phase 2, not this bead.
  @builtins ~w(look say emote take get drop give put inventory who home quit help go where mine smith recipes) ++
              ~w(examine search read use sit stand) ++
              ~w(north south east west up down in out)

  # CX-z6ub (M2 §3) — the OVERRIDABLE subset of the standard verb set: a
  # room/object may author its OWN sandboxed verb of this name to override the
  # node-signed standard baseline (dispatch = own-verb → standard prototype).
  # Everything else in `@builtins` is LOCKED (builtins-first, un-overridable) —
  # the theft/integrity boundary: `take get drop give put go` (+ directions) can
  # never be shadowed by a citizen verb (so a sandboxed "take" can't intercept
  # possession-transfer), and the system/crafting commands
  # (`who home quit help where inventory mine smith recipes`) stay engine-owned.
  # An override runs SANDBOXED (facade-bound, zone-scoped, no RCE) on its own
  # host; the standard fall-through stays node-trusted. M2.1 seeds the set with
  # the doc-hosted perception/social trio; M2.2 grows it (examine/search/whisper/
  # use/read/open/close/sit/stand/enter/leave) as node prototype verbs.
  #
  # CX-z6ub M2.2 — six standard verb baselines join the overridable set:
  # `examine`/`search`/`read`/`use`/`sit`/`stand`. Each is a node-signed,
  # player-facing baseline (see `do_examine/2`..`do_stand/2`) that a room/object
  # may override with its own sandboxed same-named verb (own-verb → baseline).
  # Deliberately NOT grown here: enter/leave/open/close/whisper (deferred/locked).
  @overridable ~w(look say emote examine search read use sit stand)

  @doc "Dispatch a parsed command. Returns one of the verb-result tuples."
  def dispatch(%Parser.Command{verb: ""}, _ctx), do: :ok

  def dispatch(%Parser.Command{verb: verb} = cmd, ctx) do
    cond do
      verb in @builders ->
        dispatch_builder(verb, cmd, ctx)

      # CX-z6ub (M2 §3) — OVERRIDABLE standard verb: resolve the host's OWN verb
      # FIRST (a sandboxed override), falling through to the node-signed standard
      # baseline (`dispatch_builtin`) when the host has none. Bare invocations
      # resolve on the ROOM host only (not an object scope-scan), so a bare `look`
      # is the room's look/standard — never hijacked by some object's `look` verb.
      overridable?(verb) ->
        case find_override_host(verb, cmd, ctx) do
          {:ok, host_kind, host_uuid, host_name} ->
            run_user_verb(host_kind, host_uuid, host_name, verb, cmd, ctx)

          :not_found ->
            dispatch_builtin(verb, cmd, ctx)
        end

      builtin?(verb) ->
        dispatch_builtin(verb, cmd, ctx)

      true ->
        case dispatch_user_verb(verb, cmd, ctx) do
          :unhandled -> dispatch_builtin(verb, cmd, ctx)
          other -> other
        end
    end
  end

  defp builtin?(verb), do: verb in @builtins

  # CX-z6ub — the OVERRIDABLE subset (⊂ @builtins; checked BEFORE `builtin?` in
  # dispatch so an override is reachable, while LOCKED builtins never are).
  defp overridable?(verb), do: verb in @overridable

  # CX-z6ub — host resolution for an OVERRIDABLE verb: a named, visible target
  # object's OWN verb wins; otherwise (bare, or the target has no such verb) the
  # ROOM host's own verb. Deliberately does NOT scope-scan other objects (unlike
  # `find_verb_by_scope_scan`) — a bare `look`/`say`/`emote` must be the room's,
  # never a stray object's same-named verb. `:not_found` → the standard baseline.
  defp find_override_host(verb_name, cmd, ctx) do
    case verb_target_candidates(cmd, ctx) do
      [] -> room_host_verb(verb_name, ctx)
      candidates -> first_host_with_verb(candidates, verb_name, ctx) || room_host_verb(verb_name, ctx)
    end
  end

  # ---- User-authored verbs (P3, CX-ndvi/CX-cj3t.5) ----

  defp dispatch_user_verb(verb_name, cmd, ctx) do
    case find_verb_in_scope(verb_name, cmd, ctx) do
      {:ok, host_kind, host_uuid, host_name} ->
        run_user_verb(host_kind, host_uuid, host_name, verb_name, cmd, ctx)

      :not_found ->
        :unhandled
    end
  end

  # CX-cj3t.5 §1b (CX-mczs) — resolve by direct-object noun. If
  # `cmd.target` names a visible object (inventory or room, via the
  # SAME name/alias matcher `take`/`give` use), the verb is looked up
  # ONLY on that resolved object — found there, run it there; not found
  # there, `:unhandled` (fall to builtin), never scan other objects. A
  # nil/unmatched target falls back to the old scope scan (object >
  # section-room > world/"here"), unchanged.
  defp find_verb_in_scope(verb_name, cmd, ctx) do
    case verb_target_candidates(cmd, ctx) do
      [] ->
        # No named target (or nothing visible matches it): the old scope scan
        # (object > section-room > world/"here"), unchanged.
        find_verb_by_scope_scan(verb_name, ctx)

      candidates ->
        # A named target resolved to visible object(s). Run the verb on the
        # noun-matching object that HAS it (room-first — CX-bi84). If none of the
        # named objects hosts the verb, fall back to the ROOM host so a room
        # ("here:") verb can still take the object NAME as its argument (CX-ylge);
        # never scan OTHER objects' verb tables (CX-mczs).
        first_host_with_verb(candidates, verb_name, ctx) || room_host_verb(verb_name, ctx)
    end
  end

  # CX-ylge — resolve `verb_name` on the current room host only.
  defp room_host_verb(verb_name, ctx) do
    if verb_source_exists?(ctx.current_room_uuid, verb_name, ctx.store) do
      {:ok, :room, ctx.current_room_uuid, "here"}
    else
      :not_found
    end
  end

  # CX-bi84 — candidate hosts whose NAME matches the command's direct-object
  # noun, ROOM objects BEFORE inventory. A carried item that merely name-matches
  # (often via an alias) must NOT shadow the room object that actually owns the
  # verb — e.g. `unlock vault` while carrying a "vault"-aliased brass key must
  # still reach the room's Warded Vault. `[]` when there is no target noun (a
  # bare verb) or nothing visible matches it.
  defp verb_target_candidates(%Parser.Command{target: nil}, _ctx), do: []

  defp verb_target_candidates(%Parser.Command{target: target}, ctx) do
    [ctx.current_room_uuid, ctx.inventory_uuid]
    |> Enum.flat_map(fn dir ->
      case World.find_entry_by_name(dir, target, ctx.store) do
        {:ok, entry} -> [{entry.node_id, entry.name}]
        :error -> []
      end
    end)
  end

  # CX-bi84 — among the noun-matching candidates (room-first), the FIRST that
  # actually hosts `verb_name`. This is what makes resolution verb-aware: a
  # name-match that lacks the verb can't win over one that has it. `nil` if none
  # host the verb (the caller supplies the fallback).
  defp first_host_with_verb(candidates, verb_name, ctx) do
    Enum.find_value(candidates, fn {uuid, name} ->
      if verb_source_exists?(uuid, verb_name, ctx.store),
        do: {:ok, :object, uuid, name},
        else: nil
    end)
  end

  defp find_verb_by_scope_scan(verb_name, ctx) do
    inventory_objects = World.list_objects_in(ctx.inventory_uuid, ctx.store)
    room_objects = World.list_objects_in(ctx.current_room_uuid, ctx.store)

    candidates =
      Enum.map(inventory_objects, &{:object, &1.node_id, &1.name}) ++
        Enum.map(room_objects, &{:object, &1.node_id, &1.name}) ++
        [{:room, ctx.current_room_uuid, "here"}]

    Enum.find_value(candidates, :not_found, fn {kind, uuid, name} ->
      if verb_source_exists?(uuid, verb_name, ctx.store), do: {:ok, kind, uuid, name}, else: nil
    end)
  end

  # CX-cj3t.5 §1c — a host is a candidate if EITHER a safe (`.safe.elx`)
  # OR a legacy (`.elx`) source exists, so target resolution works for
  # both authoring paths; the safe path takes precedence at RUN time
  # (see `run_user_verb/6`) when both exist on the same host.
  defp verb_source_exists?(uuid, verb_name, store) do
    match?({:ok, _}, VerbSource.find_safe_source(uuid, verb_name, store)) or
      match?({:ok, _}, VerbSource.find_source(uuid, verb_name, store))
  end

  # CX-cj3t.5 §1c/§1d — prefer the SAFE path; fall to the legacy path
  # ONLY on a CLEAN miss (`:not_found` — no `<name>.safe.elx` exists),
  # the intended CX-ndvi §4 migration fallback. A store/read ERROR
  # (`{:error, reason}`) must NEVER silently swap a facade-bounded safe
  # verb for its god-power legacy twin (FLAG A, plan pre-merge FIX 1):
  # a transient failure looking up the safe source must surface as a
  # clean player-facing error, never a downgrade to the ambient-`ctx`
  # legacy path (which would let a store blip escalate a bounded verb to
  # full store/uuid reach).
  defp run_user_verb(host_kind, host_uuid, host_name, verb_name, cmd, ctx) do
    case classify_verb_source(host_uuid, verb_name, ctx.store) do
      {:safe, source_uuid} ->
        run_safe_user_verb(host_kind, host_uuid, host_name, verb_name, source_uuid, cmd, ctx)

      :legacy ->
        run_legacy_user_verb(host_kind, host_uuid, host_name, verb_name, ctx)

      {:error, reason} ->
        {:error, "(verb #{verb_name} unavailable: #{inspect(reason)})"}
    end
  end

  # CX-9plf: drop the leading target-noun words from argv → {rest_argv,
  # rest_string}. Multi-word targets ("silver coin") drop all their words.
  # If argv doesn't start with the target (nil target, or a non-prefix
  # match), rest is the full argv/args unchanged.
  defp verb_rest(%Parser.Command{target: target, argv: argv, args: args}) do
    target_words = String.split(target || "")

    rest_argv =
      if target_words != [] and Enum.take(argv, length(target_words)) == target_words do
        Enum.drop(argv, length(target_words))
      else
        argv
      end

    rest = if rest_argv == argv, do: args, else: Enum.join(rest_argv, " ")
    {rest_argv, rest}
  end

  # CX-cj3t.5 FLAG A / plan pre-merge FIX 1 (SECURITY-CRITICAL) — the
  # safe-vs-legacy SELECTION, factored out so the security-relevant
  # branch decision is directly testable (see the FLAG-A pin in
  # `Commonplace.MUD.VerbsSafeDispatchTest`; a real-dispatch pin can't
  # reach the `{:error, _}` arm because `find_safe_source` and
  # `find_source` share the same verbs-dir load — no real store can make
  # one error while the other succeeds, so the arm is defense-in-depth
  # exercised via this seam).
  #
  # `find_safe_source/3`'s contract is `{:ok, uuid} | :not_found |
  # {:error, term()}`:
  #   * `{:ok, uuid}` → `{:safe, uuid}` — run the facade-bounded path.
  #   * `:not_found`  → `:legacy` — no `<name>.safe.elx`; the intended
  #     CX-ndvi §4 migration fallback to the legacy (ambient-ctx) path.
  #   * `{:error, _}` → `{:error, reason}` — a store/read failure; the
  #     caller surfaces a clean error and MUST NOT fall through to
  #     legacy (no silent facade→god-power downgrade on a transient
  #     read error).
  @doc false
  def classify_verb_source(host_uuid, verb_name, store) do
    case VerbSource.find_safe_source(host_uuid, verb_name, store) do
      {:ok, source_uuid} -> {:safe, source_uuid}
      :not_found -> :legacy
      {:error, reason} -> {:error, reason}
    end
  end

  # CX-cj3t.5 §1d (SECURITY-CRITICAL) — `section_scope` and `owner_grant`
  # are BOTH derived from the RESOLVED host_uuid (the exact tree
  # position dispatch just found this verb at), NEVER from the verb
  # doc's own content. A safe-verb author writes only a bare `run/2`
  # BODY (no `defmodule`, no scope/grant parameters in scope) — there is
  # no channel to inject either; this is structural, not merely policy.
  # A crafted body that names some OTHER uuid as text/a string literal
  # has no way to reach this function's arguments at all.
  defp run_safe_user_verb(host_kind, host_uuid, host_name, verb_name, source_uuid, cmd, ctx) do
    # CX-v6j4 — a verb's "self" (object_uuid, MOO `this`) is the HOST it's
    # authored on, ROOM or object. Binding the room (was nil) lets ROOM verbs
    # persist state / set_attr / create_child on the room (the state-loss fix).
    # `host_kind` gates the OBJECT-ONLY methods (consume/destroy_child/
    # move_object) so they stay OFF room hosts: a room's children are a
    # SHARED, mixed-ownership set (visitors' dropped objects, .usr presence),
    # and destroy_child guards only the PARENT — binding rooms fully would let
    # a room verb destroy a visitor's property on {room} authority alone
    # (cross-owner setuid, deferred). Plan-ruled #6135.
    object_uuid = host_uuid
    section_scope = [host_uuid]
    owner_grant = owner_grant_for(host_uuid, ctx.store)
    via_verb = {source_uuid, host_name}

    facade = %{Facade.new(ctx, object_uuid, owner_grant, via_verb, ctx.store) | host_kind: host_kind}

    # CX-9plf: `rest`/`rest_argv` = the argv with the leading target-noun
    # words dropped, so a parameterized verb ("play box a waltz") can read
    # its trailing parameter as args.rest ("a waltz") without re-stripping
    # the object noun itself (which was awkward boilerplate every verb
    # repeated). `target`/`argv`/`args` are unchanged.
    {rest_argv, rest} = verb_rest(cmd)
    args = %{target: cmd.target, argv: cmd.argv, args: cmd.args, rest: rest, rest_argv: rest_argv}

    host_uuid
    |> VerbSource.run_safe_verb(verb_name, section_scope, facade, args, ctx.store)
    |> map_safe_result(verb_name, ctx)
  end

  # Mirrors `run_legacy_user_verb/5`'s (formerly `run_user_verb/5`)
  # mapping shape one-for-one: `{:ok, _}` → `:ok`; runtime/timeout →
  # a clean player-facing error (never a crash); a define-gate denial
  # (`{:error, {:execution_denied, _}}` — revoked/unauthorized definer,
  # CX-bepn-consistent, checked at VERIFY time on every dispatch) → a
  # clean "verb unavailable" error, the verb never dispatches; `:not_found`
  # → `:unhandled` (defensive — `run_user_verb/6` only calls this branch
  # after `find_safe_source` already returned `{:ok, _}`).
  defp map_safe_result(result, verb_name, ctx) do
    case result do
      # CX-3x5a — the dedicated `{:ok, {:error, :state_bounds}}` (CX-qexv) and
      # `{:ok, {:error, :requires_object_host}}` (CX-a3rq) tail arms are GONE:
      # they were the DENYLIST shape ("surface the drops we thought of"). Those
      # errors now flow through the structural drop-accumulator
      # (`Facade.__accumulate__/2`) and surface as DIM author-diagnostics to
      # the invoker — correctly dim (they are AUTHOR errors), and caught BY
      # CONSTRUCTION whether they land in the tail or an ignored intermediate
      # call. A NEW facade error is visible automatically, no new arm needed.

      # CX-oh5k — a safe verb may have called `Facade.move_self`, which
      # relocates the invoker's `.usr` presence WITHOUT emitting a
      # `{:moved}` signal (unlike the builtin `go`). Reconcile the
      # session's room with the AUTHORITATIVE presence location so the
      # session follows the move instead of ghosting (presence in dest,
      # session stuck in the old room).
      {:ok, _} ->
        reconcile_session_room(ctx)

      {:error, {:compile_error, msg}} ->
        emit_verb_error(verb_name, "compile error: #{msg}", ctx)
        {:error, "(verb #{verb_name} failed to compile)"}

      {:error, :timeout} ->
        emit_verb_error(verb_name, "timed out", ctx)
        {:error, "(verb #{verb_name} timed out)"}

      {:error, {:runtime_error, msg}} ->
        emit_verb_error(verb_name, msg, ctx)
        {:error, "(verb #{verb_name} crashed: #{msg})"}

      {:error, {:execution_denied, _reason}} ->
        {:error, "(verb #{verb_name} is unavailable)"}

      # CX-fhz4 — the run-boundary re-check found the stored content is
      # not the verified substrate wrapper (or its body no longer
      # allowlists). Never crash the dispatch path on this — refuse the
      # verb the same clean way a define-gate denial does.
      {:error, {:unsafe_verb, _reason}} ->
        emit_verb_error(verb_name, "rejected: unsafe", ctx)
        {:error, "(verb #{verb_name} is unavailable)"}

      {:error, {:no_run_export, _}} ->
        {:error, "(verb #{verb_name} has no run/2)"}

      :not_found ->
        :unhandled

      _ ->
        :unhandled
    end
  end

  # CX-oh5k — pure session-state-sync after a successful safe verb.
  # CHEAP PATH FIRST: if the invoker's presence is still an entry in the
  # session's current room, no move happened → `:ok` (one schema read,
  # the common case). Only when the presence is gone from the current
  # room do we walk the tree to locate its new room and emit `{:moved,
  # new_room}` so `PlayerSession.handle_verb_result` re-subscribes and
  # re-renders. If it can't be located (presence gone entirely) → `:ok`
  # (never crash). This writes NOTHING and does not gate the move.
  defp reconcile_session_room(ctx) do
    if presence_in_room?(ctx.current_room_uuid, ctx.presence_filename, ctx.store) do
      :ok
    else
      case World.find_presence_room(ctx.root_uuid, ctx.presence_filename, ctx.store) do
        {:ok, new_room_uuid} -> {:moved, new_room_uuid}
        :not_found -> :ok
      end
    end
  end

  # A read failure defaults to `true` ("still here") so a transient
  # store blip never triggers a spurious relocation.
  defp presence_in_room?(room_uuid, presence_filename, store) do
    case Schemas.load_dir_schema(room_uuid, store) do
      {:ok, schema} ->
        Enum.any?(Schema.list_entries(schema), fn e -> e.name == presence_filename end)

      _ ->
        true
    end
  end

  defp run_legacy_user_verb(host_kind, host_uuid, host_name, verb_name, ctx) do
    verb_ctx = build_user_verb_ctx(host_kind, host_uuid, host_name, ctx)

    # CX-bg1v/CX-qom0 — PLAYER dispatch of a `.elx` verb (a full author
    # module with ambient reach) is gated by the same allowlist waist as
    # safe verbs: `require_safe_wrapper: true` makes `SourceDoc.compile`
    # reject anything that isn't the substrate safe-wrapper (a legacy
    # module fails as `:not_substrate_wrapped`). This closes the residual
    # RCE ingress a permissive world leaves open (the `:execute` gate is
    # vacuous there, and the raw `write` MCP tool can overwrite an
    # existing legacy verb's body). NOTE: only the PLAYER path passes this
    # opt — TickBot's system `run_verb/4` (the "tick" verb) and direct
    # `run_verb` callers do NOT, so trusted/system legacy dispatch is
    # unchanged. Gating those too is CX-qom0 (needs a system-verb→safe
    # migration first).
    case VerbSource.run_verb(host_uuid, verb_name, verb_ctx, ctx.store,
           require_safe_wrapper: true
         ) do
      {:ok, _} ->
        :ok

      {:error, {:unsafe_verb, _reason}} ->
        {:error,
         "(verb #{verb_name} is unavailable — legacy verbs must be re-authored as safe verbs via @verb)"}

      {:error, {:compile_error, msg}} ->
        emit_verb_error(verb_name, "compile error: #{msg}", ctx)
        {:error, "(verb #{verb_name} failed to compile)"}

      {:error, {:runtime_error, msg}} ->
        emit_verb_error(verb_name, msg, ctx)
        {:error, "(verb #{verb_name} crashed: #{msg})"}

      {:error, {:no_run_export, _}} ->
        {:error, "(verb #{verb_name} has no run/1)"}

      :not_found ->
        :unhandled

      _ ->
        :unhandled
    end
  end

  # CX-cj3t.5 §1d-owner (plan-confirmed option (A), #5833) — the safe
  # verb's OWNER-authority ceiling: `write_guarded` (Facade) enforces
  # `scope ⊆ owner_grant` on every facade write. There is NO scope→cert
  # index in this substrate (get-by-CID only), so this mirrors
  # `Commonplace.MUD.Sections.auto_extend_for_new_room/3`'s discovery
  # pattern exactly: walk `host_uuid`'s OWN commit log for
  # `metadata.capability_proof` CIDs and resolve each via
  # `CommitStoreClient.get_capability/2`.
  #
  # RIDER 1 (plan #5833, security-critical) — VERIFIED-CHAINS-ONLY: each
  # discovered cert must PASS `Commonplace.Trust.VerifyChain.verify_chain/3`
  # (the SAME chain-verify path Gate B / the local-write gate use — this
  # now includes the CX-bepn revocation check + chain-tightest expiry)
  # BEFORE its scope contributes to the union. A revoked/expired cert
  # sitting in old commit metadata must NOT keep feeding the owner
  # ceiling — that would be decorative-revocation reborn at verb
  # dispatch, the exact failure shape the CX-bepn watermark catch closed
  # at Gate B.
  #
  # RIDER 2 (plan #5833) — (A)'s derived union is the IMPLICIT DEFAULT
  # ceiling used ONLY when no explicit per-verb grant is attached (design
  # doc Axis B); a future Phase 2 explicit owner-attached grant only ever
  # NARROWS this default, never widens it.
  #
  # BLIND SPOT (mirrors `Sections`' own documented gap, same root cause):
  # discovery is get-by-CID over `host_uuid`'s commit log, so a
  # valid-but-never-yet-used cert covering `host_uuid` is invisible here.
  # Fails CLOSED: the verb is under-authorized in that case (a write that
  # could have succeeded is denied) — never the other direction. Empty/no
  # verified cert found → `owner_grant = MapSet.new([host_uuid])` (the
  # verb can at least touch its own host object).
  defp owner_grant_for(host_uuid, store) do
    start_time = System.monotonic_time()

    certs =
      store
      |> CommitStoreClient.commit_log(host_uuid, limit: CommitStore.max_commit_log_limit())
      |> Enum.map(&get_in(&1.metadata, [:capability_proof]))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.flat_map(fn cid ->
        case CommitStoreClient.get_capability(store, cid) do
          {:ok, cap} -> [cap]
          :none -> []
        end
      end)

    anchors = local_anchor_keys()

    verified_certs =
      Enum.filter(certs, fn cap ->
        match?({:ok, _effective}, VerifyChain.verify_chain(cap.id, anchors, store))
      end)

    verified_scopes = Enum.flat_map(verified_certs, &cert_scope_uuids/1)

    # Hygiene (plan #5833): telemetry for the walk cost per dispatch, so
    # a later per-host_uuid cache decision is data-driven — do NOT
    # pre-build a cache.
    :telemetry.execute(
      [:commonplace, :mud, :owner_grant_walk],
      %{
        duration_native: System.monotonic_time() - start_time,
        cert_count: length(certs),
        verified_cert_count: length(verified_certs)
      },
      %{host_uuid: host_uuid}
    )

    # CX-e12a — the host ALWAYS reaches its OWN meta (the base
    # definer's-rights case: a verb hosted on X writing X's own state, e.g.
    # the altar persisting its own offer), PLUS whatever the verified cert(s)
    # additionally scope (the cross-doc EXTENSION — where the confused-deputy
    # bound lives). The old `scopes -> MapSet.new(scopes)` DROPPED host_uuid
    # whenever any cert existed, so a curated host that gained an owner cert
    # scoped to other docs could no longer write ITSELF → put_state tripped
    # :owner_grant_exceeded → "Nothing happens" → the Convergence went
    # unwinnable (offers never persisted). Unifying to "always host_uuid,
    # plus any cert scopes" restores self-write; strictly additive (the
    # []-branch already granted host_uuid) and widens no cross-doc reach.
    MapSet.new([host_uuid | verified_scopes])
  end

  defp cert_scope_uuids(%Capability{claim: %{scope: {:docs, uuids}}}), do: uuids
  defp cert_scope_uuids(_), do: []

  # `Commonplace.Trust.VerifyChain.verify_chain/3` requires the caller's
  # locally-pinned anchor-key set — the same set `Commonplace.Trust`
  # derives internally (its `anchor_keys/1` is private, and per CX-cj3t.5
  # §3 constraints `trust.ex` is not to be touched to expose it). This is
  # a small, mechanical duplication of that derivation (decode every
  # pinned pubkey from `Trust.config/0`'s PUBLIC config), not a
  # reimplementation of any verification logic — the actual chain/
  # revocation/expiry checks all still run inside `VerifyChain` itself.
  #
  # DUPLICATE of `Commonplace.Trust.anchor_keys/1` (private) — kept in
  # sync BY HAND until CX-2rbz exposes a public accessor and deletes
  # this copy. Any change to the anchor-key derivation in trust.ex MUST
  # be mirrored here (and vice versa) until then.
  defp local_anchor_keys do
    cfg = Commonplace.Trust.config()

    cfg.trusted_identities
    |> Map.values()
    |> Enum.flat_map(&List.wrap/1)
    |> Enum.flat_map(fn encoded ->
      case Commonplace.Crypto.Signing.decode_key(encoded) do
        {:ok, key} -> [key]
        {:error, _} -> []
      end
    end)
    |> MapSet.new()
  end

  defp build_user_verb_ctx(:object, host_uuid, _host_name, ctx) do
    object =
      case Schemas.load_object(host_uuid, ctx.store) do
        {:ok, obj} -> obj
        _ -> nil
      end

    Map.merge(ctx, %{object_uuid: host_uuid, object: object})
  end

  defp build_user_verb_ctx(:room, _host_uuid, _host_name, ctx) do
    Map.merge(ctx, %{object_uuid: nil, object: nil})
  end

  defp emit_verb_error(verb_name, reason, ctx) do
    # Broadcast to bystanders only — the actor gets a separate reply
    # via the dispatch's {:error, ...} return value, so they don't
    # see the same verb_error rendered three times.
    World.broadcast_room(
      ctx.current_room_uuid,
      %{kind: :verb_error, verb: verb_name, reason: reason},
      except: [ctx.player_uuid]
    )
  end

  # ---- Built-in verbs ----

  # CX-aya0 (MUD-as-documents Inc-2 / B1): `look` is the first stateless-leaf
  # verb routed through the doc-hosted `EngineModule` resolver instead of
  # calling `do_look/2` directly. `EngineModule.run_verb/4` resolves a
  # node-signed verb doc (Gate B `:execute`) if the manifest names one,
  # falling back doc-good -> last-good -> the compiled-in floor
  # (`Commonplace.MUD.Verbs.LookFloor`, which itself just calls `do_look/2`
  # below via the `__look_floor__/2` escape hatch) on any compile failure OR
  # runtime crash. `do_look/2` and its private helpers are UNCHANGED and
  # remain the single source of truth for full look behavior; the floor
  # tier guarantees this dispatch clause never regresses even with no
  # manifest entry set (the default today).
  defp dispatch_builtin("look", cmd, ctx), do: EngineModule.run_verb(:look, cmd, ctx, ctx.store)

  # CX-aya0 (MUD-as-documents Inc-2 / B2): `say`/`emote`/`inventory` are the
  # next stateless-leaf cohort routed through the doc-hosted `EngineModule`
  # resolver, same shape as `look` (B1) above — `do_say/2`, `do_emote/2`,
  # `do_inventory/1` and their private helpers are UNCHANGED and remain the
  # single source of truth; each compiled-in floor
  # (`Commonplace.MUD.Verbs.SayFloor`/`EmoteFloor`/`InventoryFloor`) just
  # calls back into them via the `__say_floor__/2` / `__emote_floor__/2` /
  # `__inventory_floor__/2` escape hatches below.
  defp dispatch_builtin("say", cmd, ctx), do: EngineModule.run_verb(:say, cmd, ctx, ctx.store)
  defp dispatch_builtin("emote", cmd, ctx), do: EngineModule.run_verb(:emote, cmd, ctx, ctx.store)
  defp dispatch_builtin("take", cmd, ctx), do: do_take(cmd, ctx)
  defp dispatch_builtin("get", cmd, ctx), do: do_take(cmd, ctx)
  defp dispatch_builtin("drop", cmd, ctx), do: do_drop(cmd, ctx)
  defp dispatch_builtin("give", cmd, ctx), do: do_give(cmd, ctx)
  defp dispatch_builtin("put", cmd, ctx), do: do_put(cmd, ctx)
  defp dispatch_builtin("mine", cmd, ctx), do: do_mine(cmd, ctx)
  defp dispatch_builtin("smith", cmd, ctx), do: do_smith(cmd, ctx)
  # CX-wkau (MUD-as-documents Inc-1, tranche 2): `recipes` joins the
  # doc-hosted stateless-leaf cohort, same `EngineModule.run_verb/4` shape
  # as `where`/`examine`/etc (tranche 1) — `do_recipes/1` is UNCHANGED and
  # remains the single source of truth; the compiled-in floor
  # (`Commonplace.MUD.Verbs.RecipesFloor`) calls back into it via the
  # `__recipes_floor__/2` escape hatch below.
  defp dispatch_builtin("recipes", cmd, ctx), do: EngineModule.run_verb(:recipes, cmd, ctx, ctx.store)
  defp dispatch_builtin("inventory", cmd, ctx), do: EngineModule.run_verb(:inventory, cmd, ctx, ctx.store)

  # CX-wkau (MUD-as-documents Inc-1, tranche 2): `who` joins the doc-hosted
  # cohort too — `do_who/1` is UNCHANGED and remains the single source of
  # truth; the compiled-in floor (`Commonplace.MUD.Verbs.WhoFloor`) calls
  # back into it via the `__who_floor__/2` escape hatch below.
  defp dispatch_builtin("who", cmd, ctx), do: EngineModule.run_verb(:who, cmd, ctx, ctx.store)

  # CX-wkau (MUD-as-documents Inc-1, tranche 3): `home` joins the doc-hosted
  # cohort. TRUST-ADJACENT — `home` moves the player's presence (via
  # `do_home/1` -> `do_teleport/2`, the SAME `World.move_presence/5`
  # CX-avzp read-gated chokepoint `go` uses), so the doc-hosted seed
  # (`priv/engine_verbs/home.exs.seed`) inlines that move logic exactly
  # rather than reimplementing or bypassing the gate; `do_home/1` itself is
  # UNCHANGED and remains the single source of truth for the compiled-in
  # floor (`Commonplace.MUD.Verbs.HomeFloor`), reached via the
  # `__home_floor__/2` escape hatch below.
  defp dispatch_builtin("home", cmd, ctx), do: EngineModule.run_verb(:home, cmd, ctx, ctx.store)
  defp dispatch_builtin("quit", _cmd, _ctx), do: {:reply, :quit}
  # CX-hbb2 — self-hosted: help text is a node-signed CRDT doc (editable
  # without redeploy), read via `HelpDoc.text/1` with the compiled-in floor
  # as a non-brick fallback. See that module's moduledoc for the Gate-B
  # content-defacement defense.
  defp dispatch_builtin("help", _cmd, ctx), do: {:reply, HelpDoc.text(ctx.store)}

  # CX-wkau (MUD-as-documents Inc-1, tranche 3): `go` joins the doc-hosted
  # cohort — the first TRUST-ADJACENT verb (movement routes presence
  # through the CX-avzp read-gated chokepoint, `World.move_presence/5`,
  # which STAYS kernel-side and is called by the seed exactly as `do_go/2`
  # calls it today — see `Commonplace.MUD.Verbs.invoker_move_opts/1`'s doc).
  # `do_go/2` is UNCHANGED and remains the single source of truth; the
  # compiled-in floor (`Commonplace.MUD.Verbs.GoFloor`) calls back into it
  # via the `__go_floor__/2` escape hatch below.
  defp dispatch_builtin("go", cmd, ctx), do: EngineModule.run_verb(:go, cmd, ctx, ctx.store)

  # CX-wkau (MUD-as-documents Inc-1, tranche 1): `where` joins the doc-hosted
  # stateless-leaf cohort (`look`/`say`/`emote`/`inventory`), same
  # `EngineModule.run_verb/4` shape — `do_where/1` is UNCHANGED and remains
  # the single source of truth; the compiled-in floor
  # (`Commonplace.MUD.Verbs.WhereFloor`) calls back into it via the
  # `__where_floor__/2` escape hatch below.
  defp dispatch_builtin("where", cmd, ctx), do: EngineModule.run_verb(:where, cmd, ctx, ctx.store)

  # CX-z6ub M2.2 — the six OVERRIDABLE standard verb baselines. Reached only
  # when the host has no own-verb override (dispatch's `overridable?` branch
  # falls through to here); a citizen's same-named safe verb runs INSTEAD when
  # present. Kept simple and node-owned — the creative surface is the override.
  #
  # CX-wkau (MUD-as-documents Inc-1, tranche 1): `examine`/`search`/`read`/
  # `sit`/`stand` (five of the six) also route through `EngineModule` now,
  # same shape as `where` above — each `do_*/2` stays UNCHANGED, each
  # compiled-in floor (`ExamineFloor`/`SearchFloor`/`ReadFloor`/`SitFloor`/
  # `StandFloor`) calls back via its own `__*_floor__/2` escape hatch below.
  # `use` is left calling `do_use/2` directly — dispatch precedence (an
  # object-verb override reaches this clause only when absent) is UNCHANGED
  # by any of this; only the six BASELINE bodies moved behind the resolver.
  #
  # CX-wkau (MUD-as-documents Inc-1, tranche 2): `use` now also routes
  # through `EngineModule`, same shape — `do_use/2` stays UNCHANGED, the
  # compiled-in floor (`UseFloor`) calls back via `__use_floor__/2` below.
  defp dispatch_builtin("examine", cmd, ctx), do: EngineModule.run_verb(:examine, cmd, ctx, ctx.store)
  defp dispatch_builtin("search", cmd, ctx), do: EngineModule.run_verb(:search, cmd, ctx, ctx.store)
  defp dispatch_builtin("read", cmd, ctx), do: EngineModule.run_verb(:read, cmd, ctx, ctx.store)
  defp dispatch_builtin("use", cmd, ctx), do: EngineModule.run_verb(:use, cmd, ctx, ctx.store)
  defp dispatch_builtin("sit", cmd, ctx), do: EngineModule.run_verb(:sit, cmd, ctx, ctx.store)
  defp dispatch_builtin("stand", cmd, ctx), do: EngineModule.run_verb(:stand, cmd, ctx, ctx.store)

  # CX-wkau (tranche 3): the bare-direction shorthand ("down" etc, parsed as
  # its OWN verb — see `Parser.parse/1`) routes through the SAME doc-hosted
  # `:go` engine name as the explicit `go <direction>` clause above, so a
  # doc-hosted `go` verb governs BOTH invocation shapes identically. `cmd`
  # (not `_cmd`) is threaded through so the resolved module can derive the
  # direction itself — see `__go_floor__/2` and `priv/engine_verbs/go.exs.seed`
  # for the (identical) direction-derivation rule.
  defp dispatch_builtin(dir, cmd, ctx) when dir in ~w(north south east west up down in out) do
    EngineModule.run_verb(:go, cmd, ctx, ctx.store)
  end

  defp dispatch_builtin(_verb, _cmd, _ctx), do: :unhandled

  # ---- look ----

  # CX-aya0 (B1): the ONLY external caller of `do_look/2` — used
  # exclusively by `Commonplace.MUD.Verbs.LookFloor` (the EngineModule
  # compiled-in floor for the doc-hosted `look` verb). `do_look/2` itself
  # stays private; routing the floor through this one-line delegator means
  # the floor and the "real" look behavior can never drift out of parity —
  # there is exactly one implementation, this just exposes a call path to it.
  @doc false
  def __look_floor__(cmd, ctx), do: do_look(cmd, ctx)

  # CX-aya0 (B2): the ONLY external callers of `do_say/2`, `do_emote/2`, and
  # `do_inventory/1` — used exclusively by `Commonplace.MUD.Verbs.SayFloor`,
  # `EmoteFloor`, and `InventoryFloor` (the `EngineModule` compiled-in floors
  # for the doc-hosted `say`/`emote`/`inventory` verbs). Each stays private;
  # routing the floor through these one-line delegators means the floor and
  # the "real" verb behavior can never drift out of parity — there is
  # exactly one implementation of each, this just exposes a call path to it.
  # `do_inventory/1` takes only `ctx` (no `cmd`), so its hatch ignores `cmd`
  # to match the `module.run(cmd, ctx)` shape `EngineModule` expects.
  @doc false
  def __say_floor__(cmd, ctx), do: do_say(cmd, ctx)

  @doc false
  def __emote_floor__(cmd, ctx), do: do_emote(cmd, ctx)

  @doc false
  def __inventory_floor__(_cmd, ctx), do: do_inventory(ctx)

  # CX-wkau (MUD-as-documents Inc-1, tranche 1): the ONLY external callers of
  # `do_where/1`, `do_examine/2`, `do_search/2`, `do_read/2`, `do_sit/2`, and
  # `do_stand/2` — used exclusively by the six matching `EngineModule`
  # compiled-in floors (`WhereFloor`/`ExamineFloor`/`SearchFloor`/
  # `ReadFloor`/`SitFloor`/`StandFloor`). Each stays private; routing the
  # floor through these one-line delegators means the floor and the "real"
  # verb behavior can never drift out of parity — exactly one implementation
  # of each, this just exposes a call path to it. `do_where/1` and
  # `do_search/2` (search ignores both args) don't need `cmd`/`ctx` in the
  # same shape as the others; each hatch adapts to the `module.run(cmd, ctx)`
  # shape `EngineModule` expects.
  @doc false
  def __where_floor__(_cmd, ctx), do: Render.do_where(ctx)

  @doc false
  def __examine_floor__(cmd, ctx), do: do_examine(cmd, ctx)

  @doc false
  def __search_floor__(cmd, ctx), do: do_search(cmd, ctx)

  @doc false
  def __read_floor__(cmd, ctx), do: do_read(cmd, ctx)

  @doc false
  def __sit_floor__(cmd, ctx), do: do_sit(cmd, ctx)

  @doc false
  def __stand_floor__(cmd, ctx), do: do_stand(cmd, ctx)

  # CX-wkau (MUD-as-documents Inc-1, tranche 2): the ONLY external callers of
  # `do_use/2`, `do_recipes/1`, and `do_who/1` — used exclusively by the
  # matching `EngineModule` compiled-in floors (`UseFloor`/`RecipesFloor`/
  # `WhoFloor`). Each stays private; routing the floor through these
  # one-line delegators means the floor and the "real" verb behavior can
  # never drift out of parity — exactly one implementation of each, this
  # just exposes a call path to it. `do_recipes/1` and `do_who/1` take only
  # `ctx` (no `cmd`), so their hatches ignore `cmd` to match the
  # `module.run(cmd, ctx)` shape `EngineModule` expects.
  @doc false
  def __use_floor__(cmd, ctx), do: do_use(cmd, ctx)

  @doc false
  def __recipes_floor__(_cmd, ctx), do: do_recipes(ctx)

  @doc false
  def __who_floor__(_cmd, ctx), do: do_who(ctx)

  # CX-wkau (MUD-as-documents Inc-1, tranche 3): the ONLY external callers of
  # `do_go/2` and `do_home/1` — used exclusively by the matching `EngineModule`
  # compiled-in floors (`GoFloor`/`HomeFloor`). Each stays private; routing the
  # floor through these one-line delegators means the floor and the "real"
  # verb behavior can never drift out of parity. `__go_floor__/2` derives the
  # direction from `cmd` FIRST — a bare direction word (e.g. "down") parses as
  # its OWN verb (`cmd.verb`), while the explicit `go <direction>` form carries
  # it in `cmd.argv` — mirroring `priv/engine_verbs/go.exs.seed`'s derivation
  # EXACTLY (both must agree, or the doc path and the floor path diverge on
  # which direction they move).
  @doc false
  def __go_floor__(cmd, ctx) do
    direction =
      if cmd.verb in ~w(north south east west up down in out) do
        cmd.verb
      else
        List.first(cmd.argv)
      end

    do_go(direction, ctx)
  end

  @doc false
  def __home_floor__(_cmd, ctx), do: do_home(ctx)

  defp do_look(%Parser.Command{argv: []}, ctx) do
    {:reply, Render.render_room(ctx)}
  end

  defp do_look(%Parser.Command{target: target}, ctx) when target in ["here", "room"] do
    {:reply, Render.render_room(ctx)}
  end

  defp do_look(%Parser.Command{target: target}, ctx) when target in ["me", "self", "myself"] do
    case Schemas.load_player(ctx.player_dir_uuid, ctx.store) do
      {:ok, %Player{} = pl} ->
        title = if pl.title == "", do: pl.name, else: pl.title
        {:reply, "#{title}\n#{pl.description}"}

      _ ->
        {:reply, ctx.player_name}
    end
  end

  # CX-cj3t.1.1: "look in <container>" is the explicit form for
  # container contents — split the leading "in" off and resolve the
  # rest as a container (room/inventory), same resolver `put`/`get
  # ... from` use.
  defp do_look(%Parser.Command{argv: ["in" | rest]}, ctx) when rest != [] do
    Render.do_look_in_container(rest, ctx)
  end

  defp do_look(%Parser.Command{argv: argv}, ctx) do
    phrase_label = Enum.join(argv, " ")

    case Resolver.greedy_match_entry([ctx.inventory_uuid, ctx.current_room_uuid], argv, ctx.store) do
      {:ok, entry, _phrase, _remainder} ->
        Render.render_looked_at_entry(entry, phrase_label, ctx)

      :not_found ->
        {:error, "You don't see \"#{phrase_label}\" here."}
    end
  end

  # CX-cj3t.8 (safe half) — a container is LOCKED iff its freeform state
  # submap has state["locked"] == true (composes with put_state: a key-verb
  # flips it via put_state(world, "locked", false)). Strict true; any other
  # value = unlocked (fail-open — a gameplay gate, not a security boundary;
  # the real gate is write-access, which a non-owner lacks). No new Facade
  # primitive, no schema change.
  #
  # HONESTY (plan #6009): a locked container "hides" its contents ONLY
  # in-game (the `look in` command refuses). This is NOT confidentiality —
  # the container's dir/contents sync as CRDT data, so a peer syncing that
  # subtree reads the contents from the raw substrate regardless of the
  # lock. Gameplay gate, not secrecy; do NOT build hidden-info mechanics on
  # it. And "a key = a granted verb that put_states locked=false" works for
  # the OWNER + co-builders granted chest-write (put_state is
  # write_guarded([chest]) = intersection), NOT an arbitrary VISITOR —
  # visitor-usable keys are the deferred setuid / before_get-hook tiers
  # (CX-spyc / the high-trust hook bead).
  #
  # CX-ud1u (rendering extraction): the container-LOCKED/lock_key READS
  # moved to `Commonplace.MUD.Render` (they back the `container_sealed?`
  # look-hiding decision there); these two MUTATION-path gates stay here
  # since `do_get_from`/`put_item_in` are dispatch, not rendering, and now
  # call through to `Render`'s public reads unchanged.
  defp ensure_unlocked(container_uuid, name, store) do
    if Render.container_locked?(container_uuid, store), do: {:error, {:locked, name}}, else: :ok
  end

  defp ensure_has_key(container_uuid, name, ctx) do
    case Render.container_lock_key(container_uuid, ctx.store) do
      {:ok, key} ->
        if match?({:ok, _}, World.find_entry_by_name(ctx.inventory_uuid, key, ctx.store)),
          do: :ok,
          else: {:error, {:need_key, name, key}}

      :none ->
        :ok
    end
  end

  # ---- examine / search / read / use / sit / stand (CX-z6ub M2.2) ----
  #
  # Six OVERRIDABLE standard verb baselines: node-signed, player-facing, and
  # deliberately minimal — a room/object overrides them with its own sandboxed
  # verb to add world-specific behavior. All reuse the existing target
  # resolution (`greedy_match_entry`/`resolve_entry`) and return the same
  # `{:reply, _}` / `{:error, _}` / `:ok` shapes the neighboring builtins do.

  # examine <obj>: a detailed look — name + full description + any notable
  # `meta["state"]`. Models on `do_look`'s object path; players/objects only.
  defp do_examine(%Parser.Command{argv: []}, _ctx), do: {:error, "Examine what?"}

  defp do_examine(%Parser.Command{argv: argv}, ctx) do
    phrase_label = Enum.join(argv, " ")

    case Resolver.greedy_match_entry([ctx.inventory_uuid, ctx.current_room_uuid], argv, ctx.store) do
      {:ok, entry, _phrase, _remainder} ->
        Render.render_examined_entry(entry, phrase_label, ctx)

      :not_found ->
        {:error, "You don't see \"#{phrase_label}\" here."}
    end
  end

  # read <obj>: reads `meta["state"]["text"]` if present, else the object's
  # description, else a nothing-to-read note.
  defp do_read(%Parser.Command{argv: []}, _ctx), do: {:error, "Read what?"}

  defp do_read(%Parser.Command{argv: argv}, ctx) do
    phrase_label = Enum.join(argv, " ")

    case Resolver.greedy_match_entry([ctx.inventory_uuid, ctx.current_room_uuid], argv, ctx.store) do
      {:ok, entry, _phrase, _remainder} ->
        case Resolver.resolve_entry(entry, ctx) do
          {:ok, :object, %Object{} = obj} -> {:reply, Render.read_object_text(entry.node_id, obj, ctx)}
          _ -> {:reply, "There's nothing to read on #{phrase_label}."}
        end

      :not_found ->
        {:error, "You don't see \"#{phrase_label}\" here."}
    end
  end

  # search: a plain baseline — authors override to reveal hidden things.
  # Works bare or with a target.
  defp do_search(_cmd, _ctx), do: {:reply, "You search but find nothing of note."}

  # use <obj>: the creative hook — the node baseline does nothing; authors
  # override to make an object do something.
  defp do_use(%Parser.Command{argv: []}, _ctx), do: {:error, "Use what?"}
  defp do_use(%Parser.Command{argv: _argv}, _ctx), do: {:reply, "Nothing happens."}

  # sit / stand: a reply to the actor plus a room action broadcast to
  # bystanders — reuses the SAME `emote` broadcast mechanism
  # (`World.broadcast_room` + `kind: :emote`, third-person text). `except:
  # [player_uuid]` suppresses the actor's own emote echo so they see only the
  # first-person reply (the emote render otherwise echoes to the actor too).
  defp do_sit(_cmd, ctx) do
    broadcast_self_action("sits down.", ctx)
    {:reply, "You sit down."}
  end

  defp do_stand(_cmd, ctx) do
    broadcast_self_action("stands up.", ctx)
    {:reply, "You stand up."}
  end

  defp broadcast_self_action(text, ctx) do
    World.broadcast_room(
      ctx.current_room_uuid,
      %{kind: :emote, who: ctx.player_name, text: text},
      except: [ctx.player_uuid]
    )
  end

  # ---- say / emote ----

  defp do_say(%Parser.Command{args: ""}, _ctx), do: {:error, "Say what?"}

  defp do_say(%Parser.Command{args: text}, ctx) do
    World.broadcast_room(ctx.current_room_uuid, %{kind: :say, who: ctx.player_name, text: text})
    :ok
  end

  defp do_emote(%Parser.Command{args: ""}, _ctx), do: {:error, "Emote what?"}

  defp do_emote(%Parser.Command{args: text}, ctx) do
    World.broadcast_room(ctx.current_room_uuid, %{kind: :emote, who: ctx.player_name, text: text})
    :ok
  end

  # ---- take / drop / give ----

  defp do_take(%Parser.Command{argv: []}, _ctx), do: {:error, "Take what?"}

  # CX-cj3t.1.1: "take/get <item> from <container>" routes to the
  # container-aware path; plain "take <item>" (no "from") keeps the
  # existing room-only behavior below untouched.
  defp do_take(%Parser.Command{argv: argv}, ctx) do
    case split_on_from(argv) do
      {item_words, container_words} when item_words != [] and container_words != [] ->
        do_get_from(item_words, container_words, ctx)

      _ ->
        do_take_plain(argv, ctx)
    end
  end

  defp split_on_from(argv) do
    case Enum.split_while(argv, fn w -> String.downcase(w) != "from" end) do
      {item_words, [_from | rest]} -> {item_words, rest}
      {_all, []} -> {argv, []}
    end
  end

  defp do_get_from(item_words, container_words, ctx) do
    item_phrase_label = Enum.join(item_words, " ")
    container_phrase = Enum.join(container_words, " ")

    with {:ok, container_entry, %Object{} = container_obj} <-
           Resolver.resolve_container(container_phrase, [ctx.current_room_uuid, ctx.inventory_uuid], ctx),
         :ok <- ensure_unlocked(container_entry.node_id, container_obj.name, ctx.store),
         :ok <- ensure_has_key(container_entry.node_id, container_obj.name, ctx),
         {:ok, entry, _phrase, _remainder} <-
           Resolver.greedy_match_entry([container_entry.node_id], item_words, ctx.store),
         {:ok, %Object{} = obj} <- Schemas.load_object(entry.node_id, ctx.store),
         :ok <-
           World.take_item(entry.node_id, entry.name, container_entry.node_id,
             ctx.inventory_uuid, taker_identity(ctx), take_opts(ctx)) do
      World.broadcast_room(ctx.current_room_uuid, %{
        kind: :get_from,
        who: ctx.player_name,
        what: obj.name,
        from: container_obj.name
      })

      {:reply, "You get #{obj.name} from #{container_obj.name}."}
    else
      {:error, {:not_a_container, name}} -> {:error, "You can't get things from the #{name}."}
      {:error, {:locked, name}} -> {:error, "The #{name} is locked."}
      {:error, {:need_key, name, key}} -> {:error, "The #{name} won't open — you need the #{key}."}
      {:error, :not_found} -> {:error, "You don't see \"#{container_phrase}\" here."}
      :not_found -> {:error, "You don't see \"#{item_phrase_label}\" in #{container_phrase}."}
      {:error, :gone} -> {:error, "It slipped from your grasp."}
      {:error, :collision} -> {:error, "You're already carrying one of those."}
      {:error, {:trust_rejected, _}} -> {:error, "You don't have permission to take that."}
      {:error, :taken} -> {:error, "Someone else grabbed it first."}
      {:error, :item_unavailable} -> {:error, "Someone else grabbed it first."}
      # CX-cogd — an HONEST deny that matches the put path's permission language,
      # not the vague "You can't take that": a container in a zone you can't
      # write refuses extraction (the citizen-home private-container case). The
      # {:trust_rejected, _} clause below already speaks the same language.
      {:error, :not_takeable_here} -> {:error, "You don't have permission to take that."}
      {:error, :bad_arg} -> {:error, "You can't take that."}
      {:error, :fixed} -> {:error, "That's fixed in place."}
      _ -> {:error, "You can't take that."}
    end
  end

  # CX-8iyv: greedy-match the full remaining phrase against room entries
  # (names + aliases) so multi-word object names/aliases resolve
  # ('take silver coin' matches an object named/aliased "silver coin"),
  # not just the first word.
  defp do_take_plain(argv, ctx) do
    phrase_label = Enum.join(argv, " ")

    with {:ok, entry, _phrase, _remainder} <- Resolver.greedy_match_entry([ctx.current_room_uuid], argv, ctx.store),
         true <- takable_entry?(entry) || {:error, "You can't take that."},
         {:ok, %Object{} = obj} <- Schemas.load_object(entry.node_id, ctx.store),
         :ok <- ensure_not_fixed(obj),
         :ok <- World.take_item(entry.node_id, entry.name, ctx.current_room_uuid,
                  ctx.inventory_uuid, taker_identity(ctx), take_opts(ctx)) do
      World.broadcast_room(ctx.current_room_uuid, %{
        kind: :take,
        who: ctx.player_name,
        what: obj.name
      })

      {:reply, "You take #{obj.name}."}
    else
      :not_found -> {:error, "You don't see \"#{phrase_label}\" here."}
      {:error, :gone} -> {:error, "Someone else grabbed it first."}
      {:error, :collision} -> {:error, "You're already carrying one of those."}
      {:error, {:trust_rejected, _}} -> {:error, "You don't have permission to take that."}
      {:error, :taken} -> {:error, "Someone else grabbed it first."}
      {:error, :item_unavailable} -> {:error, "Someone else grabbed it first."}
      {:error, :not_takeable_here} -> {:error, "You can't take that."}
      {:error, :bad_arg} -> {:error, "You can't take that."}
      {:error, msg} when is_binary(msg) -> {:error, msg}
      _ -> {:error, "You can't take that."}
    end
  end

  defp takable_entry?(%Schema.Entry{type: :dir, name: name}), do: String.ends_with?(name, ".obj")
  defp takable_entry?(_), do: false

  # ---- mine (CX-cj3t items epic phase 2) ----
  #
  # MINE resolves a vein in the current room, then runs the lazy-regen
  # decrement + mint ELEVATED (node authority — the vein meta is
  # node-owned, the miner has no write authority over it) via
  # `Commonplace.MUD.Mint.extract_from_vein/4`. See that module's
  # moduledoc for the vein-lock + structural decrement-only guard.
  defp do_mine(%Parser.Command{argv: []}, _ctx), do: {:error, "Mine what?"}

  defp do_mine(%Parser.Command{argv: argv}, ctx) do
    phrase_label = Enum.join(argv, " ")

    with {:ok, entry, _phrase, _remainder} <- Resolver.greedy_match_entry([ctx.current_room_uuid], argv, ctx.store),
         {:ok, %Object{kind: "vein"} = vein} <- Schemas.load_object(entry.node_id, ctx.store),
         {:ok, _item_uuid, item_name} <-
           Mint.extract_from_vein(entry.node_id, ctx.inventory_uuid, taker_identity(ctx), take_opts(ctx)) do
      World.broadcast_room(ctx.current_room_uuid, %{
        kind: :mine,
        who: ctx.player_name,
        what: item_name,
        from: vein.name
      })

      {:reply, "You extract #{item_name} from the #{vein.name}."}
    else
      :not_found -> {:error, "You don't see \"#{phrase_label}\" here."}
      {:ok, %Object{}} -> {:error, "There's nothing to mine there."}
      {:error, :not_a_vein} -> {:error, "There's nothing to mine there."}
      {:error, :depleted} -> {:error, "The vein is spent."}
      {:error, :bad_arg} -> {:error, "You can't mine that."}
      {:error, :busy} -> {:error, "Someone else is mining that right now."}
      {:error, _} -> {:error, "You can't mine that right now."}
    end
  end

  # CX-cj3t items phase 2 — SMITH: consume a recipe's declared inputs, mint
  # its output. The saga (mint-before-consume under an inventory-dir lock)
  # lives in `Commonplace.MUD.Mint.smith/4`; this is the thin verb face.
  defp do_smith(%Parser.Command{argv: []}, _ctx) do
    {:error, "Smith what? Try: smith <recipe>  (see 'recipes')."}
  end

  defp do_smith(%Parser.Command{argv: argv}, ctx) do
    recipe_name = Enum.join(argv, " ")

    case Mint.smith(recipe_name, ctx.inventory_uuid, taker_identity(ctx),
           root_uuid: ctx.root_uuid,
           store: ctx.store
         ) do
      {:ok, output_name} ->
        World.broadcast_room(ctx.current_room_uuid, %{
          kind: :smith,
          who: ctx.player_name,
          what: output_name
        })

        {:reply, "You craft #{output_name}."}

      {:error, :no_recipe} ->
        {:error, "You don't know how to make \"#{recipe_name}\"."}

      {:error, {:missing_input, type}} ->
        {:error, "You don't have the #{type} you need for that."}

      {:error, :bad_arg} ->
        {:error, "You can't craft that."}

      {:error, :busy} ->
        {:error, "Your hands are too full right now — try again."}

      _ ->
        {:error, "The crafting fails."}
    end
  end

  # `recipes` — list the curated recipes + their inputs so a player can
  # see what a craft will consume BEFORE committing (informed consent).
  defp do_recipes(ctx) do
    case Mint.list_recipes(ctx.root_uuid, ctx.store) do
      [] ->
        {:reply, "No recipes are known here."}

      recipes ->
        lines =
          Enum.map(recipes, fn r ->
            inputs =
              r.inputs
              |> Enum.map(fn i -> "#{Map.get(i, "qty", 1)}× #{Map.get(i, "type", "?")}" end)
              |> Enum.join(", ")

            out = Map.get(r.output, "name", Map.get(r.output, :name, "item"))
            "  #{r.name}: #{inputs} → #{out}"
          end)

        {:reply, "Recipes:\n" <> Enum.join(lines, "\n")}
    end
  end

  defp ensure_not_fixed(%Object{fixed: true, name: name}), do: {:error, "#{name} is fixed in place."}
  defp ensure_not_fixed(_), do: :ok

  defp do_drop(%Parser.Command{argv: []}, _ctx), do: {:error, "Drop what?"}

  # CX-8iyv: greedy-match the full remaining phrase against inventory
  # entries (names + aliases), same rationale as `do_take/2`.
  defp do_drop(%Parser.Command{argv: argv}, ctx) do
    phrase_label = Enum.join(argv, " ")

    with {:ok, entry, _phrase, _remainder} <- Resolver.greedy_match_entry([ctx.inventory_uuid], argv, ctx.store),
         {:ok, %Object{} = obj} <- Schemas.load_object(entry.node_id, ctx.store),
         :ok <-
           World.drop_item(entry.node_id, entry.name, ctx.inventory_uuid, ctx.current_room_uuid, taker_identity(ctx), possession_opts(ctx)) do
      World.broadcast_room(ctx.current_room_uuid, %{
        kind: :drop,
        who: ctx.player_name,
        what: obj.name
      })

      {:reply, "You drop #{obj.name}."}
    else
      :not_found -> {:error, "You aren't carrying \"#{phrase_label}\"."}
      {:error, :collision} -> {:error, "There's already one of those here."}
      {:error, :gone} -> {:error, "It slipped from your grasp."}
      {:error, {:trust_rejected, _}} -> {:error, "You don't have permission to drop that here."}
      {:error, :not_holder} -> {:error, "You aren't carrying that."}
      {:error, :bad_arg} -> {:error, "You can't drop that."}
      _ -> {:error, "You can't drop that."}
    end
  end

  defp do_give(%Parser.Command{argv: argv}, _ctx) when length(argv) < 2 do
    {:error, "Give what to whom? Try: give <item> to <player>"}
  end

  # CX-8iyv: give syntax rule — both item and recipient may be multi-word
  # ('give silver coin to tester'). The word "to" is the robust
  # disambiguator between the two phrases: split on the first standalone
  # "to" and use everything before/after verbatim. Without a "to", fall
  # back to best-effort: greedy-match the item from the front against
  # inventory (longest matching phrase wins), and treat whatever argv
  # words remain as the recipient phrase — this keeps the pre-existing
  # single-word syntax ('give cloak bob') working unchanged.
  defp do_give(%Parser.Command{argv: argv}, ctx) do
    case split_on_to(argv) do
      {item_words, target_words} when item_words != [] and target_words != [] ->
        give_item_to(Enum.join(item_words, " "), Enum.join(target_words, " "), ctx)

      _ ->
        do_give_greedy(argv, ctx)
    end
  end

  defp split_on_to(argv) do
    case Enum.split_while(argv, fn w -> String.downcase(w) != "to" end) do
      {item_words, [_to | rest]} -> {item_words, rest}
      {_all, []} -> {argv, []}
    end
  end

  defp do_give_greedy(argv, ctx) do
    case Resolver.greedy_match_entry([ctx.inventory_uuid], argv, ctx.store, min_remainder: 1) do
      {:ok, _entry, phrase, remainder} when remainder != [] ->
        give_item_to(phrase, Enum.join(remainder, " "), ctx)

      _ ->
        {:error, "Give what to whom? Try: give <item> to <player>"}
    end
  end

  defp give_item_to(item_phrase, target_phrase, ctx) do
    with {:ok, obj_entry} <- World.find_entry_by_name(ctx.inventory_uuid, item_phrase, ctx.store),
         {:ok, %Object{} = obj} <- Schemas.load_object(obj_entry.node_id, ctx.store),
         {:ok, target_inv_uuid, target_player_name, target_presence_uuid} <- find_player_inventory(target_phrase, ctx),
         recipient_identity <- resolve_recipient_identity(target_presence_uuid, ctx),
         :ok <-
           World.give_item(
             obj_entry.node_id,
             obj_entry.name,
             ctx.inventory_uuid,
             target_inv_uuid,
             taker_identity(ctx),
             recipient_identity,
             possession_opts(ctx)
           ) do
      World.broadcast_room(ctx.current_room_uuid, %{
        kind: :give,
        who: ctx.player_name,
        what: obj.name,
        to: target_player_name
      })

      {:reply, "You give #{obj.name} to #{target_player_name}."}
    else
      :error -> {:error, "You aren't carrying \"#{item_phrase}\"."}
      {:error, :no_such_player} -> {:error, "You don't see \"#{target_phrase}\" here."}
      {:error, :collision} -> {:error, "#{target_phrase} is already carrying one of those."}
      {:error, :gone} -> {:error, "It slipped from your grasp."}
      {:error, {:trust_rejected, _}} -> {:error, "You don't have permission to give that away."}
      {:error, :not_holder} -> {:error, "You aren't holding that."}
      {:error, :bad_arg} -> {:error, "You can't give that right now."}
      _ -> {:error, "You can't give that."}
    end
  end

  # CX-cj3t.2: resolve the recipient's bound identity uuid from their
  # presence doc, so `give`'s node-elevated push (`World.give_item/7`)
  # can transfer the item's possession token TO the actual recipient,
  # not just move the tree entry. Anonymous/unsigned presence docs (no
  # `bound_identity` written) yield `nil` — `HolderMove.push/7`'s
  # enforce path refuses that gracefully with `{:error, :bad_arg}`.
  defp resolve_recipient_identity(presence_uuid, ctx) do
    case Commonplace.Presence.read(presence_uuid, ctx.store) do
      %{"bound_identity" => id} when is_binary(id) -> id
      _ -> nil
    end
  end

  defp find_player_inventory(target_name, ctx) do
    needle = String.downcase(target_name)

    presence_entries =
      World.list_players_in(ctx.current_room_uuid, ctx.store)
      |> Enum.filter(fn e ->
        bare = e.name |> String.replace_suffix(".usr", "") |> String.downcase()
        String.contains?(bare, needle) and bare != String.downcase(ctx.player_name)
      end)

    case presence_entries do
      [entry] ->
        bare = entry.name |> String.replace_suffix(".usr", "")
        case lookup_player_inventory(bare, ctx) do
          {:ok, inv_uuid} -> {:ok, inv_uuid, bare, entry.node_id}
          err -> err
        end

      [] ->
        {:error, :no_such_player}

      _ ->
        {:error, :no_such_player}
    end
  end

  defp lookup_player_inventory(player_name, ctx) do
    path = "players/#{player_name}/inventory"
    World.resolve_path(path, ctx.root_uuid, ctx.store)
    |> case do
      {:ok, uuid} -> {:ok, uuid}
      _ -> {:error, :no_such_player}
    end
  end

  # ---- put / get-from (nested containers, CX-cj3t.1.1) ----

  defp do_put(%Parser.Command{argv: argv}, _ctx) when length(argv) < 2 do
    {:error, "Put what in what? Try: put <item> in <container>"}
  end

  # CX-8iyv-style syntax rule, mirrored from `give`'s "to" splitter: the
  # word "in" is the disambiguator between the item phrase and the
  # container phrase, so both may be multi-word ('put silver coin in
  # wooden chest').
  defp do_put(%Parser.Command{argv: argv}, ctx) do
    case split_on_in(argv) do
      {item_words, container_words} when item_words != [] and container_words != [] ->
        put_item_in(item_words, container_words, ctx)

      _ ->
        {:error, "Put what in what? Try: put <item> in <container>"}
    end
  end

  # CX-ypgf (jes comment) — accept surface-flavored prepositions as aliases of
  # "in" so `put brass key on tithe-plate` / `put ingot into forge` work like
  # `put ... in ...` (a plate/altar/pedestal begs for "on"). Splits on the FIRST
  # preposition token; both item and container phrases may still be multi-word.
  @put_prepositions ~w(in into on onto)

  defp split_on_in(argv) do
    case Enum.split_while(argv, fn w -> String.downcase(w) not in @put_prepositions end) do
      {item_words, [_prep | rest]} -> {item_words, rest}
      {_all, []} -> {argv, []}
    end
  end

  defp put_item_in(item_words, container_words, ctx) do
    item_phrase_label = Enum.join(item_words, " ")
    container_phrase = Enum.join(container_words, " ")

    with {:ok, source_dir, item_entry} <- locate_item_for_put(item_words, ctx),
         {:ok, %Object{} = obj} <- Schemas.load_object(item_entry.node_id, ctx.store),
         {:ok, container_entry, %Object{} = container_obj} <-
           Resolver.resolve_container(container_phrase, [ctx.current_room_uuid, ctx.inventory_uuid], ctx),
         :ok <- ensure_unlocked(container_entry.node_id, container_obj.name, ctx.store),
         :ok <- ensure_has_key(container_entry.node_id, container_obj.name, ctx),
         move_opts <-
           write_opts(ctx)
           # CX-2cmq — the deposit gate (World.deposit_item → Take
           # .deposit_elevation_allowed?) needs the world root to classify the
           # container's zone (curated vs citizen-home), EXACTLY like take_opts
           # feeds the extraction gate. Without it the gate fails closed and
           # denies legitimate curated-container deposits.
           |> Keyword.put(:root_uuid, Map.get(ctx, :root_uuid))
           # CX-j2wt — carry the invoker's own inventory uuid so a `put` FROM the
           # invoker's inventory can re-anchor an orphaned :available token
           # (`source_dir == invoker inventory` → HolderMove own-inventory rescue).
           |> Keyword.put(:invoker_inventory_uuid, Map.get(ctx, :inventory_uuid))
           |> Keyword.put(:precheck, fn ->
             cycle_guard(item_entry.node_id, container_entry.node_id, ctx.store)
           end),
         # CX-5c78 — route the deposit through the HolderMove push-to-node
         # primitive (the drop/give shape) instead of the un-elevated
         # World.move. A non-owner depositing into a curated (node-owned)
         # container now ELEVATES to node authority (like take/drop) rather
         # than failing invoker-signed {:trust_rejected}. The token moves to
         # the node → the item is takeable-from-container (put/take symmetric).
         # Locked containers still gate above (ensure_unlocked/ensure_has_key —
         # locking IS the deposits-closed opt-out); the cycle_guard rides the
         # threaded :precheck.
         :ok <-
           World.deposit_item(
             item_entry.node_id,
             item_entry.name,
             source_dir,
             container_entry.node_id,
             put_from_holder(source_dir, ctx),
             move_opts
           ) do
      World.broadcast_room(ctx.current_room_uuid, %{
        kind: :put,
        who: ctx.player_name,
        what: obj.name,
        where: container_obj.name
      })

      {:reply, "You put #{obj.name} in #{container_obj.name}."}
    else
      :not_found -> {:error, "You don't see \"#{item_phrase_label}\" here."}
      {:error, {:not_a_container, name}} -> {:error, "You can't put things in the #{name}."}
      {:error, {:locked, name}} -> {:error, "The #{name} is locked."}
      {:error, {:need_key, name, key}} -> {:error, "The #{name} won't open — you need the #{key}."}
      {:error, :not_found} -> {:error, "You don't see \"#{container_phrase}\" here."}
      {:error, :container_cycle} -> {:error, "You can't put #{item_phrase_label} inside itself."}
      {:error, :collision} -> {:error, "There's already one of those in there."}
      {:error, :gone} -> {:error, "It slipped from your grasp."}
      {:error, {:trust_rejected, _}} -> {:error, "You don't have permission to do that."}
      _ -> {:error, "You can't put that there."}
    end
  end

  # Item resolution order for `put`: inventory first, then the current
  # room (spec-specified order) — mirrors `find_in_scope`'s dir order
  # but also reports WHICH dir matched, since `put` needs the source dir
  # to move from (unlike `look`, which only needs the entry).
  defp locate_item_for_put(item_words, ctx) do
    case Resolver.greedy_match_entry([ctx.inventory_uuid], item_words, ctx.store) do
      {:ok, entry, _phrase, _remainder} ->
        {:ok, ctx.inventory_uuid, entry}

      :not_found ->
        case Resolver.greedy_match_entry([ctx.current_room_uuid], item_words, ctx.store) do
          {:ok, entry, _phrase, _remainder} -> {:ok, ctx.current_room_uuid, entry}
          :not_found -> :not_found
        end
    end
  end

  # CX-5c78 — the item's CURRENT possession holder for a `put` deposit (the
  # `from_holder` HolderMove transfers the token from): the invoker when the
  # source is their own inventory, the node when the source is a room (a
  # room-held item). `nil` (no signed identity / no node identity) makes the
  # elevated deposit fail closed — the correct enforce refusal.
  defp put_from_holder(source_dir, ctx) do
    if source_dir == ctx.inventory_uuid do
      taker_identity(ctx)
    else
      case Commonplace.Crypto.NodeIdentity.identity() do
        {:ok, id} -> id
        _ -> nil
      end
    end
  end

  # CX-cj3t.1.1: atomic move-cycle guard for `put`, run as
  # `Move.move/5`'s `opts[:precheck]` — INSIDE the bursar lock the move
  # already takes on `{source_dir, container_dir}`, so a concurrent
  # `put` racing this one cannot open the cycle in the gap between a
  # check and a write (there is no gap; the check runs under the same
  # lock as the write).
  #
  # DEVIATION FLAGGED FOR PLAN: plan's preferred guard shape was an
  # ancestor-walk (walk the container's ancestors looking for the
  # item). This MUD's dir schema is CHILD-REFERENCED ONLY — a directory
  # lists its children; nothing stores a parent pointer — so an
  # ancestor-walk would require a root-down path search with no cheaper
  # alternative than re-deriving ancestry from scratch. A bounded
  # SUBTREE-walk of the ITEM's own contents (typically small — a bag,
  # not the world) is the practical equivalent: putting the item inside
  # something that already lives inside the item creates the same
  # cycle as putting the item inside itself. Depth-capped + visited-set
  # so it terminates even against an already-corrupt/cyclic tree.
  #
  # See `Commonplace.MUD.Move`'s moduledoc "Nested containers" section
  # for the wider concurrent-cross-replica caveat this guard does NOT
  # cover (resolved by move-serialization now, Kleppmann-move / CX-liim
  # for the federated future).
  @default_cycle_guard_max_depth 32

  # Configurable so tests can exercise the fail-closed cap without a
  # 33-deep fixture, and an operator can tune it. Prod default 32.
  defp cycle_guard_max_depth,
    do: Application.get_env(:commonplace, :cycle_guard_max_depth, @default_cycle_guard_max_depth)

  defp cycle_guard(item_uuid, container_uuid, _store) when item_uuid == container_uuid do
    {:error, :container_cycle}
  end

  defp cycle_guard(item_uuid, container_uuid, store) do
    case Schemas.load_object(item_uuid, store) do
      {:ok, %Object{container?: true}} ->
        if subtree_contains?(item_uuid, container_uuid, store) do
          {:error, :container_cycle}
        else
          :ok
        end

      _ ->
        :ok
    end
  end

  defp subtree_contains?(root_uuid, target_uuid, store) do
    bfs_contains?([root_uuid], MapSet.new([root_uuid]), target_uuid, store, 0)
  end

  # An exhausted frontier means the whole subtree was explored without
  # finding the target — genuinely acyclic (this precedes the depth
  # check, so a fully-explored shallow tree is correctly `false`).
  defp bfs_contains?([], _visited, _target, _store, _depth), do: false

  defp bfs_contains?(frontier, visited, target_uuid, store, depth) do
    # FAIL-CLOSED (plan #5965): a non-empty frontier past the depth cap
    # means we could NOT prove the subtree acyclic within the bound, so
    # assume a cycle and reject. Returning `false` here would fail OPEN —
    # a deep-but-acyclic nest past the cap → "no cycle found" → ALLOW →
    # forms a cycle at depth >cap the guard's own BFS can't reach (a
    # scriptable DoS: an author verb can loop transfers to build the deep
    # nest). A true cycle still terminates via the visited-set well before
    # the cap; this only bites a legit >32-deep nest (absurd for
    # gameplay), where a false-reject is far cheaper than a missed-cycle
    # infinite move/render walk.
    if depth > cycle_guard_max_depth() do
      true
    else
      do_bfs_contains?(frontier, visited, target_uuid, store, depth)
    end
  end

  defp do_bfs_contains?(frontier, visited, target_uuid, store, depth) do
    children =
      frontier
      |> Enum.flat_map(fn uuid -> World.list_objects_in(uuid, store) end)
      |> Enum.map(& &1.node_id)
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(visited, &1))

    cond do
      target_uuid in children ->
        true

      children == [] ->
        false

      true ->
        bfs_contains?(children, Enum.reduce(children, visited, &MapSet.put(&2, &1)), target_uuid, store, depth + 1)
    end
  end

  # ---- inventory / who ----

  defp do_inventory(ctx) do
    items =
      World.list_objects_in(ctx.inventory_uuid, ctx.store)
      |> Enum.map(fn e ->
        case Schemas.load_object(e.node_id, ctx.store) do
          {:ok, %Object{name: name}} -> name
          _ -> e.name
        end
      end)

    text =
      case items do
        [] -> "You are carrying nothing."
        _ -> "You are carrying:\n  - " <> Enum.join(items, "\n  - ")
      end

    {:reply, text}
  end

  defp do_who(ctx) do
    names =
      walk_collect_players(ctx.root_uuid, ctx.store)
      |> Enum.filter(&live_presence?/1)
      |> Enum.sort()
      |> Enum.uniq()

    text =
      case names do
        [] -> "Nobody is logged in."
        _ -> "Players online:\n  - " <> Enum.join(names, "\n  - ")
      end

    {:reply, text}
  end

  # CX-3xwu: a collected `.usr` name renders in `who` IFF a live session is
  # registered for it in PresenceRegistry. Keys purely on live-session
  # registration (auto-removed on process death), NOT heartbeat recency —
  # a live-but-slow player still shows; a dead session's stale `.usr` tree
  # entry doesn't.
  defp live_presence?(name) do
    Registry.lookup(Commonplace.MUD.PresenceRegistry, "#{name}.usr") != []
  end

  # CX-wkau (MUD-as-documents Inc-1, tranche 2) — PROMOTED verb-authoring
  # surface: the read-only roster walk that `do_who/1` needs, exposed so
  # its doc-hosted seed (`priv/engine_verbs/who.exs.seed`) can collect the
  # `.usr` tree entries without copying the private tree-recursion logic.
  # The names it returns are exactly what `who` already prints to every
  # player — no new visibility is created by promoting it. Live-session
  # filtering (`live_presence?/1`) stays private/inline in the seed itself
  # (a one-line `Registry.lookup/2` — no private machinery to wrap).
  @doc false
  def walk_collect_players(dir_uuid, store) do
    case Schemas.load_dir_schema(dir_uuid, store) do
      {:ok, schema} ->
        Schema.list_entries(schema)
        |> Enum.flat_map(fn entry ->
          cond do
            String.ends_with?(entry.name, ".usr") ->
              [entry.name |> String.replace_suffix(".usr", "")]

            entry.type == :dir ->
              walk_collect_players(entry.node_id, store)

            true ->
              []
          end
        end)

      _ ->
        []
    end
  end

  # ---- movement ----

  defp do_go(nil, _ctx), do: {:error, "Go where?"}

  defp do_go(direction, ctx) do
    with {:ok, %Room{} = room} <- World.get_room(ctx.current_room_uuid, ctx.store),
         {:ok, dest_uuid} <- Map.fetch(room.exits, direction) |> wrap_fetch(),
         # CX-avzp — route the presence move through the read-gated chokepoint:
         # entering a room subscribes you to its event stream, so a private dest
         # denies the move ATOMICALLY (no presence write, no subscribe, no
         # eavesdrop) rather than only suppressing the later render.
         :ok <-
           World.move_presence(
             ctx.player_uuid,
             ctx.presence_filename,
             ctx.current_room_uuid,
             dest_uuid,
             invoker_move_opts(ctx)
           ) do
      World.broadcast_room(ctx.current_room_uuid, %{
        kind: :depart,
        who: ctx.player_name,
        to: direction
      })

      from_dir = Parser.opposite_direction(direction) || "elsewhere"

      World.broadcast_room(dest_uuid, %{
        kind: :arrive,
        who: ctx.player_name,
        from: from_dir
      })

      {:moved, dest_uuid}
    else
      :error -> {:error, "You can't go #{direction}."}
      {:error, :gone} -> {:error, "The way #{direction} closed behind you."}
      {:error, :collision} -> {:error, "Something blocks the way #{direction}."}
      {:error, :read_denied} -> {:error, "That place is private."}
      {:error, {:trust_rejected, _}} -> {:error, "You don't have permission to go #{direction}."}
      _ -> {:error, "You can't go #{direction}."}
    end
  end

  defp wrap_fetch({:ok, _} = ok), do: ok
  defp wrap_fetch(:error), do: :error

  # ---- Builder verbs ----

  defp dispatch_builder("@dig", cmd, ctx), do: do_dig(cmd, ctx)
  defp dispatch_builder("@create", cmd, ctx), do: do_create(cmd, ctx)
  defp dispatch_builder("@destroy", cmd, ctx), do: do_destroy(cmd, ctx)
  defp dispatch_builder("@desc", cmd, ctx), do: do_desc(cmd, ctx)
  defp dispatch_builder("@name", cmd, ctx), do: do_rename(cmd, ctx)
  defp dispatch_builder("@alias", cmd, ctx), do: do_alias(cmd, ctx)
  defp dispatch_builder("@listen", _cmd, ctx), do: {:reply, "Now listening to room #{ctx.current_room_uuid}. (Debug: red events will appear inline.)"}
  defp dispatch_builder("@verb", cmd, ctx), do: do_verb_edit(cmd, ctx)
  defp dispatch_builder("@unverb", cmd, ctx), do: do_unverb(cmd, ctx)
  defp dispatch_builder("@link", cmd, ctx), do: do_link(cmd, ctx)
  defp dispatch_builder("@unlink", cmd, ctx), do: do_unlink(cmd, ctx)
  defp dispatch_builder("@teleport", cmd, ctx), do: do_teleport(cmd, ctx)
  defp dispatch_builder("@go", cmd, ctx), do: do_teleport(cmd, ctx)
  defp dispatch_builder("@container", cmd, ctx), do: do_mark_container(cmd, ctx)
  defp dispatch_builder("@private", _cmd, ctx), do: do_visibility(:capability_gated, ctx)
  defp dispatch_builder("@public", _cmd, ctx), do: do_visibility(:public, ctx)

  defp dispatch_builder("@dump", cmd, ctx) do
    cond do
      cmd.target in [nil, "here", "room"] ->
        case World.get_room(ctx.current_room_uuid, ctx.store) do
          # CX-82wi — lead with the room's OWN uuid (its address). It is not a
          # Room struct field, so inspect/1 alone never surfaced it, leaving a
          # no-inbound-exit room (every home!) unaddressable for @link/@teleport.
          {:ok, room} ->
            {:reply, "uuid: #{ctx.current_room_uuid}\n" <> inspect(room, pretty: true)}

          _ ->
            {:error, "no room"}
        end

      true ->
        # CX-mxxe / CX-hh70 — `@dump` is the raw-internals command, so it (not
        # casual `examine`) is where the object's freeform `meta["state"]` block
        # belongs. The typed `Object` struct drops `state` (CX-hqk5), so append
        # `notable_state/2` (raw meta) after the struct dump for builders/debug.
        case Resolver.greedy_match_entry([ctx.inventory_uuid, ctx.current_room_uuid], cmd.argv, ctx.store) do
          {:ok, entry, _phrase, _remainder} ->
            case Resolver.resolve_entry(entry, ctx) do
              {:ok, :object, obj} ->
                struct_text = inspect(obj, pretty: true)

                case Render.notable_state(entry.node_id, ctx.store) do
                  "" -> {:reply, struct_text}
                  state_text -> {:reply, struct_text <> "\n" <> state_text}
                end

              {:ok, :player, pl} ->
                {:reply, inspect(pl, pretty: true)}

              _ ->
                {:error, "Can't find \"#{Enum.join(cmd.argv, " ")}\"."}
            end

          :not_found ->
            {:error, "Can't find \"#{Enum.join(cmd.argv, " ")}\"."}
        end
    end
  end

  defp do_verb_edit(%Parser.Command{argv: argv}, _ctx) when length(argv) < 1 do
    {:error, "Try: @verb <target>:<verbname>"}
  end

  # CX-cj3t.11 — join the FULL argv before splitting on ":" so a multi-word
  # object name resolves ("@verb warded vault:swing" → target "warded vault",
  # verb "swing"). Previously only argv[0] was used, so any object whose name
  # had a space broke. The verb name is the FIRST token after ":" (verb names
  # are single words; trailing words are ignored, as before).
  defp do_verb_edit(%Parser.Command{argv: argv}, ctx) do
    spec = Enum.join(argv, " ")

    case String.split(spec, ":", parts: 2) do
      [target_raw, rest] ->
        target = String.trim(target_raw)
        verb_name = rest |> String.trim() |> String.split() |> List.first()

        if target != "" and verb_name not in [nil, ""] do
          do_verb_edit_resolved(target, verb_name, ctx)
        else
          {:error, "Try: @verb <target>:<verbname>"}
        end

      _ ->
        {:error, "Try: @verb <target>:<verbname>"}
    end
  end

  defp do_verb_edit_resolved(target, verb_name, ctx) do
    cond do
      target in ["here", "room"] ->
        enter_verb_editor(ctx.current_room_uuid, "here", verb_name, ctx)

      true ->
        case World.find_entry_by_name(ctx.current_room_uuid, target, ctx.store) do
          {:ok, %Schema.Entry{type: :dir, name: name, node_id: uuid}} ->
            if String.ends_with?(name, ".obj") do
              enter_verb_editor(uuid, target, verb_name, ctx)
            else
              {:error, "Can only edit verbs on objects (or here/room)."}
            end

          _ ->
            case World.find_entry_by_name(ctx.inventory_uuid, target, ctx.store) do
              {:ok, %Schema.Entry{type: :dir, name: name, node_id: uuid}} ->
                if String.ends_with?(name, ".obj") do
                  enter_verb_editor(uuid, target, verb_name, ctx)
                else
                  {:error, "Can only edit verbs on objects (or here/room)."}
                end

              _ ->
                {:error, "You don't see \"#{target}\" here or in inventory."}
            end
        end
    end
  end

  # CX-cj3t / CX-fogy: open the @verb editor, stamping an `editable` flag from an
  # UPFRONT authority check (`Trust.safe_verb_author_authorized?`) so the session
  # can render read-only PREVIEW mode when the caller can't author verbs here —
  # instead of dangling a full editor + docs and only denying the save. The @verb
  # editor writes a SANDBOXED safe-verb, gated by DefineVerbGate (:define_verb
  # over the target's zone) — so a citizen holding the {:subtree,home}[:define_verb]
  # grant (CX-fogy) CAN author in their own home. Raw executable code is a separate
  # lane (:execute / Gate-B, node-only) the editor never reaches.
  defp enter_verb_editor(target_uuid, target_label, verb_name, ctx) do
    current = read_current_source(target_uuid, verb_name, ctx)

    {:enter_editor,
     %{
       target_uuid: target_uuid,
       target_label: target_label,
       verb_name: verb_name,
       current: current,
       editable: can_author_verbs?(target_uuid, ctx)
     }}
  end

  defp can_author_verbs?(target_uuid, ctx) do
    {id, pub} =
      case Map.get(ctx, :signing_context) do
        %{identity_uuid: i, public_key: p} -> {i, p}
        _ -> {nil, nil}
      end

    Commonplace.Trust.safe_verb_author_authorized?(
      id,
      pub,
      Map.get(ctx, :cert_cids, []),
      target_uuid,
      Commonplace.Trust.config(),
      ctx.store
    )
  end

  defp read_current_source(target_uuid, verb_name, ctx) do
    case VerbSource.read_source(target_uuid, verb_name, ctx.store) do
      {:ok, text} -> text
      _ -> ""
    end
  end

  defp do_dig(%Parser.Command{argv: argv}, _ctx) when length(argv) < 2 do
    {:error, "Try: @dig <direction> <name>"}
  end

  defp do_dig(%Parser.Command{argv: [direction | name_parts]}, ctx) do
    direction = String.downcase(direction)
    opposite = Parser.opposite_direction(direction)
    name = Enum.join(name_parts, " ")

    cond do
      not Parser.direction?(direction) ->
        {:error, "Unknown direction: #{direction}"}

      opposite == nil ->
        {:error, "No opposite for #{direction}"}

      true ->
        do_dig_write(direction, opposite, name, ctx)
    end
  end

  # CX-p0wx: @dig onto a direction that ALREADY has an exit used to
  # silently overwrite it (`update_room_exit/4` did a bare `Map.put`) —
  # the old target room fell out of the tree (still stored, but no
  # longer reachable from anywhere) with zero warning, and since
  # relogin does NOT reset a player's location, a builder who clobbered
  # their only exit was left permanently stranded with no in-game way
  # back. Refuse by default: check for an existing exit before writing
  # anything, and point the builder at `@link`/`@teleport` for the
  # intentional-repoint / recovery paths instead.
  defp do_dig_write(direction, opposite, name, ctx) do
    case World.get_room(ctx.current_room_uuid, ctx.store) do
      {:ok, %Room{exits: exits}} ->
        case Map.fetch(exits, direction) do
          {:ok, existing_uuid} ->
            {:error,
             "There is already an exit #{direction} (to #{describe_room(existing_uuid, ctx)}). " <>
               "Use @link to repoint it or pick another direction."}

          :error ->
            do_dig_write_new_room(direction, opposite, name, ctx)
        end

      {:error, reason} ->
        {:error, commit_error_reply(reason)}
    end
  end

  defp describe_room(room_uuid, ctx) do
    case World.get_room(room_uuid, ctx.store) do
      {:ok, %Room{name: name}} when name != "" -> name
      _ -> room_uuid
    end
  end

  # CX-93ea: @dig writes THREE things (the new room's dir+meta doc, the
  # entry in root, and the exit edge on the current room) — this module
  # has no rollback (append-only store), so a mid-sequence denial stops
  # here and reports the failure; whatever landed before the denial
  # (e.g. the new room's genesis doc with nothing yet pointing at it)
  # stays as an orphan rather than being cleaned up.
  # CX-Camillo-C2: the room-dig WRITE-CORE now lives in `Commonplace.MUD.Build`
  # (one impl, two entry points — this verb AND the native-agent citizen
  # orchestrator seed through the SAME function, bot-signed). This head keeps the
  # verb behavior IDENTICAL: it calls the core and formats the reply as before.
  defp do_dig_write_new_room(direction, opposite, name, ctx) do
    case Build.dig_room(ctx, direction, opposite, name) do
      {:ok, _new_room_uuid} ->
        {:reply, "You carve out a new room (#{name}). #{String.capitalize(direction)} leads there."}

      {:error, reason} ->
        {:error, commit_error_reply(reason)}
    end
  end

  # ---- @link / @unlink / @teleport (CX-p0wx: the deliberate-repoint and
  # stranded-builder recovery primitives) ----

  defp do_link(%Parser.Command{argv: argv}, _ctx) when length(argv) < 2 do
    {:error, "Try: @link <direction> <room-uuid>"}
  end

  # CX-p0wx: unlike @dig, @link is EXPECTED to repoint an exit (that's
  # the whole point — it's the intentional-overwrite counterpart to
  # @dig's refuse-by-default), so it always overwrites whatever exit
  # (if any) already sits in that direction. `@dump` already surfaces
  # neighbor-room uuids, so a builder always has the id they need.
  defp do_link(%Parser.Command{argv: [direction, room_uuid | _]}, ctx) do
    direction = String.downcase(direction)

    cond do
      not Parser.direction?(direction) ->
        {:error, "Unknown direction: #{direction}"}

      true ->
        case World.get_room(room_uuid, ctx.store) do
          {:ok, %Room{} = target} ->
            case Build.update_room_exit(ctx.current_room_uuid, direction, room_uuid, ctx) do
              :ok -> {:reply, "Linked #{direction} to #{target.name} (#{room_uuid})."}
              {:error, reason} -> {:error, commit_error_reply(reason)}
            end

          _ ->
            {:error, "No such room: #{room_uuid}"}
        end
    end
  end

  defp do_unlink(%Parser.Command{argv: []}, _ctx), do: {:error, "Try: @unlink <direction>"}

  # CX-pe8d/CX-p0wx: removes an exit from the current room without
  # touching the neighbor room — the (rare, deliberate) way to
  # disconnect two rooms. Never errors if the direction had no exit;
  # that's a no-op, not a failure.
  defp do_unlink(%Parser.Command{argv: [direction | _]}, ctx) do
    direction = String.downcase(direction)

    cond do
      not Parser.direction?(direction) ->
        {:error, "Unknown direction: #{direction}"}

      true ->
        # CX-cl65: surgical exits-merge, never a %Room{} round-trip (drops zone).
        case World.get_meta_map(ctx.current_room_uuid, Schemas.room_filename(), ctx.store) do
          {:ok, %{"exits" => exits} = _map} when is_map_key(exits, direction) ->
            new_exits = Map.delete(exits, direction)

            case World.merge_meta(ctx.current_room_uuid, Schemas.room_filename(), %{"exits" => new_exits}, ctx.store, write_opts(ctx)) do
              :ok -> {:reply, "Removed the exit #{direction}."}
              {:error, reason} -> {:error, commit_error_reply(reason)}
            end

          {:ok, _map} ->
            {:reply, "There is no exit #{direction} to remove."}

          {:error, reason} ->
            {:error, commit_error_reply(reason)}
        end
    end
  end

  # CX-ivqz (read-scoping P2, Seam 4): "@private"/"@public" flip the
  # CURRENT room's read-visibility. No player-owner-grant flow ships yet
  # (deferred) — visibility + DENY-ONLY, so a private home is private to
  # its owner alone. The WRITE GATE is the protection, exactly like
  # `@desc`/`@name`: this commits through the SAME invoker-signed
  # surgical-merge path `@desc`/`@unlink` use (`World.merge_meta` +
  # `write_opts(ctx)` → the session's own signing context; CX-cl65 — never a
  # zone-dropping %Room{} round-trip). Under
  # `local_write_gate: :enforce` only a principal holding a `:write` cap
  # over the room's meta doc (the home owner, via
  # `Citizenship.issue_home_zone_cert/4`) can land the commit — a
  # non-owner's attempt comes back `{:trust_rejected, _}`, surfaced here
  # as "You don't own this place." (not the generic `commit_error_reply/1`
  # message, so the refusal reads as an ownership denial, not a random
  # failure). On a `@private` flip, `owner` is never left blank: an
  # UNOWNED room (legacy, minted before P2) is stamped with the invoker's
  # identity; an already-set owner is PRESERVED (a co-writer's @private
  # must not silently reassign read-ownership).
  defp do_visibility(visibility, ctx) do
    case World.get_room(ctx.current_room_uuid, ctx.store) do
      {:ok, %Room{} = room} ->
        # Going private: keep an ALREADY-SET owner (a co-writer's @private
        # must not silently reassign read-ownership); only a legacy/unowned
        # room gets stamped with the invoker. Going public: owner unchanged.
        owner =
          if visibility == :capability_gated,
            do: room.owner || taker_identity(ctx),
            else: room.owner

        # CX-cl65: surgical merge (preserves the zone stamp + verb state), never a
        # %Room{} round-trip. Match encode_room's omit-when-default wire form —
        # :public omits "visibility" (nil ⇒ delete key), owner omitted when nil.
        updates = %{
          "visibility" => if(visibility == :capability_gated, do: "capability_gated", else: nil),
          "owner" => owner
        }

        case World.merge_meta(ctx.current_room_uuid, Schemas.room_filename(), updates, ctx.store, write_opts(ctx)) do
          :ok -> {:reply, visibility_reply(visibility)}
          {:error, {:trust_rejected, _}} -> {:error, "You don't own this place."}
          {:error, reason} -> {:error, commit_error_reply(reason)}
        end

      {:error, reason} ->
        {:error, commit_error_reply(reason)}
    end
  end

  defp visibility_reply(:capability_gated), do: "This place is now private."
  defp visibility_reply(:public), do: "This place is now public."

  # CX-z0v7 bundle (P3 polish): `home` — teleport to your own home room
  # (`players/<name>/`, the room Citizenship provisions + you own). A
  # convenience over `@teleport <home-uuid>`; the web client (MudLive)
  # already offers this, the escript/Bot path didn't. Delegates to
  # `do_teleport` (own-presence move only, no shared-tree write).
  defp do_home(ctx) do
    # A full citizen's `players/<name>/` IS a room (Citizenship provisions
    # it with a `__room.json`); a bare non-citizen session only has a plain
    # player dir there. Require an actual room before teleporting so `home`
    # gives a clean message rather than `@teleport`'s "No such room".
    with {:ok, home_uuid} <- World.resolve_path("players/#{ctx.player_name}", ctx.root_uuid, ctx.store),
         {:ok, %Room{}} <- World.get_room(home_uuid, ctx.store) do
      do_teleport(%Parser.Command{argv: [home_uuid]}, ctx)
    else
      _ -> {:error, "You don't seem to have a home to return to yet."}
    end
  end

  defp do_teleport(%Parser.Command{argv: []}, _ctx) do
    {:error, "Try: @teleport <room-uuid>"}
  end

  # CX-p0wx: the stranded-builder escape hatch — moves the player
  # directly to any room by uuid, bypassing exits entirely. This is
  # the recovery path for a builder who got stranded before this fix
  # existed (or who just wants to jump around while building).
  #
  # Gating decision: NOT restricted to builders/owners. @teleport moves
  # only the player's own location (no shared-tree write — no schema
  # edit, no exit mutation), so it doesn't touch the trust/section-cert
  # surface any other verb writes through, and gating it here would add
  # an identity check that doesn't exist anywhere else in this module
  # (builder-verb access today is "in @builders", not role/owner based).
  # Given the MUD's current trust posture (single shared trust domain,
  # no builder/player role split yet), keep it available to everyone —
  # revisit if/when the MUD grows real roles.
  defp do_teleport(%Parser.Command{argv: [room_uuid | _]}, ctx) do
    case World.get_room(room_uuid, ctx.store) do
      {:ok, %Room{}} ->
        # CX-avzp — same read-gated chokepoint as `do_go`/`move_self`: teleport
        # relocates presence (→ subscribe), so a private dest denies atomically.
        # `do_home/1` reaches here too (its own-room teleport delegates to
        # `do_teleport/2`), so this is also `home`'s move call.
        case World.move_presence(
               ctx.player_uuid,
               ctx.presence_filename,
               ctx.current_room_uuid,
               room_uuid,
               invoker_move_opts(ctx)
             ) do
          :ok ->
            World.broadcast_room(ctx.current_room_uuid, %{
              kind: :depart,
              who: ctx.player_name,
              to: "elsewhere"
            })

            World.broadcast_room(room_uuid, %{
              kind: :arrive,
              who: ctx.player_name,
              from: "elsewhere"
            })

            {:moved, room_uuid}

          {:error, :gone} ->
            {:error, "You couldn't teleport away — try again."}

          {:error, :collision} ->
            {:error, "Something blocks your arrival there."}

          {:error, :read_denied} ->
            {:error, "That place is private."}

          {:error, {:trust_rejected, _}} ->
            {:error, "You don't have permission to teleport there."}

          _ ->
            {:error, "Teleport failed."}
        end

      _ ->
        {:error, "No such room: #{room_uuid}"}
    end
  end

  defp do_create(%Parser.Command{argv: argv}, _ctx) when length(argv) < 2 do
    {:error, "Try: @create <object|room> <name>"}
  end

  # CX-8iyv: `argv: ["object" | name_parts]` — the FULL remainder is the
  # name, not just the first word (was `["object", name | _]`, which
  # silently dropped every word after the first — this is why
  # `@create room The Silver Fountain` used to mint a disconnected room
  # literally named "The").
  defp do_create(%Parser.Command{argv: ["object" | name_parts]}, ctx) do
    create_object(name_parts, false, ctx)
  end

  # CX-cj3t.1.1: `@create container <name>` makes an object that can hold
  # other objects (`put <item> in <name>` / `look in <name>`). It's an
  # ordinary object with `container?: true`, so this is the in-world way
  # to designate a container (there was no builder command to set the
  # flag otherwise — only the schema field).
  defp do_create(%Parser.Command{argv: ["container" | name_parts]}, ctx) do
    create_object(name_parts, true, ctx)
  end

  defp do_create(%Parser.Command{argv: ["room" | name_parts]}, ctx) do
    name = Enum.join(name_parts, " ")
    json = Schemas.encode_room(%Room{name: name, description: "(no description yet)"})

    # CX-4u03 A3: minted UNDER the player's HOME subtree (bound (2), never the
    # global root) via ChildMutation → inherits the home zone, covered by the
    # {:subtree, home} cert. Disconnected (no exit) but OWNED — the player can
    # @dig/@link it into their map.
    with {:ok, home} <- Build.resolve_home(ctx),
         {:ok, new_uuid} <-
           ChildMutation.create_zoned_child(home, name, Schemas.room_filename(), json, ctx.store, write_opts(ctx)) do
      Build.auto_extend_section(new_uuid, nil, ctx.store)

      {:reply, "You create a new room (#{name}) in your home."}
    else
      {:error, reason} -> {:error, commit_error_reply(reason)}
    end
  end

  defp do_create(%Parser.Command{argv: [other | _]}, _ctx) do
    {:error, "Unknown kind: #{other} (try object, container, or room)"}
  end

  defp create_object([], _container?, _ctx), do: {:error, "Create what? Try: @create object <name>"}

  # CX-Camillo-C2: the object-create WRITE-CORE now lives in
  # `Commonplace.MUD.Build` (one impl, two entry points — this verb AND the
  # native-agent citizen orchestrator seed through the SAME function). This head
  # keeps the verb behavior IDENTICAL: it calls the core and formats the reply.
  defp create_object(name_parts, container?, ctx) do
    name = Enum.join(name_parts, " ")

    case Build.create_object(ctx, name, container?) do
      {:ok, _new_obj_uuid} ->
        article = if container?, do: "a container (#{name})", else: "a #{name}"
        {:reply, "You create #{article}."}

      {:error, reason} ->
        {:error, commit_error_reply(reason)}
    end
  end

  # CX-avgu — builder cleanup: unlink a stray/mis-created OBJECT from the
  # current room (the inverse of @create). Authority MIRRORS @create exactly:
  # the write is signed via `write_opts(ctx)`, so it's enforce-gated on the
  # room schema (invoker needs a cert covering the room) and permissive-lands
  # for any builder — no new authority class. Unlink only, NOT a hard delete:
  # the object doc persists in the append-only history and is re-linkable by
  # uuid until GC — but there is NO one-command undo yet, so this is a
  # manual-recovery-window, not "oops-proof" (plan #6260). Guards (CX-avgu
  # plan-touch #6260): OBJECT-only — keyed on `.obj`, the SYSTEM-ASSIGNED
  # stable ENTRY suffix (a builder can't forge it, and @name only touches the
  # display meta, not the entry key), so `.usr`/verbs/any future entry type
  # are whitelisted OUT fail-closed and rooms are structurally excluded (not
  # room-entries). REFUSE a non-empty container — counting CONTAINED OBJECTS
  # (`list_objects_in` = `.obj` only), NOT its own verbs/state/meta children
  # (those correctly die with it); refuse-over-orphan is the fail-toward-no-
  # loss default (cascade `-r` stays an explicit opt-in for later). Room-
  # scoped v1 (inventory items are the gameplay consume path).
  defp do_destroy(%Parser.Command{argv: []}, _ctx), do: {:error, "Destroy what? Try: @destroy <object>"}

  defp do_destroy(%Parser.Command{argv: name_parts}, ctx) do
    name = Enum.join(name_parts, " ")

    case World.find_entry_by_name(ctx.current_room_uuid, name, ctx.store) do
      {:ok, entry} ->
        cond do
          not String.ends_with?(entry.name, ".obj") ->
            {:error, "You can only @destroy objects, not \"#{name}\"."}

          World.list_objects_in(entry.node_id, ctx.store) != [] ->
            {:error, "The #{name} isn't empty — empty it before you @destroy it."}

          true ->
            case remove_dir_entry(ctx.current_room_uuid, entry.name, ctx) do
              :ok -> {:reply, "You destroy the #{name}."}
              {:error, reason} -> {:error, commit_error_reply(reason)}
            end
        end

      :error ->
        {:error, "There's no \"#{name}\" here to destroy."}
    end
  end

  # CX-9plf: `@unverb <target>:<verbname>` removes a verb (both safe +
  # legacy entries) from a room/object — @verb only creates/edits, so
  # throwaway/diagnostic verbs were stuck permanently.
  defp do_unverb(%Parser.Command{argv: [spec | _]}, ctx) do
    case String.split(spec, ":", parts: 2) do
      [target, verb_name] when verb_name != "" ->
        case resolve_unverb_target(target, ctx) do
          {:ok, target_uuid, label} ->
            case VerbSource.delete_verb(target_uuid, verb_name, ctx.store, write_opts(ctx)) do
              :ok -> {:reply, "Removed #{label}:#{verb_name}."}
              :not_found -> {:error, "No verb \"#{verb_name}\" on #{label}."}
              {:error, reason} -> {:error, commit_error_reply(reason)}
            end

          {:error, msg} ->
            {:error, msg}
        end

      _ ->
        {:error, "Try: @unverb <target>:<verbname>"}
    end
  end

  defp do_unverb(_cmd, _ctx), do: {:error, "Try: @unverb <target>:<verbname>"}

  defp resolve_unverb_target(target, ctx) when target in ["here", "room"],
    do: {:ok, ctx.current_room_uuid, "here"}

  defp resolve_unverb_target(target, ctx) do
    case find_object_entry(target, ctx) do
      {:ok, %Schema.Entry{node_id: uuid, name: name}} ->
        {:ok, uuid, String.replace_suffix(name, ".obj", "")}

      :error ->
        {:error, "You don't see \"#{target}\" here or in your inventory."}
    end
  end

  # CX-cj3t.1.1: `@container <object>` converts an EXISTING object (in the
  # room or your inventory) into a container — the in-world way to mark
  # something you already built as able to hold things.
  defp do_mark_container(%Parser.Command{argv: []}, _ctx),
    do: {:error, "Try: @container <object>"}

  defp do_mark_container(%Parser.Command{argv: argv}, ctx) do
    target = Enum.join(argv, " ")

    case find_object_entry(target, ctx) do
      {:ok, entry} ->
        case World.set_meta(entry.node_id, Schemas.object_filename(), "container", true, ctx.store, write_opts(ctx)) do
          :ok -> {:reply, "#{target} is now a container — you can put things in it."}
          {:error, reason} -> {:error, commit_error_reply(reason)}
        end

      :error ->
        {:error, "You don't see \"#{target}\" here or in your inventory."}
    end
  end

  # Resolve an .obj entry by name in the current room or the player's
  # inventory (room first). Returns {:ok, entry} or :error.
  defp find_object_entry(target, ctx) do
    with :error <- object_entry_in(ctx.current_room_uuid, target, ctx.store),
         :error <- object_entry_in(ctx.inventory_uuid, target, ctx.store) do
      :error
    end
  end

  defp object_entry_in(dir_uuid, target, store) do
    case World.find_entry_by_name(dir_uuid, target, store) do
      {:ok, %Schema.Entry{name: name} = entry} ->
        if String.ends_with?(name, ".obj"), do: {:ok, entry}, else: :error

      _ ->
        :error
    end
  end

  defp do_desc(%Parser.Command{argv: argv}, _ctx) when length(argv) < 2, do: {:error, "Try: @desc <target> <text>"}

  # CX-8iyv: target may itself be multi-word ("silver coin") with no
  # explicit separator from the text that follows it — greedy-match the
  # longest prefix of argv against room entries (names + aliases),
  # requiring at least one word left over for the description text.
  defp do_desc(%Parser.Command{argv: argv}, ctx) do
    case Resolver.split_target_and_rest(argv, ctx) do
      {:ok, target_label, text} when text != "" ->
        update_meta_description(target_label, text, ctx)

      _ ->
        {:error, "Try: @desc <target> <text>"}
    end
  end

  defp do_rename(%Parser.Command{argv: argv}, _ctx) when length(argv) < 2, do: {:error, "Try: @name <target> <new name>"}

  # CX-8iyv: same greedy target/rest split as `do_desc/2` — lets both
  # the target ("silver coin") and the new name be multi-word.
  defp do_rename(%Parser.Command{argv: argv}, ctx) do
    case Resolver.split_target_and_rest(argv, ctx) do
      {:ok, target_label, new_name} when new_name != "" ->
        update_meta(target_label, "name", new_name, ctx)

      _ ->
        {:error, "Try: @name <target> <new name>"}
    end
  end

  defp do_alias(%Parser.Command{argv: argv}, _ctx) when length(argv) < 2 do
    {:error, "Try: @alias <target> <new alias>"}
  end

  # CX-8iyv: `@alias <target> <newalias...>` — adds an alias to an
  # object so it becomes addressable by that phrase in later
  # take/drop/look/@desc/@name lookups (which already match against
  # aliases via `World.find_entry_by_name/3`; this is the missing
  # setter). Target may be multi-word; whatever argv remains after the
  # greedy target match becomes the (possibly multi-word) new alias.
  defp do_alias(%Parser.Command{argv: argv}, ctx) do
    case Resolver.split_target_and_rest(argv, ctx) do
      {:ok, target_label, new_alias} when new_alias != "" ->
        add_object_alias(target_label, new_alias, ctx)

      _ ->
        {:error, "Try: @alias <target> <new alias>"}
    end
  end

  defp add_object_alias(target, new_alias, ctx) do
    case Resolver.find_entry_in_dirs(target, [ctx.current_room_uuid, ctx.inventory_uuid], ctx.store) do
      {:ok, entry} ->
        if String.ends_with?(entry.name, ".obj") do
          case Schemas.load_object(entry.node_id, ctx.store) do
            {:ok, %Object{aliases: aliases}} ->
              new_aliases = if new_alias in aliases, do: aliases, else: aliases ++ [new_alias]

              case World.set_meta(entry.node_id, Schemas.object_filename(), "aliases", new_aliases, ctx.store, write_opts(ctx)) do
                :ok -> {:reply, "#{target} can now also be called \"#{new_alias}\"."}
                {:error, reason} -> {:error, commit_error_reply(reason)}
              end

            _ ->
              {:error, "Can't alias #{target}."}
          end
        else
          {:error, "Can only alias objects."}
        end

      :error ->
        {:error, "You don't see \"#{target}\" here."}
    end
  end

  defp update_meta_description(target, text, ctx) do
    update_meta(target, "description", text, ctx)
  end

  defp update_meta(target, key, value, ctx) do
    cond do
      target in ["here", "room"] ->
        case World.set_meta(ctx.current_room_uuid, Schemas.room_filename(), key, value, ctx.store, write_opts(ctx)) do
          :ok -> {:reply, "Updated room #{key}."}
          {:error, reason} -> {:error, commit_error_reply(reason)}
        end

      true ->
        # CX-df64 — search the actor's INVENTORY too, not just the room:
        # `@desc`/`@name`/`@alias` must reach an object you're CARRYING,
        # not only one lying in the room (mirrors `resolve_target_object`'s
        # [inventory, room] precedence and the `split_target_and_rest` fix
        # above — the target label this function receives may itself have
        # resolved via inventory, so re-resolving room-only here would
        # silently re-lose it).
        case Resolver.find_entry_in_dirs(target, [ctx.inventory_uuid, ctx.current_room_uuid], ctx.store) do
          {:ok, entry} ->
            filename =
              cond do
                String.ends_with?(entry.name, ".obj") -> Schemas.object_filename()
                true -> nil
              end

            if filename do
              case World.set_meta(entry.node_id, filename, key, value, ctx.store, write_opts(ctx)) do
                :ok -> {:reply, "Updated #{target} #{key}."}
                {:error, reason} -> {:error, commit_error_reply(reason)}
              end
            else
              {:error, "Can't update #{target} #{key}."}
            end

          :error ->
            {:error, "You don't see \"#{target}\" here."}
        end
    end
  end

  # CX-Camillo-C2: `auto_extend_section/3`, `update_room_exit/4`,
  # `instance_obj_entry/2`, and the room-dig/object-create write-cores moved to
  # `Commonplace.MUD.Build` (one impl, two entry points). The @create-room and
  # @link heads above call `Build.auto_extend_section`/`Build.update_room_exit`
  # directly; `write_opts/1` below delegates to `Build.write_opts/1` so every
  # existing call site in this module is unchanged.

  # CX-4u03 A3: the former `add_dir_entry/4` (raw player-signed schema add to an
  # arbitrary parent — used by @dig/@create to attach under the GLOBAL root) is
  # GONE. Every builder create now routes through `ChildMutation.create_zoned_child`
  # (attach under the player's home subtree, node-signed zone-stamp) — no
  # un-stamped/root-attached build path survives (bound (1) no-bypass).

  # CX-avgu — the inverse of the old add_dir_entry: unlink `entry_name` from
  # `parent_uuid`'s schema, signed (SAME enforce-gate as the add).
  defp remove_dir_entry(parent_uuid, entry_name, ctx) do
    store = ctx.store
    {:ok, schema} = Schemas.load_dir_schema(parent_uuid, store)
    schema = Schema.remove_entry(schema, entry_name)
    update = Yelixer.Encoding.encode_update(schema)

    {metadata, commit_opts} =
      SignedWrite.opts_for(parent_uuid, Keyword.put(write_opts(ctx), :store, store))

    case CommitStoreClient.create_chained_commit(store, parent_uuid, update, metadata, commit_opts) do
      {:error, _} = err -> err
      _commit -> :ok
    end
  end

  # CX-93ea: shared translator from a swallowed-no-longer write error to
  # the player-visible reply text. `{:trust_rejected, _}` is the
  # expected/common case under `local_write_gate: :enforce`; everything
  # else (namespace rejection, store errors, etc.) gets a generic
  # failure message — never silence, never false success.
  defp commit_error_reply({:trust_rejected, _reason}), do: "You don't have permission to build here."
  # CX-4u03 A3: the ChildMutation link pre-check denies an unauthorized build
  # (a player building outside their home subtree, or with no build cert) with
  # :link_unauthorized — the same "you can't build here" class as a gate reject.
  defp commit_error_reply(:link_unauthorized), do: "You don't have permission to build here."
  defp commit_error_reply(_other), do: "Something went wrong and that change didn't take effect."

  # CX-lg06: the ctx -> {store, signing_context, cert_cids, signer_id}
  # opts adapter every write call site in this module goes through — one
  # seam, so a session's resolved identity (see `PlayerSession`) reaches
  # every commit-producing verb without re-deriving it downstream.
  # CX-Camillo-C2: the canonical impl now lives in `Commonplace.MUD.Build` (so
  # the citizen orchestrator and the verb path share ONE adapter); this delegates
  # to keep every call site in this module unchanged.
  defp write_opts(ctx), do: Build.write_opts(ctx)

  # CX-ix9n: TAKE is push-not-pull — the node elevates and pushes the
  # item to the taker (see `Commonplace.MUD.Take`), so the taker's own
  # signing context never rides the write. Only their bare identity_uuid
  # (the possession-token holder) is needed.
  #
  # CX-ud1u (rendering extraction): made public (was `defp`) so
  # `Commonplace.MUD.Render.render_room/1` — which needs the viewer
  # identity for `World.room_snapshot/4`'s read-scoping check — can call
  # it without duplicating the signing-context lookup.
  @doc "The invoker's bare identity_uuid from `ctx.signing_context`, or `nil`."
  def taker_identity(ctx) do
    case ctx[:signing_context] do
      %{identity_uuid: id} when is_binary(id) -> id
      # no signed identity -> Take returns {:error, :bad_arg}, refused gracefully
      _ -> nil
    end
  end

  # CX-ix9n: thread the invoker's OWN write context (store + signing_context
  # + cert_cids + signer_id). `Take` uses it two ways: to test whether the
  # invoker is already authorized over both dirs (permissive mode, or the
  # item's owner) — in which case the move runs invoker-signed, UNCHANGED
  # from before — and, only for the genuine enforce visitor who is not, it
  # ignores the invoker signing and builds its own node context to elevate.
  # CX-1mz7: TAKE needs the world root so its zone-gate can classify the
  # source room (shared-curated vs the taker's own home vs another's home).
  defp take_opts(ctx), do: Keyword.put(write_opts(ctx), :root_uuid, Map.get(ctx, :root_uuid))

  # CX-wkau (MUD-as-documents Inc-1, tranche 3) — PROMOTED verb-authoring
  # surface: the ONE promotion this tranche needs. Returns EXACTLY what
  # `do_go/2` (and, via `do_teleport/2`, `do_home/1`) has always passed to
  # `World.move_presence/5` — built from the INVOKING SESSION's own
  # `signing_context`/`cert_cids` (via `write_opts/1`) plus its bare identity
  # as `:viewer` (via `taker_identity/1`, the CX-avzp read-gate's caller
  # identity). NO elevation happens here: worst case a doc-hosted mover acts
  # AS THE INVOKER (the same authority the compiled floor already carries),
  # never as the node. `do_go/2`/`do_teleport/2` (home's mover) and the
  # doc-hosted `go`/`home` seeds (`priv/engine_verbs/go.exs.seed` /
  # `home.exs.seed`) all call this ONE function, so there is a single source
  # of truth for what "the invoker's move opts" means across every mover.
  @doc false
  def invoker_move_opts(ctx), do: Keyword.put(write_opts(ctx), :viewer, taker_identity(ctx))

  # CX-j2wt — possession-move opts: `write_opts` PLUS the invoker's
  # SERVER-RESOLVED durable inventory uuid, so `HolderMove.ensure_mover_holds`
  # can re-anchor an orphaned `:available` token that sits in the invoker's OWN
  # inventory (the drop/give/put phantom-unwedge). `ctx.inventory_uuid` is
  # resolved at session bootstrap (nil for a non-durable session → the re-anchor
  # guard fails closed). NEVER a client-supplied value — see
  # `HolderMove.own_inventory_reanchor?`'s load-bearing note.
  defp possession_opts(ctx), do: Keyword.put(write_opts(ctx), :invoker_inventory_uuid, Map.get(ctx, :inventory_uuid))

  # ---- Scope resolution ----
  #
  # CX-ud1u — moved to `Commonplace.MUD.Resolver`. `resolve_target/2` stays
  # here as a public delegator: it's a promoted verb-authoring surface
  # referenced by name (`Commonplace.MUD.Verbs.resolve_target/2`) from
  # `priv/engine_verbs/examine.exs.seed` and `read.exs.seed`, and directly
  # by `Commonplace.MUD.VerbsSafeDispatchTest`/`engine_module_test.exs`, so
  # it can't simply move without breaking those call sites.

  # CX-wkau (MUD-as-documents Inc-1, tranche 1) — PROMOTED verb-authoring
  # surface: the minimal combined greedy-match + type-resolve glue that
  # `do_examine/2` and `do_read/2` both need, exposed so their doc-hosted
  # seeds (`priv/engine_verbs/examine.exs.seed` / `read.exs.seed`) can reach
  # entity resolution WITHOUT the private `greedy_match_entry/4` /
  # `resolve_entry/2` machinery (and its `find_entry_in_dirs/3` ranking/
  # visibility internals) being copied into a doc or made public wholesale.
  @doc false
  def resolve_target(argv, ctx), do: Resolver.resolve_target(argv, ctx)
end
