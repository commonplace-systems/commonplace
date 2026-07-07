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

  alias Commonplace.MUD.{Parser, Schemas, Sections, SignedWrite, VerbSource, World}
  alias Commonplace.MUD.Schemas.{Object, Player, Room}
  alias Commonplace.MUD.World.Facade
  alias Commonplace.Tree.Schema
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Trust.{Capability, VerifyChain}

  require Logger

  @builders ~w(@dig @create @desc @name @alias @listen @dump @verb @link @unlink @teleport @go)

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
  @builtins ~w(look say emote take get drop give put inventory who quit help go) ++
              ~w(north south east west up down in out)

  @doc "Dispatch a parsed command. Returns one of the verb-result tuples."
  def dispatch(%Parser.Command{verb: ""}, _ctx), do: :ok

  def dispatch(%Parser.Command{verb: verb} = cmd, ctx) do
    cond do
      verb in @builders ->
        dispatch_builder(verb, cmd, ctx)

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
    case resolve_target_object(cmd, ctx) do
      {:ok, uuid, name} ->
        if verb_source_exists?(uuid, verb_name, ctx.store) do
          {:ok, :object, uuid, name}
        else
          :not_found
        end

      :none ->
        find_verb_by_scope_scan(verb_name, ctx)
    end
  end

  defp resolve_target_object(%Parser.Command{target: nil}, _ctx), do: :none

  defp resolve_target_object(%Parser.Command{target: target}, ctx) do
    case World.find_entry_by_name(ctx.inventory_uuid, target, ctx.store) do
      {:ok, entry} ->
        {:ok, entry.node_id, entry.name}

      :error ->
        case World.find_entry_by_name(ctx.current_room_uuid, target, ctx.store) do
          {:ok, entry} -> {:ok, entry.node_id, entry.name}
          :error -> :none
        end
    end
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
    object_uuid = if host_kind == :object, do: host_uuid, else: nil
    section_scope = [host_uuid]
    owner_grant = owner_grant_for(host_uuid, ctx.store)
    via_verb = {source_uuid, host_name}

    facade = Facade.new(ctx, object_uuid, owner_grant, via_verb, ctx.store)
    args = %{target: cmd.target, argv: cmd.argv, args: cmd.args}

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
      {:ok, _} ->
        :ok

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
      |> CommitStoreClient.commit_log(host_uuid, limit: 10_000)
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

    case verified_scopes do
      [] -> MapSet.new([host_uuid])
      scopes -> MapSet.new(scopes)
    end
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

  defp dispatch_builtin("look", cmd, ctx), do: do_look(cmd, ctx)
  defp dispatch_builtin("say", cmd, ctx), do: do_say(cmd, ctx)
  defp dispatch_builtin("emote", cmd, ctx), do: do_emote(cmd, ctx)
  defp dispatch_builtin("take", cmd, ctx), do: do_take(cmd, ctx)
  defp dispatch_builtin("get", cmd, ctx), do: do_take(cmd, ctx)
  defp dispatch_builtin("drop", cmd, ctx), do: do_drop(cmd, ctx)
  defp dispatch_builtin("give", cmd, ctx), do: do_give(cmd, ctx)
  defp dispatch_builtin("put", cmd, ctx), do: do_put(cmd, ctx)
  defp dispatch_builtin("inventory", _cmd, ctx), do: do_inventory(ctx)
  defp dispatch_builtin("who", _cmd, ctx), do: do_who(ctx)
  defp dispatch_builtin("quit", _cmd, _ctx), do: {:reply, :quit}
  defp dispatch_builtin("help", _cmd, _ctx), do: {:reply, help_text()}
  defp dispatch_builtin("go", cmd, ctx), do: do_go(List.first(cmd.argv), ctx)

  defp dispatch_builtin(dir, _cmd, ctx) when dir in ~w(north south east west up down in out) do
    do_go(dir, ctx)
  end

  defp dispatch_builtin(_verb, _cmd, _ctx), do: :unhandled

  # ---- look ----

  defp do_look(%Parser.Command{argv: []}, ctx) do
    {:reply, render_room(ctx)}
  end

  defp do_look(%Parser.Command{target: target}, ctx) when target in ["here", "room"] do
    {:reply, render_room(ctx)}
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
    do_look_in_container(rest, ctx)
  end

  defp do_look(%Parser.Command{argv: argv}, ctx) do
    phrase_label = Enum.join(argv, " ")

    case greedy_match_entry([ctx.inventory_uuid, ctx.current_room_uuid], argv, ctx.store) do
      {:ok, entry, _phrase, _remainder} ->
        render_looked_at_entry(entry, phrase_label, ctx)

      :not_found ->
        {:error, "You don't see \"#{phrase_label}\" here."}
    end
  end

  # CX-cj3t.1.1: plain "look <obj>" on a container renders its contents
  # instead of the description; a non-container object keeps the old
  # name+description behavior unchanged.
  defp render_looked_at_entry(entry, phrase_label, ctx) do
    case resolve_entry(entry, ctx) do
      {:ok, :object, %Object{container?: true} = obj} ->
        {:reply, render_container_contents(entry.node_id, obj.name, ctx)}

      {:ok, :object, %Object{} = obj} ->
        {:reply, "#{obj.name}\n#{obj.description}"}

      {:ok, :player, %Player{} = pl} ->
        title = if pl.title == "", do: pl.name, else: pl.title
        {:reply, "#{title}\n#{pl.description}"}

      :not_found ->
        {:error, "You don't see \"#{phrase_label}\" here."}
    end
  end

  defp do_look_in_container(argv, ctx) do
    container_phrase = Enum.join(argv, " ")

    case resolve_container(container_phrase, [ctx.inventory_uuid, ctx.current_room_uuid], ctx) do
      {:ok, container_entry, %Object{} = container_obj} ->
        {:reply, render_container_contents(container_entry.node_id, container_obj.name, ctx)}

      {:error, {:not_a_container, name}} ->
        {:error, "You can't look inside the #{name}."}

      {:error, :not_found} ->
        {:error, "You don't see \"#{container_phrase}\" here."}
    end
  end

  defp render_container_contents(container_uuid, container_name, ctx) do
    items =
      World.list_objects_in(container_uuid, ctx.store)
      |> Enum.map(fn e ->
        case Schemas.load_object(e.node_id, ctx.store) do
          {:ok, %Object{name: name}} -> name
          _ -> e.name |> String.replace_suffix(".obj", "")
        end
      end)

    case items do
      [] -> "The #{container_name} is empty."
      _ -> "The #{container_name} contains: #{Enum.join(items, ", ")}."
    end
  end

  # CX-cj3t.1.1: shared container resolver for `put`/`get ... from`/
  # `look in` — finds `phrase` in `dirs` (in order) and requires the
  # matched `.obj` to have `container?: true`; a non-container match
  # returns its name so callers can give a precise "not a container"
  # error rather than a generic not-found.
  defp resolve_container(phrase, dirs, ctx) do
    case find_entry_in_dirs(phrase, dirs, ctx.store) do
      {:ok, entry} ->
        case Schemas.load_object(entry.node_id, ctx.store) do
          {:ok, %Object{container?: true} = obj} -> {:ok, entry, obj}
          {:ok, %Object{name: name}} -> {:error, {:not_a_container, name}}
          _ -> {:error, :not_found}
        end

      :error ->
        {:error, :not_found}
    end
  end

  defp render_room(ctx) do
    case World.get_room(ctx.current_room_uuid, ctx.store) do
      {:ok, %Room{} = room} ->
        players = list_other_players(ctx)
        objects = list_room_objects(ctx)
        exits = room.exits |> Map.keys() |> Enum.sort()

        IO.iodata_to_binary([
          "== ", room.name, " ==\n",
          room.description, "\n",
          if(exits == [], do: "Exits: (none)\n", else: ["Exits: ", Enum.join(exits, ", "), "\n"]),
          if(objects == [], do: "", else: ["You see: ", Enum.join(objects, ", "), "\n"]),
          if(players == [], do: "", else: ["Players: ", Enum.join(players, ", "), "\n"])
        ])

      {:error, _} ->
        "(this place has no description)"
    end
  end

  defp list_other_players(ctx) do
    self_name = ctx.presence_filename

    World.list_players_in(ctx.current_room_uuid, ctx.store)
    |> Enum.reject(fn e -> e.name == self_name end)
    |> Enum.map(fn e -> e.name |> String.replace_suffix(".usr", "") end)
  end

  defp list_room_objects(ctx) do
    World.list_objects_in(ctx.current_room_uuid, ctx.store)
    |> Enum.map(fn e ->
      case Schemas.load_object(e.node_id, ctx.store) do
        {:ok, %Object{name: name}} -> name
        _ -> e.name |> String.replace_suffix(".obj", "")
      end
    end)
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
           resolve_container(container_phrase, [ctx.current_room_uuid, ctx.inventory_uuid], ctx),
         {:ok, entry, _phrase, _remainder} <-
           greedy_match_entry([container_entry.node_id], item_words, ctx.store),
         {:ok, %Object{} = obj} <- Schemas.load_object(entry.node_id, ctx.store),
         :ok <-
           World.move(entry.node_id, entry.name, container_entry.node_id, ctx.inventory_uuid, write_opts(ctx)) do
      World.broadcast_room(ctx.current_room_uuid, %{
        kind: :get_from,
        who: ctx.player_name,
        what: obj.name,
        from: container_obj.name
      })

      {:reply, "You get #{obj.name} from #{container_obj.name}."}
    else
      {:error, {:not_a_container, name}} -> {:error, "You can't get things from the #{name}."}
      {:error, :not_found} -> {:error, "You don't see \"#{container_phrase}\" here."}
      :not_found -> {:error, "You don't see \"#{item_phrase_label}\" in #{container_phrase}."}
      {:error, :gone} -> {:error, "It slipped from your grasp."}
      {:error, :collision} -> {:error, "You're already carrying one of those."}
      {:error, {:trust_rejected, _}} -> {:error, "You don't have permission to take that."}
      _ -> {:error, "You can't take that."}
    end
  end

  # CX-8iyv: greedy-match the full remaining phrase against room entries
  # (names + aliases) so multi-word object names/aliases resolve
  # ('take silver coin' matches an object named/aliased "silver coin"),
  # not just the first word.
  defp do_take_plain(argv, ctx) do
    phrase_label = Enum.join(argv, " ")

    with {:ok, entry, _phrase, _remainder} <- greedy_match_entry([ctx.current_room_uuid], argv, ctx.store),
         true <- takable_entry?(entry) || {:error, "You can't take that."},
         {:ok, %Object{} = obj} <- Schemas.load_object(entry.node_id, ctx.store),
         :ok <- ensure_not_fixed(obj),
         :ok <- World.move(entry.node_id, entry.name, ctx.current_room_uuid, ctx.inventory_uuid, write_opts(ctx)) do
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
      {:error, msg} when is_binary(msg) -> {:error, msg}
      _ -> {:error, "You can't take that."}
    end
  end

  defp takable_entry?(%Schema.Entry{type: :dir, name: name}), do: String.ends_with?(name, ".obj")
  defp takable_entry?(_), do: false

  defp ensure_not_fixed(%Object{fixed: true, name: name}), do: {:error, "#{name} is fixed in place."}
  defp ensure_not_fixed(_), do: :ok

  defp do_drop(%Parser.Command{argv: []}, _ctx), do: {:error, "Drop what?"}

  # CX-8iyv: greedy-match the full remaining phrase against inventory
  # entries (names + aliases), same rationale as `do_take/2`.
  defp do_drop(%Parser.Command{argv: argv}, ctx) do
    phrase_label = Enum.join(argv, " ")

    with {:ok, entry, _phrase, _remainder} <- greedy_match_entry([ctx.inventory_uuid], argv, ctx.store),
         {:ok, %Object{} = obj} <- Schemas.load_object(entry.node_id, ctx.store),
         :ok <- World.move(entry.node_id, entry.name, ctx.inventory_uuid, ctx.current_room_uuid, write_opts(ctx)) do
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
    case greedy_match_entry([ctx.inventory_uuid], argv, ctx.store, min_remainder: 1) do
      {:ok, _entry, phrase, remainder} when remainder != [] ->
        give_item_to(phrase, Enum.join(remainder, " "), ctx)

      _ ->
        {:error, "Give what to whom? Try: give <item> to <player>"}
    end
  end

  defp give_item_to(item_phrase, target_phrase, ctx) do
    with {:ok, obj_entry} <- World.find_entry_by_name(ctx.inventory_uuid, item_phrase, ctx.store),
         {:ok, %Object{} = obj} <- Schemas.load_object(obj_entry.node_id, ctx.store),
         {:ok, target_inv_uuid, target_player_name} <- find_player_inventory(target_phrase, ctx),
         :ok <- World.move(obj_entry.node_id, obj_entry.name, ctx.inventory_uuid, target_inv_uuid, write_opts(ctx)) do
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
      _ -> {:error, "You can't give that."}
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
          {:ok, inv_uuid} -> {:ok, inv_uuid, bare}
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

  defp split_on_in(argv) do
    case Enum.split_while(argv, fn w -> String.downcase(w) != "in" end) do
      {item_words, [_in | rest]} -> {item_words, rest}
      {_all, []} -> {argv, []}
    end
  end

  defp put_item_in(item_words, container_words, ctx) do
    item_phrase_label = Enum.join(item_words, " ")
    container_phrase = Enum.join(container_words, " ")

    with {:ok, source_dir, item_entry} <- locate_item_for_put(item_words, ctx),
         {:ok, %Object{} = obj} <- Schemas.load_object(item_entry.node_id, ctx.store),
         {:ok, container_entry, %Object{} = container_obj} <-
           resolve_container(container_phrase, [ctx.current_room_uuid, ctx.inventory_uuid], ctx),
         move_opts <-
           Keyword.put(write_opts(ctx), :precheck, fn ->
             cycle_guard(item_entry.node_id, container_entry.node_id, ctx.store)
           end),
         :ok <-
           World.move(item_entry.node_id, item_entry.name, source_dir, container_entry.node_id, move_opts) do
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
    case greedy_match_entry([ctx.inventory_uuid], item_words, ctx.store) do
      {:ok, entry, _phrase, _remainder} ->
        {:ok, ctx.inventory_uuid, entry}

      :not_found ->
        case greedy_match_entry([ctx.current_room_uuid], item_words, ctx.store) do
          {:ok, entry, _phrase, _remainder} -> {:ok, ctx.current_room_uuid, entry}
          :not_found -> :not_found
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
  @cycle_guard_max_depth 32

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

  defp bfs_contains?(_frontier, _visited, _target, _store, depth) when depth > @cycle_guard_max_depth, do: false
  defp bfs_contains?([], _visited, _target, _store, _depth), do: false

  defp bfs_contains?(frontier, visited, target_uuid, store, depth) do
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
    names = walk_collect_players(ctx.root_uuid, ctx.store) |> Enum.sort() |> Enum.uniq()

    text =
      case names do
        [] -> "Nobody is logged in."
        _ -> "Players online:\n  - " <> Enum.join(names, "\n  - ")
      end

    {:reply, text}
  end

  defp walk_collect_players(dir_uuid, store) do
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
         :ok <- World.move(ctx.player_uuid, ctx.presence_filename, ctx.current_room_uuid, dest_uuid, write_opts(ctx)) do
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
      {:error, {:trust_rejected, _}} -> {:error, "You don't have permission to go #{direction}."}
      _ -> {:error, "You can't go #{direction}."}
    end
  end

  defp wrap_fetch({:ok, _} = ok), do: ok
  defp wrap_fetch(:error), do: :error

  # ---- Builder verbs ----

  defp dispatch_builder("@dig", cmd, ctx), do: do_dig(cmd, ctx)
  defp dispatch_builder("@create", cmd, ctx), do: do_create(cmd, ctx)
  defp dispatch_builder("@desc", cmd, ctx), do: do_desc(cmd, ctx)
  defp dispatch_builder("@name", cmd, ctx), do: do_rename(cmd, ctx)
  defp dispatch_builder("@alias", cmd, ctx), do: do_alias(cmd, ctx)
  defp dispatch_builder("@listen", _cmd, ctx), do: {:reply, "Now listening to room #{ctx.current_room_uuid}. (Debug: red events will appear inline.)"}
  defp dispatch_builder("@verb", cmd, ctx), do: do_verb_edit(cmd, ctx)
  defp dispatch_builder("@link", cmd, ctx), do: do_link(cmd, ctx)
  defp dispatch_builder("@unlink", cmd, ctx), do: do_unlink(cmd, ctx)
  defp dispatch_builder("@teleport", cmd, ctx), do: do_teleport(cmd, ctx)
  defp dispatch_builder("@go", cmd, ctx), do: do_teleport(cmd, ctx)

  defp dispatch_builder("@dump", cmd, ctx) do
    cond do
      cmd.target in [nil, "here", "room"] ->
        case World.get_room(ctx.current_room_uuid, ctx.store) do
          {:ok, room} -> {:reply, inspect(room, pretty: true)}
          _ -> {:error, "no room"}
        end

      true ->
        case find_in_scope(cmd.argv, ctx) do
          {:ok, :object, obj} -> {:reply, inspect(obj, pretty: true)}
          {:ok, :player, pl} -> {:reply, inspect(pl, pretty: true)}
          _ -> {:error, "Can't find \"#{Enum.join(cmd.argv, " ")}\"."}
        end
    end
  end

  defp do_verb_edit(%Parser.Command{argv: argv}, _ctx) when length(argv) < 1 do
    {:error, "Try: @verb <target>:<verbname>"}
  end

  defp do_verb_edit(%Parser.Command{argv: [spec | _]}, ctx) do
    case String.split(spec, ":", parts: 2) do
      [target, verb_name] when verb_name != "" ->
        cond do
          target in ["here", "room"] ->
            current = read_current_source(ctx.current_room_uuid, verb_name, ctx)
            {:enter_editor, %{target_uuid: ctx.current_room_uuid, target_label: "here", verb_name: verb_name, current: current}}

          true ->
            case World.find_entry_by_name(ctx.current_room_uuid, target, ctx.store) do
              {:ok, %Schema.Entry{type: :dir, name: name, node_id: uuid}} ->
                if String.ends_with?(name, ".obj") do
                  current = read_current_source(uuid, verb_name, ctx)
                  {:enter_editor, %{target_uuid: uuid, target_label: target, verb_name: verb_name, current: current}}
                else
                  {:error, "Can only edit verbs on objects (or here/room)."}
                end

              _ ->
                case World.find_entry_by_name(ctx.inventory_uuid, target, ctx.store) do
                  {:ok, %Schema.Entry{type: :dir, name: name, node_id: uuid}} ->
                    if String.ends_with?(name, ".obj") do
                      current = read_current_source(uuid, verb_name, ctx)
                      {:enter_editor, %{target_uuid: uuid, target_label: target, verb_name: verb_name, current: current}}
                    else
                      {:error, "Can only edit verbs on objects (or here/room)."}
                    end

                  _ ->
                    {:error, "You don't see \"#{target}\" here or in inventory."}
                end
            end
        end

      _ ->
        {:error, "Try: @verb <target>:<verbname>"}
    end
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
  defp do_dig_write_new_room(direction, opposite, name, ctx) do
    json = Schemas.encode_room(%Room{name: name, description: "(no description yet)", exits: %{opposite => ctx.current_room_uuid}})

    with {:ok, new_room_uuid} <- Schemas.create_dir_with_meta(Schemas.room_filename(), json, ctx.store, write_opts(ctx)),
         :ok <- add_dir_entry(ctx.root_uuid, name, new_room_uuid, ctx),
         :ok <- update_room_exit(ctx.current_room_uuid, direction, new_room_uuid, ctx) do
      # CX-qat5.5: the new room is dug FROM ctx.current_room_uuid, so
      # that's the section context — any node-issued root section cert
      # covering it gets reissued to also cover new_room_uuid. See
      # `Sections.auto_extend_for_new_room/3` for the full rules.
      auto_extend_section(new_room_uuid, ctx.current_room_uuid, ctx.store)

      {:reply, "You carve out a new room (#{name}). #{String.capitalize(direction)} leads there."}
    else
      {:error, reason} -> {:error, commit_error_reply(reason)}
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
            case update_room_exit(ctx.current_room_uuid, direction, room_uuid, ctx) do
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
        case World.get_room(ctx.current_room_uuid, ctx.store) do
          {:ok, %Room{exits: exits} = room} ->
            if Map.has_key?(exits, direction) do
              new_exits = Map.delete(exits, direction)
              json = Schemas.encode_room(%Room{room | exits: new_exits})

              case write_current_room_meta(ctx.current_room_uuid, json, ctx) do
                :ok -> {:reply, "Removed the exit #{direction}."}
                {:error, reason} -> {:error, commit_error_reply(reason)}
              end
            else
              {:reply, "There is no exit #{direction} to remove."}
            end

          {:error, reason} ->
            {:error, commit_error_reply(reason)}
        end
    end
  end

  defp write_current_room_meta(room_dir_uuid, json, ctx) do
    with {:ok, schema} <- Schemas.load_dir_schema(room_dir_uuid, ctx.store),
         {:ok, entry} <- Schema.get_entry(schema, Schemas.room_filename()) do
      Schemas.write_meta_doc(entry.node_id, json, ctx.store, write_opts(ctx))
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
        case World.move(ctx.player_uuid, ctx.presence_filename, ctx.current_room_uuid, room_uuid, write_opts(ctx)) do
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
    name = Enum.join(name_parts, " ")
    obj_json = Schemas.encode_object(%Object{name: name, description: "(no description yet)"})

    with {:ok, new_obj_uuid} <- Schemas.create_dir_with_meta(Schemas.object_filename(), obj_json, ctx.store, write_opts(ctx)),
         :ok <- add_dir_entry(ctx.current_room_uuid, "#{name}.obj", new_obj_uuid, ctx) do
      {:reply, "You create a #{name}."}
    else
      {:error, reason} -> {:error, commit_error_reply(reason)}
    end
  end

  defp do_create(%Parser.Command{argv: ["room" | name_parts]}, ctx) do
    name = Enum.join(name_parts, " ")
    json = Schemas.encode_room(%Room{name: name, description: "(no description yet)"})

    with {:ok, new_uuid} <- Schemas.create_dir_with_meta(Schemas.room_filename(), json, ctx.store, write_opts(ctx)),
         :ok <- add_dir_entry(ctx.root_uuid, name, new_uuid, ctx) do
      # CX-qat5.5: `@create room` always builds a DISCONNECTED room (no
      # exit links it to `ctx.current_room_uuid`) — there is no section
      # context to anchor a cert-extend inference to, so this passes `nil`
      # and `auto_extend_for_new_room/3` is a documented no-op
      # (`{:ok, :no_context}`). If `@create` ever grows a variant that
      # attaches the new room to the current section, thread that room's
      # uuid through here instead of `nil`.
      auto_extend_section(new_uuid, nil, ctx.store)

      {:reply, "You create a new disconnected room (#{name})."}
    else
      {:error, reason} -> {:error, commit_error_reply(reason)}
    end
  end

  defp do_create(%Parser.Command{argv: [other | _]}, _ctx) do
    {:error, "Unknown kind: #{other} (try object or room)"}
  end

  defp do_desc(%Parser.Command{argv: argv}, _ctx) when length(argv) < 2, do: {:error, "Try: @desc <target> <text>"}

  # CX-8iyv: target may itself be multi-word ("silver coin") with no
  # explicit separator from the text that follows it — greedy-match the
  # longest prefix of argv against room entries (names + aliases),
  # requiring at least one word left over for the description text.
  defp do_desc(%Parser.Command{argv: argv}, ctx) do
    case split_target_and_rest(argv, ctx) do
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
    case split_target_and_rest(argv, ctx) do
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
    case split_target_and_rest(argv, ctx) do
      {:ok, target_label, new_alias} when new_alias != "" ->
        add_object_alias(target_label, new_alias, ctx)

      _ ->
        {:error, "Try: @alias <target> <new alias>"}
    end
  end

  defp add_object_alias(target, new_alias, ctx) do
    case find_entry_in_dirs(target, [ctx.current_room_uuid, ctx.inventory_uuid], ctx.store) do
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
        case World.find_entry_by_name(ctx.current_room_uuid, target, ctx.store) do
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

  # CX-qat5.5: best-effort issuance automation, never a hard gate on room
  # creation — a lookup/mint failure here (e.g. no node signing key yet)
  # is logged, not surfaced as a verb error; the room was already carved
  # successfully. See `Sections.auto_extend_for_new_room/3` moduledoc for
  # the full policy (node-issued-only, root-certs-only, context-anchored).
  defp auto_extend_section(new_room_uuid, context_room_uuid, store) do
    case Sections.auto_extend_for_new_room(new_room_uuid, context_room_uuid, store: store) do
      {:ok, _results} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Commonplace.MUD.Verbs: section cert auto-extend for new room " <>
            "#{new_room_uuid} failed: #{inspect(reason)}"
        )

        :ok
    end
  end

  # CX-lg06: `ctx` carries the resolved session identity
  # (`:signing_context` / `:cert_cids` / `:signer_id`, set up once at
  # `PlayerSession` ingress) — `write_opts/1` below turns that into the
  # keyword list `Commonplace.MUD.SignedWrite` and `World`/`Move` expect.
  # CX-93ea: was `CommitStoreClient.create_chained_commit(...); :ok` —
  # the commit result was thrown away, so a trust-gate denial under
  # `:enforce` still reported `:ok` up to every builder verb call site.
  # Now checked and propagated.
  defp add_dir_entry(parent_uuid, name, child_uuid, ctx) do
    store = ctx.store
    {:ok, schema} = Schemas.load_dir_schema(parent_uuid, store)
    schema = Schema.add_directory(schema, name, child_uuid)
    update = Yelixer.Encoding.encode_update(schema)

    {metadata, commit_opts} =
      SignedWrite.opts_for(parent_uuid, Keyword.put(write_opts(ctx), :store, store))

    case CommitStoreClient.create_chained_commit(store, parent_uuid, update, metadata, commit_opts) do
      {:error, _} = err -> err
      _commit -> :ok
    end
  end

  defp update_room_exit(room_dir_uuid, direction, dest_uuid, ctx) do
    store = ctx.store

    case World.get_room(room_dir_uuid, store) do
      {:ok, %Room{} = room} ->
        new_exits = Map.put(room.exits, direction, dest_uuid)
        json = Schemas.encode_room(%Room{room | exits: new_exits})
        {:ok, schema} = Schemas.load_dir_schema(room_dir_uuid, store)
        {:ok, entry} = Schema.get_entry(schema, Schemas.room_filename())
        Schemas.write_meta_doc(entry.node_id, json, store, write_opts(ctx))

      err ->
        err
    end
  end

  # CX-93ea: shared translator from a swallowed-no-longer write error to
  # the player-visible reply text. `{:trust_rejected, _}` is the
  # expected/common case under `local_write_gate: :enforce`; everything
  # else (namespace rejection, store errors, etc.) gets a generic
  # failure message — never silence, never false success.
  defp commit_error_reply({:trust_rejected, _reason}), do: "You don't have permission to build here."
  defp commit_error_reply(_other), do: "Something went wrong and that change didn't take effect."

  # CX-lg06: the ctx -> {store, signing_context, cert_cids, signer_id}
  # opts adapter every write call site in this module goes through — one
  # seam, so a session's resolved identity (see `PlayerSession`) reaches
  # every commit-producing verb without re-deriving it downstream.
  defp write_opts(ctx) do
    [
      store: ctx.store,
      signing_context: Map.get(ctx, :signing_context),
      cert_cids: Map.get(ctx, :cert_cids, []),
      signer_id: Map.get(ctx, :signer_id)
    ]
  end

  # ---- Scope resolution ----

  # CX-8iyv: multi-word targets — greedy-match the longest prefix of
  # `argv` against inventory first, then the current room (names +
  # aliases via `World.find_entry_by_name/3`), so 'look silver coin'
  # resolves an object named/aliased "silver coin" instead of just
  # matching the word "silver".
  defp find_in_scope(argv, ctx) do
    case greedy_match_entry([ctx.inventory_uuid, ctx.current_room_uuid], argv, ctx.store) do
      {:ok, entry, _phrase, _remainder} -> resolve_entry(entry, ctx)
      :not_found -> :not_found
    end
  end

  # CX-8iyv: shared greedy phrase matcher for target-taking verbs
  # (take/drop/look/@dump/@desc/@name/@alias). Tries the longest prefix
  # of `argv` first (down to a single word), searching `dirs` in order
  # for each candidate phrase, so multi-word names/aliases win over
  # shorter partial matches. `min_remainder` reserves that many trailing
  # words (e.g. so `@desc <target> <text>` always leaves at least one
  # word for the text) — the match never consumes more than
  # `length(argv) - min_remainder` words.
  #
  # Returns `{:ok, entry, matched_phrase, remainder_words}` or
  # `:not_found`.
  defp greedy_match_entry(dirs, argv, store, opts \\ []) do
    min_remainder = Keyword.get(opts, :min_remainder, 0)
    max_len = length(argv) - min_remainder

    if max_len < 1 do
      :not_found
    else
      Enum.reduce_while(max_len..1//-1, :not_found, fn n, _acc ->
        phrase = argv |> Enum.take(n) |> Enum.join(" ")

        case find_entry_in_dirs(phrase, dirs, store) do
          {:ok, entry} -> {:halt, {:ok, entry, phrase, Enum.drop(argv, n)}}
          :error -> {:cont, :not_found}
        end
      end)
    end
  end

  defp find_entry_in_dirs(phrase, dirs, store) do
    Enum.find_value(dirs, :error, fn dir ->
      case World.find_entry_by_name(dir, phrase, store) do
        {:ok, entry} -> {:ok, entry}
        :error -> nil
      end
    end)
  end

  # CX-8iyv: shared helper for @desc/@name/@alias — greedy-match a
  # (possibly multi-word) target against the current room, requiring at
  # least one argv word left over for the text/new-name/new-alias that
  # follows it. "here"/"room" stay single-word literals (never part of a
  # greedy phrase match) so they keep addressing the room itself.
  defp split_target_and_rest(argv, ctx) do
    case argv do
      [kw | rest] when kw in ["here", "room"] and rest != [] ->
        {:ok, kw, Enum.join(rest, " ")}

      _ ->
        case greedy_match_entry([ctx.current_room_uuid], argv, ctx.store, min_remainder: 1) do
          {:ok, _entry, phrase, remainder} -> {:ok, phrase, Enum.join(remainder, " ")}
          :not_found -> :not_found
        end
    end
  end

  defp resolve_entry(%Schema.Entry{} = entry, ctx) do
    cond do
      String.ends_with?(entry.name, ".obj") ->
        case Schemas.load_object(entry.node_id, ctx.store) do
          {:ok, obj} -> {:ok, :object, obj}
          _ -> :not_found
        end

      String.ends_with?(entry.name, ".usr") ->
        load_player_for_lookup(entry, "", ctx)

      true ->
        :not_found
    end
  end

  defp load_player_for_lookup(entry, _needle, ctx) do
    bare = entry.name |> String.replace_suffix(".usr", "")
    path = "players/#{bare}"

    with {:ok, player_dir_uuid} <- World.resolve_path(path, ctx.root_uuid, ctx.store),
         {:ok, player} <- Schemas.load_player(player_dir_uuid, ctx.store) do
      {:ok, :player, player}
    else
      _ -> :not_found
    end
  end

  defp help_text do
    """
    Commands:
      look [target]                    look at the room or a target
      n/s/e/w/u/d  or  go <direction>  move
      say <text>  ('<text>)            speak in the room
      emote <text>                     act out
      take <obj> / drop <obj>          pick up / drop an object
      take/get <obj> from <container>  get something out of a container
      put <obj> in <container>         put something into a container
      look in <container>              see what's inside a container
      give <obj> <player>              give an object to someone here
      i / inventory                    list what you carry
      who                              list players online
      help                             this help
      quit                             disconnect

    Builders:
      @dig <dir> <name>                carve a new room in <dir> (refuses if
                                       <dir> already has an exit)
      @link <dir> <room-uuid>          point <dir> at an existing room
                                       (repoint/recovery; see @dump for uuids)
      @unlink <dir>                    remove the exit in <dir>
      @teleport <room-uuid> (@go)      jump directly to a room by uuid
      @create object|room <name>       create here
      @desc <target> <text>            set description (target: here, or obj name)
      @name <target> <new name>        rename
      @verb <target>:<verbname>        edit a verb on a room/object (line editor;
                                       finish with '.' on its own line, '@abort'
                                       cancels)
      @listen                          subscribe to debug events
      @dump [target]                   dump raw struct
    """
  end
end
