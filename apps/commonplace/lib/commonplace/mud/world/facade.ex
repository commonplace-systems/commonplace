defmodule Commonplace.MUD.World.Facade do
  @moduledoc """
  CX-ndvi §1.2/§2 — the ONLY effect surface a SAFE MUD verb receives.

  A safe verb's `run/2` body is bound to `world` (a `%Facade{}`) and
  `args` — nothing else. There is no `CommitStoreClient`, no raw store
  handle, no raw uuid-addressed write path in scope: every effect a
  verb can cause goes through one of the nine methods below, and every
  one of them is either a pure read or an INTERSECTION-checked write.

  ## HONESTY BOUNDARY (load-bearing)

  This facade is STRUCTURAL LEAST-AUTHORITY for honest-but-buggy code —
  it shrinks the blast radius of a verb that does exactly what its
  author intended but touches something it shouldn't. It is NOT hostile
  code containment: a determined hostile author who found a way to
  smuggle a raw store reference through some future facade method (or a
  BEAM primitive `Commonplace.MUD.SafeVerb.Lint` didn't anticipate)
  would defeat it. `Lint` (defense-in-depth, raised bar, not a sandbox)
  and this facade (least-authority, not containment) are BOTH necessary
  and NEITHER is sufficient — true hostile-code containment is
  OS-level isolation (phase-4, banked). Do not sell facade+lint as
  containment; say so wherever this module is described.

  ## Authority — intersection by two checks (Axis B, CX-ndvi §2)

  A verb's effects are commits SIGNED BY THE INVOKER (`invoker_opts`
  below — never the verb owner, never an ambient/system identity: exact
  accountability). Each WRITE method checks, PER CALL (not once per
  invocation):

    * (a) `Trust.authorized?(invoker, :write, scope)` — is the invoker
      allowed to make this write directly? This is enforced by the
      EXISTING local-write gate
      (`Commonplace.Store.CommitStore`'s `local_write_gate_check/2`,
      `Application.get_env(:commonplace, :local_write_gate)`) the
      moment the facade issues the commit with the invoker's
      `signing_context`/`cert_cids` — this module does not reimplement
      that check, it just always signs as the invoker so the existing
      gate applies. Under `:enforce` a denial comes back as
      `{:error, {:trust_rejected, reason}}`, same shape a direct player
      write would get.
    * (b) `scope ⊆ owner_grant` — is the touched uuid inside the set of
      uuids the verb's OWNER attached as this verb's grant? Checked
      HERE, in this module, BEFORE any commit is attempted — a target
      outside the grant is refused with `{:error, :owner_grant_exceeded}`
      and NO write is even attempted (the invoker's own authority is
      irrelevant to this check — monotone narrowing: the owner cannot
      grant a verb more reach than the owner attached, and the check
      runs regardless of whether the invoker could have done the write
      directly).

  Both must pass. The confused-deputy / setuid case (a verb reaching
  into the OWNER's property on a stranger's behalf) is exactly what (a)
  denies: the stranger-invoker holds no `:write` there, full stop. That
  denial is CORRECT MVP behavior (design doc §3, "the confused-deputy
  edge, deferred deliberately") — phase 3 is a per-verb identity + owner
  cert, its own security review, not attempted here.

  Every write's metadata carries `via_verb: {verb_doc_ref, owner}` (see
  `Commonplace.MUD.SignedWrite.opts_for/2`'s `:via_verb` option) for the
  causal audit trail.

  ## What's in the struct

    * `store` — the commit store server (an implementation detail of
      HOW the facade performs ops; never exposed to verb code, which
      only ever holds the facade value itself).
    * `ctx` — the invoker's session context map (`current_room_uuid`,
      `inventory_uuid`, `player_uuid`, `player_name`, `signing_context`,
      `cert_cids`, `signer_id` — the same shape `Commonplace.MUD.Verbs`
      already threads as `ctx`).
    * `object_uuid` — the object THIS verb is bound to ("self" — MOO's
      `this`), or `nil` for a room-hosted verb with no object binding.
    * `owner_grant` — `MapSet` of uuids the verb's owner attached as
      this invocation's write scope.
    * `via_verb` — `{verb_doc_ref, owner}` audit tag, attached to every
      write this facade issues.

  ## The nine locked methods (jes #5764)

  `look/1`, `describe/2`, `get_attr/2` — reads, unrestricted (same
  posture as the built-in `look`/`@dump` verbs — no authority gate on
  reading what's already visible). `move/2`, `set_attr/3`,
  `create_child/2`, `transfer/3` — writes, intersection-checked.
  `say/2`, `emit/2` — room broadcasts (Phoenix PubSub, not a commit —
  no doc write, so no intersection check applies; same posture as the
  built-in `say`/`emote` verbs).
  """

  require Logger

  alias Commonplace.MUD.{Move, Schemas, SignedWrite, World}
  alias Commonplace.MUD.Schemas.Object
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.Schema
  alias Yelixer.Encoding

  @enforce_keys [:store, :ctx, :owner_grant, :via_verb]
  defstruct store: nil, ctx: nil, object_uuid: nil, owner_grant: MapSet.new(), via_verb: nil, host_kind: :object

  @type t :: %__MODULE__{
          store: GenServer.server(),
          ctx: map(),
          object_uuid: String.t() | nil,
          owner_grant: MapSet.t(),
          via_verb: term(),
          host_kind: :object | :room
        }

  # CX-3x5a — override `def` so every PUBLIC method below has its return
  # post-processed through the drop-accumulator (`__accumulate__/2`), by
  # construction. Placed AFTER `defstruct`/`@type` (so the struct's generated
  # `__struct__` functions compile with normal `Kernel.def`) but BEFORE the
  # first real `def`, so every facade method is wrapped. See `AccumDef`.
  use Commonplace.MUD.World.Facade.AccumDef

  @doc """
  Build a facade. `owner_grant` is any enumerable of uuids (converted to
  a `MapSet`). `via_verb` is the `{verb_doc_ref, owner}` audit tag
  attached to every write this facade issues.
  """
  @spec new(map(), String.t() | nil, Enumerable.t(), term(), GenServer.server()) :: t()
  def new(ctx, object_uuid, owner_grant, via_verb, store \\ CommitStoreClient) do
    %__MODULE__{
      store: store,
      ctx: ctx,
      object_uuid: object_uuid,
      owner_grant: MapSet.new(owner_grant),
      via_verb: via_verb
    }
  end

  # ---- reads (unrestricted) ----

  @doc "Render the current room (name/description/exits) as a plain map."
  @spec look(t()) :: {:ok, map()} | {:error, term()}
  def look(%__MODULE__{} = f) do
    f = unwrap(f)

    case World.get_room(f.ctx.current_room_uuid, f.store) do
      {:ok, room} ->
        {:ok, %{name: room.name, description: room.description, exits: Map.keys(room.exits)}}

      {:error, _} = err ->
        err
    end
  end

  @doc "Name + description text for any room/object/player uuid."
  @spec describe(t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def describe(%__MODULE__{} = f, target_uuid) when is_binary(target_uuid) do
    f = unwrap(f)

    case load_any(target_uuid, f.store) do
      {:ok, %{name: name, description: description}} -> {:ok, "#{name}\n#{description}"}
      {:error, _} = err -> err
    end
  end

  @doc "Raw attribute map (room/object/player metadata) for any target uuid."
  @spec get_attr(t(), String.t()) :: {:ok, map()} | {:error, term()}
  def get_attr(%__MODULE__{} = f, target_uuid) when is_binary(target_uuid) do
    f = unwrap(f)
    load_any(target_uuid, f.store)
  end

  @doc """
  CX-hbua — does the invoker carry an item matching `name_or_uuid`? The
  gated-content READ: a "key" verb checks `actor_carries?(world, "brass
  key")` before unlocking; quest turn-ins, toll gates, "you need a torch".

  SCOPED TO THE INVOKER'S OWN INVENTORY (`f.ctx.inventory_uuid`) — there is
  NO target-player param BY DESIGN, so a verb can never probe another
  player's inventory (privacy). Matches by entry uuid OR by display
  name/alias (the same substring/alias matcher `get`/`take` use). Read-only,
  no authority gate — same posture as `look`/`get_attr` (reading what you
  already hold). Returns a plain boolean (missing inventory → `false`).
  """
  @spec actor_carries?(t(), String.t()) :: boolean()
  def actor_carries?(%__MODULE__{} = f, name_or_uuid) when is_binary(name_or_uuid) do
    f = unwrap(f)

    cond do
      # FOOTGUN GUARD (playtest #6074): a blank/whitespace-only name would
      # substring-match ANY held item (find_entry_by_name's empty needle is
      # in every name), turning a verb that forgot/mis-passed the name into
      # an OPEN gate ("hold anything" → unlock). Fail CLOSED — a real key
      # check must name a real item.
      String.trim(name_or_uuid) == "" ->
        false

      f.ctx[:inventory_uuid] == nil ->
        false

      true ->
        inv = f.ctx[:inventory_uuid]

        carries_by_uuid?(inv, name_or_uuid, f.store) or
          match?({:ok, _}, World.find_entry_by_name(inv, name_or_uuid, f.store))
    end
  end

  defp carries_by_uuid?(inv, uuid, store) do
    case Schemas.load_dir_schema(inv, store) do
      {:ok, schema} -> Enum.any?(Schema.list_entries(schema), &(&1.node_id == uuid))
      _ -> false
    end
  end

  # ---- writes (intersection-checked) ----

  # CX-cj3t.9 (plan-blessed #6069) — THE MOVE SPLIT. The old single `move/2`
  # was room-write intersection on [object, source, dest] and so ALWAYS
  # errored `:owner_grant_exceeded` for gameplay (the default grant {object}
  # covers no rooms) — the case people actually wanted was moving the ACTOR
  # (portals/teleport pads), which is presence-self-authority, NOT a
  # room-write. Split into two methods with SEPARATE authority and NO shared
  # path: `move_self` (presence, never write_guarded) and `move_object`
  # (room-write intersection on BOTH rooms). `move/2` is RETIRED from the
  # allowlist — it never worked, so nothing depends on it, and two explicit
  # names make the authority split legible at the admit-set level.
  #
  # DESIGN RULING (plan #6069, load-bearing): spatial position is
  # NAVIGATION, not access-control. Teleport-to-any-room is CORRECT —
  # presence ≠ authority; you were always allowed to place your presence
  # anywhere (that's what walking is). So content protection MUST be
  # read-scoping or write-gating, NEVER "they can't reach the room." Do not
  # build a security boundary on spatial reachability.

  @doc """
  CX-cj3t.9 — move the INVOKER'S OWN presence into `dest_room_uuid`
  (portals / teleport pads / trapdoors). PRESENCE-SELF-AUTHORITY: mirrors
  the `go` builtin exactly (`World.move` of the invoker's `.usr` presence,
  invoker-signed) and deliberately does NOT call `write_guarded` — moving
  your own presence is not a room-write authority question, it's the same
  thing walking already does. SERVER-FIXED to the invoker (no target-player
  param) — a verb can NEVER move another player. Teleports past exits by
  design (a raw room uuid); the exits-respecting variant is a separate
  future `move_self/exit-name` power, not sugar over this.

  ENFORCE NOTE: `.usr`-into-a-room is a normal schema write and there is no
  presence-authority carve in the write gate today, so `move_self` is
  honest PERMISSIVE-PARITY with the `go` builtin — it surfaces the
  pre-existing enforce-walking gap, does not widen it. Enforce-correct
  movement rides a presence-authority carve OR subtree-scopes (CX-tdkq.23).
  The carve, WHEN designed, MUST key on identity + presence-schema (own
  `.usr`, presence-kind content), NOT on the `.usr` EXTENSION — an
  extension-keyed carve is forgeable, the same filename-trust class as the
  `.safe.elx` bug (plan #6069).
  """
  @spec move_self(t(), String.t()) :: :ok | {:error, term()}
  def move_self(%__MODULE__{} = f, dest_room_uuid) when is_binary(dest_room_uuid) do
    f = unwrap(f)

    World.move(
      f.ctx.player_uuid,
      f.ctx.presence_filename,
      f.ctx.current_room_uuid,
      dest_room_uuid,
      write_opts(f)
    )
  end

  @doc """
  CX-cj3t.9 — move this facade's bound object (`object_uuid`) from the
  invoker's current room into `dest_room_uuid`. ROOM-WRITE INTERSECTION:
  grant-checked against `{object_uuid, current_room_uuid, dest_room_uuid}`
  — ALL THREE must be in `owner_grant` AND the invoker must be able to
  write both rooms. Placing an object into a room modifies that room's
  contents beyond your own presence, so it correctly stays a BUILDER
  capability (room-scoped cert), NOT loosened to gameplay — loosening it
  would let a visitor rearrange a room they don't own.
  """
  @spec move_object(t(), String.t()) :: :ok | {:error, term()}
  # CX-v6j4 (plan #6135) — OBJECT-host only: a room is not a movable object.
  # (host_kind is preserved on the thin verb-facing facade, so this head guard
  # still fires correctly in a verb run — CX-r8vp.)
  def move_object(%__MODULE__{host_kind: :room}, _dest_room_uuid), do: {:error, :requires_object_host}

  def move_object(%__MODULE__{} = f, dest_room_uuid) when is_binary(dest_room_uuid) do
    f = unwrap(f)

    if f.object_uuid == nil do
      {:error, :no_bound_object}
    else
      write_guarded(f, [f.object_uuid, f.ctx.current_room_uuid, dest_room_uuid], fn ->
        case entry_name(f.ctx.current_room_uuid, f.object_uuid, f.store) do
          {:ok, name} ->
            Move.move(f.object_uuid, name, f.ctx.current_room_uuid, dest_room_uuid, write_opts(f))

          :error ->
            {:error, :not_found}
        end
      end)
    end
  end

  @doc """
  Set a metadata attribute (`key`/`value`) on this facade's bound
  object. Grant-checked against `{object_uuid}`.
  """
  @spec set_attr(t(), String.t(), term()) :: :ok | {:error, term()}
  def set_attr(%__MODULE__{} = f, key, value) when is_binary(key) do
    f = unwrap(f)

    if f.object_uuid == nil do
      {:error, :no_bound_object}
    else
      write_guarded(f, [f.object_uuid], fn ->
        World.set_meta(f.object_uuid, meta_filename(f), key, value, f.store, write_opts(f))
      end)
    end
  end

  # CX-hqk5 — freeform per-object state bounds (plan #5968). State lives in
  # __object.json which is a CRDT doc that SYNCS, so bloat = sync/storage
  # cost across every replica — bound it (size only; write-frequency is
  # bounded by the session rate-limit + exec bounds, not here).
  @state_key_max_bytes 64
  @state_value_max_bytes 1024
  @state_max_keys 64
  @state_max_depth 8

  @doc """
  CX-hqk5 — read freeform per-object state written by `put_state/3`.
  Reads the BOUND object's own `meta["state"][key]`; returns the value or
  `nil` (missing key / object). Read-only, bound-object only: there is no
  target-uuid param, so a verb can only read its OWN object's state — NOT
  another object's (cross-object read is a separate, bigger capability by
  design, not smuggled in here).
  """
  @spec get_state(t(), String.t()) :: term()
  def get_state(%__MODULE__{} = f, key) when is_binary(key) do
    f = unwrap(f)

    if f.object_uuid == nil do
      nil
    else
      case World.get_meta_map(f.object_uuid, meta_filename(f), f.store) do
        {:ok, %{"state" => state}} when is_map(state) -> Map.get(state, key)
        _ -> nil
      end
    end
  end

  def get_state(%__MODULE__{}, _key), do: nil

  @doc """
  CX-hqk5 — write freeform per-object state. Owner-scoped (`write_guarded`
  on the bound object, the SAME intersection as `set_attr`) into a
  DEDICATED `meta["state"]` submap, so it can NEVER clobber typed fields
  (name/fixed/container). Bounds (plan #5968 + #6163): key ≤ 64 bytes;
  value any JSON DATA-MODEL term — nil / boolean / number / string / list /
  string-keyed map (NOT atoms-except-true/false/nil, tuples, or structs) —
  nested ≤ 8 deep, whose FULL `Jason.encode` fits ≤ 1024 bytes; ≤ 64 keys
  per object. Over-limit / wrong-shape → `{:error, :state_bounds}`
  (fail-visible, never truncates). One verb `put_state`s, another (or a
  later run) `get_state`s — the whole stateful-mechanic class (lit/unlit,
  unlocked, score, already-solved) plus lists/maps (chords, inventories,
  quest progress).
  """
  @spec put_state(t(), String.t(), term()) :: :ok | {:error, term()}
  def put_state(%__MODULE__{} = f, key, value) when is_binary(key) do
    f = unwrap(f)

    if f.object_uuid == nil do
      {:error, :no_bound_object}
    else
      with :ok <- validate_state_key(key),
           :ok <- validate_state_value(value) do
        # CX-v6j4 — the BOUND host's own meta file (room_filename for a room
        # host, object_filename for an object host). A room's meta is
        # __room.json, NOT __object.json — writing the wrong file failed with
        # :no_meta_entry, so room state never persisted.
        write_guarded(f, [f.object_uuid], fn ->
          do_put_state(f, f.object_uuid, meta_filename(f), key, value)
        end)
      end
    end
  end

  def put_state(%__MODULE__{}, _key, _value), do: {:error, :state_bounds}

  # Shared state-write core (put_state on the bound host; configure_state
  # on a just-minted OBJECT). `meta_file` is the target's meta filename —
  # meta_filename(f) for the bound host (room or object), object_filename
  # for a minted object. The AUTHORITY decision is the CALLER's.
  defp do_put_state(f, target_uuid, meta_file, key, value) do
    state = read_state(f, target_uuid, meta_file)

    if Map.has_key?(state, key) or map_size(state) < @state_max_keys do
      new_state = Map.put(state, key, value)
      World.set_meta(target_uuid, meta_file, "state", new_state, f.store, write_opts(f))
    else
      {:error, :state_bounds}
    end
  end

  defp read_state(f, target_uuid, meta_file) do
    case World.get_meta_map(target_uuid, meta_file, f.store) do
      {:ok, %{"state" => state}} when is_map(state) -> state
      _ -> %{}
    end
  end

  # CX-v6j4 — the bound host's own meta filename. Room hosts keep state in
  # __room.json (the room's meta), object hosts in __object.json.
  defp meta_filename(%__MODULE__{host_kind: :room}), do: Schemas.room_filename()
  defp meta_filename(%__MODULE__{}), do: Schemas.object_filename()

  defp validate_state_key(key) when is_binary(key) do
    if byte_size(key) > 0 and byte_size(key) <= @state_key_max_bytes,
      do: :ok,
      else: {:error, :state_bounds}
  end

  # CX-qexv (plan #6163 BLESSED) — a state value may be any JSON DATA-MODEL
  # term: nil | boolean | number | string | list-of-valid | map with STRING
  # keys of valid values. The SHAPE is checked first (rejecting atoms except
  # true/false/nil, tuples, structs, atom-keyed maps, pids/funs/refs, and
  # anything nested deeper than @state_max_depth), THEN the value's FULL
  # `Jason.encode` byte size must fit @state_value_max_bytes.
  #
  # Two invariants this closes (plan gotchas):
  #  1. ORDERING/no-raise — shape runs BEFORE size, and size uses the
  #     NON-raising `Jason.encode/1`. So the validator itself never raises on
  #     the hostile non-JSON input it exists to reject cleanly.
  #  2. Type-change + encode-raise — rejecting atoms/tuples/structs prevents
  #     both the store's `Jason.encode!` raise (World.set_meta) and the
  #     write-`:foo`/read-`"foo"` footgun (get_state decodes to STRING keys).
  #
  # Structure is spent WITHIN the same 1024-byte per-value budget as the old
  # scalar-only rule — richer shape at IDENTICAL sync-cost ceiling, so
  # plan-#5968's per-object bound is unchanged (≤64 keys × ≤1024 B).
  defp validate_state_value(value) do
    with :ok <- validate_state_shape(value, @state_max_depth) do
      validate_state_size(value)
    end
  end

  defp validate_state_shape(_v, depth) when depth < 0, do: {:error, :state_bounds}
  defp validate_state_shape(v, _d) when is_boolean(v) or is_nil(v) or is_number(v), do: :ok
  defp validate_state_shape(v, _d) when is_binary(v), do: :ok

  defp validate_state_shape(list, depth) when is_list(list) do
    Enum.reduce_while(list, :ok, fn el, :ok ->
      case validate_state_shape(el, depth - 1) do
        :ok -> {:cont, :ok}
        err -> {:halt, err}
      end
    end)
  end

  defp validate_state_shape(map, depth) when is_map(map) do
    # Structs are maps with an atom `__struct__` key → caught by the
    # string-key guard and rejected fail-closed (no struct ever persists).
    Enum.reduce_while(map, :ok, fn {k, v}, :ok ->
      if is_binary(k) do
        case validate_state_shape(v, depth - 1) do
          :ok -> {:cont, :ok}
          err -> {:halt, err}
        end
      else
        {:halt, {:error, :state_bounds}}
      end
    end)
  end

  # atoms (other than the true/false/nil handled above), tuples, pids, funs,
  # refs, ports — not JSON data, fail closed.
  defp validate_state_shape(_other, _depth), do: {:error, :state_bounds}

  # Non-raising by design: the shape check already guarantees encodability,
  # but `Jason.encode/1` ({:ok|:error}) is used — never `encode!/1` — so this
  # measure can't raise even if shape validation and Jason ever disagree.
  defp validate_state_size(value) do
    case Jason.encode(value) do
      {:ok, json} when byte_size(json) <= @state_value_max_bytes -> :ok
      _ -> {:error, :state_bounds}
    end
  end

  # ---- randomness (CX-9plf) — no effect, no authority: just RNG ----
  #
  # CONVERGENCE SAFETY (plan #5976 — load-bearing, don't reopen): RNG in a
  # verb is safe ONLY because verbs are SINGLE-EXECUTION-then-sync. A verb
  # runs ONCE on the node dispatching the player's command; its EFFECTS
  # (commits) sync, and DocBuilder replays those COMMITS, not the verb
  # code — so producing a different number per run can't threaten
  # convergence (there is only one run). REVIEW TRIGGER: if verb dispatch
  # is ever made deterministic-replayable / re-run-per-replica (like
  # compute/snapshot minting), RNG here would diverge each replica —
  # remove RNG or seed it deterministically FIRST.

  @doc """
  CX-9plf — a random integer in `1..n` (dice-style: `random(world, 6)` is
  a d6). `n` must be a positive integer, else `{:error, :bad_arg}`.
  Server-side `:rand` (the allowlist bans `Enum.random`/`:rand` by
  closed-by-default; this is the sanctioned exposure). Cosmetic — no
  effect, no doc write, no authority.
  """
  @spec random(t(), integer()) :: pos_integer() | {:error, :bad_arg}
  def random(%__MODULE__{}, n) when is_integer(n) and n > 0, do: :rand.uniform(n)
  def random(%__MODULE__{}, _n), do: {:error, :bad_arg}

  @doc """
  CX-9plf — a random element of a non-empty list (`nil` if empty or not a
  list). For shuffled flavor text / random fortunes.
  """
  @spec pick(t(), list()) :: term()
  def pick(%__MODULE__{}, []), do: nil
  def pick(%__MODULE__{}, list) when is_list(list), do: Enum.random(list)
  def pick(%__MODULE__{}, _), do: nil

  # ---- invoker identity (CX-a2gd, plan-blessed #6189/#6193) ----
  #
  # THE SPOOF-FIX: a safe verb could not read WHO invoked it, so per-player
  # state forced players to self-TYPE their name as a command arg
  # (spoofable). These expose the SERVER-SET invoker identity from the bound
  # ctx (the SAME value `emit_action/3`/`whisper/3` stamp) — read-only, no
  # effect, no authority (random/2/pick/2 posture). INVOKER-ONLY is
  # STRUCTURAL: there is no parameter to name another player; the ctx is the
  # invoking session's own, so a verb can only ever read ITS OWN caller
  # (same scope discipline as `actor_carries?/2`). Non-secret: the invoker's
  # name/dir are already public (room presence, Players dir, emit
  # attribution) — exposing them to the invoker's OWN verb is no new leak.
  #
  # NOTE (plan #6193): these are the spoof-fix, NOT yet "the secure/opaque
  # interface" — until CX-r8vp closes the verb-facing data surface, the same
  # values remain reachable via `Map.get(world.ctx, ...)`. The spoof-fix is
  # real regardless (the value is server-set); the opacity lands with r8vp.

  @doc """
  CX-a2gd — the invoker's DISPLAY name (server-set, the value `emit_action`
  stamps). Use for narration / display. For a DURABLE per-player state KEY
  use `actor_ref/1` instead — a display name ORPHANS state on an `@name`
  rename and INHERITS it on name-reuse; `actor_ref` is stable.
  """
  @spec actor_name(t()) :: String.t() | nil
  def actor_name(%__MODULE__{} = f) do
    f = unwrap(f)
    f.ctx[:player_name]
  end

  @doc """
  CX-a2gd — a STABLE opaque reference to the invoker (their player-dir uuid),
  for keying durable per-player state: `put_state(world, "score:" <>
  actor_ref(world), n)`. Stable across `@name` renames (unlike
  `actor_name/1`). Opaque — treat it as a key, not a display string.
  """
  @spec actor_ref(t()) :: String.t() | nil
  def actor_ref(%__MODULE__{} = f) do
    f = unwrap(f)
    f.ctx[:player_dir_uuid]
  end

  @doc """
  Create a new child object named `name` under this facade's bound
  object. Grant-checked against `{object_uuid}` (the parent). Returns
  `{:ok, new_uuid}` on success.
  """
  @spec create_child(t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def create_child(%__MODULE__{} = f, name) when is_binary(name) do
    f = unwrap(f)

    if f.object_uuid == nil do
      {:error, :no_bound_object}
    else
      # CX-cj3t.1.1 — now shares the capped/charged creator with `spawn`, so
      # create_child is subject to the SAME per-container (M=128) and
      # per-invocation (N=8) bounds (it was previously uncapped — a latent
      # object-spam DoS). Authority is unchanged: strict intersection on the
      # bound object.
      with :ok <- charge_lifecycle_op() do
        write_guarded(f, [f.object_uuid], fn -> create_object_in(f, f.object_uuid, name) end)
      end
    end
  end

  @doc """
  Transfer `item_uuid` from the invoker's inventory into
  `dest_container_uuid` (the give/receive primitive — CX-pe8d). Grant-
  checked against `{item_uuid, inventory_uuid, dest_container_uuid}`.
  """
  @spec transfer(t(), String.t(), String.t()) :: :ok | {:error, term()}
  def transfer(%__MODULE__{} = f, item_uuid, dest_container_uuid)
      when is_binary(item_uuid) and is_binary(dest_container_uuid) do
    f = unwrap(f)

    write_guarded(f, [item_uuid, f.ctx.inventory_uuid, dest_container_uuid], fn ->
      case entry_name(f.ctx.inventory_uuid, item_uuid, f.store) do
        {:ok, name} ->
          Move.move(item_uuid, name, f.ctx.inventory_uuid, dest_container_uuid, write_opts(f))

        :error ->
          {:error, :not_found}
      end
    end)
  end

  # ---- object lifecycle (CX-cj3t.1.1, plan-blessed #5991) ----
  #
  # THE KEYSTONE (plan #5991, the setuid trap): spawn/consume/destroy_child
  # touch OWNER-controlled scope (a room / the bound object). They MUST pass
  # the FULL intersection — invoker-authority (check (a), via signing the
  # commit as the invoker in `write_opts/1`, enforced downstream by the
  # local-write gate) AND `owner_grant` (check (b), via `write_guarded/3`).
  # Grant-checking ONLY `owner_grant` would be SETUID-BY-ACCIDENT: a visitor
  # invoking the owner's verb would spawn/destroy with the OWNER's authority
  # the visitor doesn't hold — rights-amplification, the confused-deputy
  # class DEFERRED to phase-3 with its own security review. So spawn into
  # room R needs the invoker to be able to write R; consuming a room-fixed
  # object needs invoker room-write (a VISITOR is correctly BLOCKED by
  # check (a) — that's the deferred setuid case, not smuggled in here).
  #
  # `give_to_actor/2` is THE ONE EXCEPTION (named distinctly so nobody
  # "fixes" it to intersect and breaks rewards): it writes the INVOKER's
  # OWN inventory, which `owner_grant` does not cover (the invoker's
  # inventory is not the owner's property to grant) — so it deliberately
  # SKIPS `write_guarded` and relies on invoker-authority alone (the
  # invoker can always write their own inventory) plus a SERVER-FIXED
  # recipient (the invoker; no victim-targeting param). Not setuid (the
  # invoker exercises only their own authority), not intersected (nothing
  # of the owner's is touched).
  #
  # BOUNDS (two-tier, plan #5991): a PER-CONTAINER child cap
  # (`@container_max_entries`, M=128 — objects are synced CRDT docs, so an
  # uncapped container is a cross-replica sync/storage DoS) fail-visible as
  # `{:error, :container_full}`; a PER-INVOCATION op cap
  # (`@lifecycle_ops_per_run`, N=8 — a verb legitimately makes 1-3 objects)
  # fail-visible as `{:error, :spawn_limit}`. Total-world / per-principal
  # object budget is DEFERRED to broader-tier hardening (an author can
  # spawn→drop→spawn to grow total objects over time; contained for INVITED
  # by the session rate-limit + per-container cap + snapshot-compaction, but
  # an OPEN-adversarial tier would need a per-principal budget — CX-n2j2
  # class, not an invited blocker).

  @container_max_entries 128
  @lifecycle_ops_per_run 8
  @lifecycle_op_counter :cp_safe_verb_lifecycle_ops
  # CX-nyj9 — the per-run minted-set (uuids created this run) backing the
  # own-creation exception for configure_*. Server-populated only, in this
  # run's process dict; author code can't reach it (Process is banned).
  @minted_set_key :cp_safe_verb_minted_set

  @doc """
  Spawn a new object named `name` into the invoker's current room.
  STRICT INTERSECTION on the room (`write_guarded` + invoker-signed) —
  the invoker must be able to write the room AND the room must be in
  `owner_grant` (a room-scoped cert on the bound object). Returns
  `{:ok, new_uuid}`. Bounded (see the lifecycle header).
  """
  @spec spawn(t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def spawn(%__MODULE__{} = f, name) when is_binary(name) do
    f = unwrap(f)

    with :ok <- charge_lifecycle_op() do
      room = f.ctx[:current_room_uuid]
      write_guarded(f, [room], fn -> create_object_in(f, room, name) end)
    end
  end

  @doc """
  Create a new object named `name` directly into the INVOKER's own
  inventory (the reward/give-out primitive). THE ONE EXCEPTION to
  intersection (see the lifecycle header): invoker-authority only
  (their own inventory), server-fixed recipient, NO `owner_grant` check.
  Returns `{:ok, new_uuid}`. Bounded (see the lifecycle header).
  """
  @spec give_to_actor(t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def give_to_actor(%__MODULE__{} = f, name) when is_binary(name) do
    f = unwrap(f)

    with :ok <- charge_lifecycle_op() do
      case f.ctx[:inventory_uuid] do
        nil ->
          {:error, :no_inventory}

        inv ->
          # DELIBERATELY no write_guarded — see the header. Still
          # invoker-signed via write_opts/1 (check (a) applies).
          create_object_in(f, inv, name)
      end
    end
  end

  @doc """
  Destroy (UNLINK — not hard-delete; the doc stays in history, the entry
  drops, GC-reachability handles liveness) the invoker's BOUND object.
  Locates the object's parent container (inventory first, then the current
  room — mirroring dispatch's own resolution order). If the parent is the
  invoker's OWN inventory, this is the invoker-own-container case (consume
  a thing you CARRY — invoker-authority only, same reasoning as
  `give_to_actor`); otherwise FULL INTERSECTION on `[parent, object]` (a
  visitor consuming a room-fixed object is blocked by invoker-authority —
  the deferred setuid case). Bounded (per-invocation cap).
  """
  @spec consume(t()) :: :ok | {:error, term()}
  # CX-v6j4 (plan #6135) — OBJECT-host only: a room's children are shared/
  # mixed-ownership, and consume/destroy_child guard only the parent, so
  # they must not fire on room hosts (cross-owner setuid). host_kind is
  # preserved on the thin verb-facing facade, so this head guard still fires.
  def consume(%__MODULE__{host_kind: :room}), do: {:error, :requires_object_host}

  def consume(%__MODULE__{} = f) do
    f = unwrap(f)

    if f.object_uuid == nil do
      {:error, :no_bound_object}
    else
      with :ok <- charge_lifecycle_op() do
        case locate_parent(f, f.object_uuid) do
          {:ok, parent_uuid, entry} ->
            if parent_uuid == f.ctx[:inventory_uuid] do
              # Invoker-own-inventory: consume what you carry (see header).
              unlink_child(parent_uuid, entry, f)
            else
              write_guarded(f, [parent_uuid, f.object_uuid], fn ->
                unlink_child(parent_uuid, entry, f)
              end)
            end

          :error ->
            {:error, :not_found}
        end
      end
    end
  end

  @doc """
  Destroy (UNLINK) a named child object of the invoker's BOUND object.
  STRICT INTERSECTION on the bound object (`write_guarded` + invoker-
  signed) — symmetric with `create_child/2`, which the child lives under.
  Bounded (per-invocation cap).
  """
  @spec destroy_child(t(), String.t()) :: :ok | {:error, term()}
  # CX-v6j4 (plan #6135) — OBJECT-host only (see consume). host_kind is
  # preserved on the thin verb-facing facade, so this head guard still fires.
  def destroy_child(%__MODULE__{host_kind: :room}, _name), do: {:error, :requires_object_host}

  def destroy_child(%__MODULE__{} = f, name) when is_binary(name) do
    f = unwrap(f)

    if f.object_uuid == nil do
      {:error, :no_bound_object}
    else
      with :ok <- charge_lifecycle_op() do
        write_guarded(f, [f.object_uuid], fn ->
          # CX-lfo3 — children now carry instance-unique entry keys
          # ("<name>-<short-uuid>.obj"), so resolve the child by DISPLAY name
          # (the same substring/alias matcher the MUD's get/take use) rather
          # than a literal "<name>.obj" key. Destroys ONE match (like `get`).
          case World.find_entry_by_name(f.object_uuid, name, f.store) do
            {:ok, entry} -> unlink_child(f.object_uuid, entry.name, f)
            :error -> {:error, :not_found}
          end
        end)
      end
    end
  end

  # ---- own-inventory quest/gift verbs (CX-5u5j, plan-blessed #6171) ----
  #
  # Two own-inventory-authorized effect methods, distinct from the
  # bound-object `consume/1`/`give_to_actor/2` above:
  #
  #   * `consume_from_inventory/2` — "eat a held item" (quest turn-in).
  #     Own-inventory authority ONLY (same basis as give_to_actor and the
  #     invoker-own branch of consume/1): resolves a name in the invoker's
  #     OWN `inventory_uuid`, NO `write_guarded`, NO owner_grant — the
  #     invoker can always write their own inventory, so it's invoker-signed
  #     via `write_opts(f)` alone. DISTINCT from `consume/1` (which is a
  #     bound-object owner-scope INTERSECTION); do not merge them.
  #
  #   * `give_from_inventory/3` — push a held item into a SAME-ROOM
  #     recipient's inventory mailbox. Authority basis: the invoker acts
  #     with their OWN item-authority and deposits ADDITIVELY into the
  #     recipient's inbox — it is NOT setuid (never borrows the recipient's
  #     authority; the recipient-container write is signed by the INVOKER).
  #
  # ENFORCE-ANCHOR (comment only — not gated on here): give_from_inventory's
  # DEPOSIT writes the RECIPIENT'S inventory doc, which the invoker does not
  # own. In permissive dogfood this just works. Under `:enforce` it would be
  # rejected by the local-write gate exactly like any other cross-owner
  # write and would need an inbox-write-policy cert — the SAME permissive-
  # now/enforce-later shape as mint (CX-nyj9), and the same anchor the
  # existing `give_to_actor`/facade cross-owner writes already inherit. This
  # module does NOT implement that policy and makes NO enforce-correctness
  # claim; the property preserved TODAY is the least-authority shape
  # (own-item basis + same-room gate + additive-only + server-stamped
  # attribution), matching the module's honesty boundary.

  @doc """
  CX-5u5j — consume (UNLINK) a named item from the invoker's OWN inventory
  (`f.ctx.inventory_uuid`): the quest-turn-in "eat a held item". OWN-
  INVENTORY AUTHORITY ONLY — resolves `name` in the invoker's own inventory
  (via `World.find_entry_by_name/3`), and DELIBERATELY skips `write_guarded`
  / owner_grant (the invoker can always write their own inventory), staying
  invoker-signed via `write_opts(f)` — the SAME basis as `give_to_actor/2`
  and the invoker-own branch of `consume/1`. DISTINCT from `consume/1`,
  which is a bound-object owner-scope intersection; keep them separate.

  Destroy = UNLINK (the append-only store keeps history; no hard delete, no
  live orphan). Bounded by the per-invocation lifecycle op cap (N=8).
  Returns BARE STATUS only — `:ok`, `{:error, :not_carrying}` (blank name,
  non-binary name, or no matching held item), `{:error, :no_inventory}`
  (no `inventory_uuid`), or `{:error, :spawn_limit}` (op cap). NEVER echoes
  the item's uuid/internals (returns-axis: no data leak).
  """
  @spec consume_from_inventory(t(), String.t()) :: :ok | {:error, term()}
  def consume_from_inventory(%__MODULE__{} = f, name) when is_binary(name) do
    f = unwrap(f)

    cond do
      # nil inventory → fail closed, before charging or any lookup.
      f.ctx[:inventory_uuid] == nil ->
        {:error, :no_inventory}

      # FOOTGUN GUARD (mirrors actor_carries?): a blank/whitespace name
      # would substring-match ANY held item — fail CLOSED before any lookup.
      String.trim(name) == "" ->
        {:error, :not_carrying}

      true ->
        with :ok <- charge_lifecycle_op() do
          inv = f.ctx[:inventory_uuid]

          case World.find_entry_by_name(inv, name, f.store) do
            # Own-inventory authority: NO write_guarded, invoker-signed only.
            {:ok, entry} -> unlink_child(inv, entry.name, f)
            :error -> {:error, :not_carrying}
          end
        end
    end
  end

  # name not a binary → fail closed (returns-axis: bare status, no leak).
  def consume_from_inventory(%__MODULE__{}, _name), do: {:error, :not_carrying}

  @doc """
  CX-5u5j — push a named item from the invoker's OWN inventory into a
  SAME-ROOM recipient's inventory (a gift into their mailbox). Own-item
  authority: the invoker acts with their own item-authority and deposits
  ADDITIVELY into the recipient's inbox — NOT setuid (never borrows the
  recipient's authority). Invoker-signed via `write_opts(f)`.

  SECURITY-CRITICAL ORDERING (no-global-oracle, load-bearing — mirrors
  `whisper/3`): the SAME-ROOM gate runs BEFORE any global players-dir
  lookup. The recipient is verified present in the invoker's CURRENT room
  by exact-matching `recipient_name <> ".usr"` against
  `World.list_players_in(current_room)` — ONLY THEN is the recipient's
  inventory resolved by walking `root → "players" → recipient_name →
  "inventory"`. An off-room name fails IDENTICALLY (`:recipient_not_here`)
  whether or not that player exists elsewhere in the world; a resolution
  step missing anywhere in the walk ALSO fails closed as
  `:recipient_not_here` (never a distinct error that would leak
  in-room-but-no-inventory).

  The DEPOSIT uses an INSTANCE-UNIQUE dest entry key (CX-lfo3 style,
  derived from the item's own uuid) so it is ADDITIVE — it can NEVER
  overwrite or collide with a recipient's existing same-named item, and it
  can NOT remove or alter any other recipient item. Bounded by the
  per-invocation op cap (N=8) and the recipient container cap (M=128 →
  `:container_full`). NARRATION `who` is SERVER-STAMPED from
  `f.ctx[:player_name]` (never author-supplied), mirroring
  `emit_action/3`/`whisper/3`.

  Returns BARE STATUS only — `:ok`, `{:error, :not_carrying}`,
  `{:error, :recipient_not_here}`, `{:error, :container_full}`,
  `{:error, :no_inventory}`, or `{:error, :spawn_limit}`. NEVER echoes the
  recipient's inventory contents or updated state (returns-axis: the
  recipient inventory must not leak to the invoker's verb).
  """
  @spec give_from_inventory(t(), String.t(), String.t()) :: :ok | {:error, term()}
  def give_from_inventory(%__MODULE__{} = f, name, recipient_name)
      when is_binary(name) and is_binary(recipient_name) do
    f = unwrap(f)

    with :ok <- charge_lifecycle_op(),
         {:ok, inv} <- own_inventory(f),
         {:ok, entry, display} <- resolve_own_item(f, inv, name),
         # no-global-oracle: same-room gate BEFORE any global players-dir walk.
         :ok <- same_room_recipient_gate(f, recipient_name),
         {:ok, recipient_inv} <- resolve_recipient_inventory(f, recipient_name) do
      deposit_gift(f, inv, entry, display, recipient_inv, recipient_name)
    end
  end

  # non-binary name/recipient → fail closed.
  def give_from_inventory(%__MODULE__{}, _name, _recipient_name), do: {:error, :not_carrying}

  defp own_inventory(%__MODULE__{} = f) do
    case f.ctx[:inventory_uuid] do
      nil -> {:error, :no_inventory}
      inv -> {:ok, inv}
    end
  end

  # Resolve `name` in the invoker's OWN inventory only — a local lookup,
  # never a global one, so it reveals nothing about the recipient and is
  # safe to run before the same-room gate. Blank/whitespace name fails
  # closed (would substring-match any held item). Returns
  # `{:ok, entry, display_name}` or `{:error, :not_carrying}`.
  defp resolve_own_item(%__MODULE__{} = f, inv, name) do
    if String.trim(name) == "" do
      {:error, :not_carrying}
    else
      case World.find_entry_by_name(inv, name, f.store) do
        {:ok, entry} -> {:ok, entry, item_display_name(f, entry)}
        :error -> {:error, :not_carrying}
      end
    end
  end

  # The item's clean display name (meta "name"), used for the instance-
  # unique dest key and the narration. Falls back to the entry's own name
  # if the object meta can't be read.
  defp item_display_name(%__MODULE__{} = f, entry) do
    case World.get_object(entry.node_id, f.store) do
      {:ok, %{name: name}} when is_binary(name) and name != "" -> name
      _ -> entry.name
    end
  end

  # no-global-oracle gate (property 1, mirrors whisper/3): the recipient
  # must be PRESENT in the invoker's CURRENT room. Exact-match on
  # `recipient_name <> ".usr"` among the room's `.usr` presence entries —
  # NO global player lookup here. Blank recipient fails closed. An off-room
  # (or nonexistent) name is `:recipient_not_here` indistinguishably.
  defp same_room_recipient_gate(%__MODULE__{} = f, recipient_name) do
    cond do
      String.trim(recipient_name) == "" ->
        {:error, :recipient_not_here}

      true ->
        presence = recipient_name <> ".usr"

        names =
          f.ctx[:current_room_uuid]
          |> case do
            nil -> []
            room -> World.list_players_in(room, f.store) |> Enum.map(& &1.name)
          end

        if presence in names, do: :ok, else: {:error, :recipient_not_here}
    end
  end

  # Resolve the recipient's inventory ONLY AFTER the same-room gate: walk
  # `root → "players" → recipient_name → "inventory"`. Any missing step →
  # `:recipient_not_here` (fail closed; do not leak a distinct
  # in-room-but-no-inventory error).
  defp resolve_recipient_inventory(%__MODULE__{} = f, recipient_name) do
    with root when is_binary(root) <- f.ctx[:root_uuid],
         {:ok, players} <- child_dir(root, "players", f.store),
         {:ok, player_dir} <- child_dir(players, recipient_name, f.store),
         {:ok, inv} <- child_dir(player_dir, "inventory", f.store) do
      {:ok, inv}
    else
      _ -> {:error, :recipient_not_here}
    end
  end

  defp child_dir(parent_uuid, name, store) do
    case Schemas.load_dir_schema(parent_uuid, store) do
      {:ok, schema} ->
        case Schema.get_entry(schema, name) do
          {:ok, entry} -> {:ok, entry.node_id}
          :error -> :error
        end

      _ ->
        :error
    end
  end

  # ADDITIVE deposit: add the item to the recipient inventory under an
  # INSTANCE-UNIQUE key (never clobbers/collides with an existing recipient
  # item), THEN unlink it from the invoker's own inventory. Dest-add FIRST
  # (a mid-op failure leaves the item in BOTH inventories, recoverable —
  # never in neither, silently lost), mirroring Move's ordering. Recipient
  # container cap (M=128) is enforced before the add. Narrates a server-
  # stamped give action.
  defp deposit_gift(%__MODULE__{} = f, source_inv, entry, display, recipient_inv, recipient_name) do
    case Schemas.load_dir_schema(recipient_inv, f.store) do
      {:ok, schema} ->
        if length(Schema.list_entries(schema)) >= @container_max_entries do
          {:error, :container_full}
        else
          dest_key = instance_entry_name(display, entry.node_id)

          with :ok <- add_child_entry(recipient_inv, dest_key, entry.node_id, f),
               :ok <- unlink_child(source_inv, entry.name, f) do
            narrate_give(f, display, recipient_name)
            :ok
          end
        end

      {:error, _} = err ->
        err
    end
  end

  # SERVER-STAMPED attribution (mirrors emit_action/3): `who` is filled from
  # the bound ctx, never author-supplied. Cosmetic room broadcast (PubSub,
  # no doc write, no authority input).
  defp narrate_give(%__MODULE__{} = f, display, recipient_name) do
    World.broadcast_room(f.ctx.current_room_uuid, %{
      kind: :action,
      who: f.ctx[:player_name],
      first_person: "give #{display} to #{recipient_name}",
      third_person: "gives #{display} to #{recipient_name}"
    })
  end

  # ---- configure a freshly-minted object (CX-nyj9, plan-blessed #6028) ----
  #
  # THE OWN-CREATION EXCEPTION (plan #6028, ruling a): operating on an
  # object THIS RUN minted (spawn/give_to_actor/create_child returned its
  # uuid) is INVOKER-AUTHORIZED — the invoker signed its creation, so
  # writing it is within their own authority, and a fresh uuid is in
  # nobody's owner_grant, so requiring owner_grant would wrongly block it.
  # Same shape as the own-inventory exception (give_to_actor / consume-
  # carried). So configure_* SKIP write_guarded but stay invoker-signed
  # (write_opts).
  #
  # TWO KEYSTONE PINS (plan #6028):
  #   1. The minted-set is SERVER-TRACKED, this-run, UN-FORGEABLE: it lives
  #      in this run's spawn_monitor-child process dict (like the N=8
  #      counter), populated ONLY by `create_object_in`'s own return values
  #      (`record_minted/1`). Author code cannot touch it — `Process` is
  #      allowlist-banned — and cannot inject a uuid: the author PASSES a
  #      uuid, but configure_* VALIDATE it against the set.
  #   2. A UUID IS NEVER A BEARER TOKEN: mint now returns uuids to author
  #      code, so every uuid-taking method must RE-GATE. configure_* re-gate
  #      via minted-set membership (a non-minted uuid → `:not_minted_here`);
  #      `transfer/3` re-gates via `write_guarded` (owner_grant). A known
  #      uuid alone never authorizes anything.
  #
  # ENFORCE-MODE STATUS = CASE B (plan #6032): PERMISSIVE-DOGFOOD-CORRECT
  # ONLY. The minted-set is a FACADE-level re-gate (it stops author code
  # configuring an ARBITRARY uuid) — it does NOT satisfy the local-write
  # gate. That gate runs INSIDE the CommitStore GenServer, a different
  # process with no access to this safe-verb child's process-dict minted-
  # set, so minted-set membership cannot authorize the write there. A minted
  # object is a fresh uuid absent from the invoker's explicit {:docs, uuids}
  # :write cert, so under ENFORCE a set_meta/put_state to it is rejected by
  # the gate for a scoped (non-root) invoker — the SAME anchor wall as
  # define_on. Enforce-correctness for configure_* rides SUBTREE-SCOPES
  # (CX-tdkq.23 Wrinkle-H: a {:subtree, section_root} cert covers minted
  # objects under the section), landing WITH zone-ownership — NOT object-
  # level auto-extend (which would inherit the CX-rmuk cert-laundering hole).
  # SECURITY is unaffected: the setuid protection (spawn-cross-owner refused)
  # holds under enforce because ROOMS are explicit-uuid certs; only minted-
  # object config/behavior RICHNESS is permissive-only until subtree-scopes.
  #
  # (`define_on` — defining VERBS on a minted object — is the :define_verb-
  # level sibling, held pending plan's section-anchor ruling; see CX-nyj9.)

  @doc """
  CX-nyj9 — set a metadata attribute (`key`/`value`) on an object THIS RUN
  minted. Own-creation :write exception (see the section header): no
  owner_grant, invoker-signed, uuid re-gated against the minted-set. Turns
  a minted husk into a real item (description/stats). `{:error,
  :not_minted_here}` if `minted_uuid` was not minted this run.
  """
  @spec configure_attr(t(), String.t() | {:ok, String.t()}, String.t(), term()) :: :ok | {:error, term()}
  # CX-hbua/DX (boss #6045) — accept the mint's `{:ok, uuid}` return
  # directly, so `configure_attr(world, give_to_actor(world, "sword"), ...)`
  # works without the author manually destructuring. Still re-gates (unwraps
  # then falls to the binary clause → minted_this_run? check).
  def configure_attr(%__MODULE__{} = f, {:ok, minted_uuid}, key, value),
    do: configure_attr(f, minted_uuid, key, value)

  def configure_attr(%__MODULE__{} = f, minted_uuid, key, value)
      when is_binary(minted_uuid) and is_binary(key) do
    f = unwrap(f)

    if minted_this_run?(minted_uuid) do
      World.set_meta(minted_uuid, Schemas.object_filename(), key, value, f.store, write_opts(f))
    else
      {:error, :not_minted_here}
    end
  end

  # CX-ssi6 — mistyped args (a non-binary key, or a minted ref that's neither
  # {:ok, uuid} nor a bare uuid string) → a clean {:error, :bad_arg} instead of
  # a FunctionClauseError crash. Surfaced as a dim author-diagnostic (CX-3x5a),
  # so the author sees the type mistake — fail-visible, not fail-crash.
  def configure_attr(%__MODULE__{}, _minted, _key, _value), do: {:error, :bad_arg}

  @doc """
  CX-nyj9 — write freeform per-object state (`key`/`value`, same dedicated
  `meta["state"]` submap + bounds as `put_state/3`) on an object THIS RUN
  minted. Own-creation :write exception (see the section header): no
  owner_grant, invoker-signed, uuid re-gated against the minted-set.
  `{:error, :not_minted_here}` if `minted_uuid` was not minted this run.
  """
  @spec configure_state(t(), String.t() | {:ok, String.t()}, String.t(), term()) :: :ok | {:error, term()}
  # CX-hbua/DX — accept the mint's `{:ok, uuid}` return directly (see
  # configure_attr). Still re-gates via the binary clause below.
  def configure_state(%__MODULE__{} = f, {:ok, minted_uuid}, key, value),
    do: configure_state(f, minted_uuid, key, value)

  def configure_state(%__MODULE__{} = f, minted_uuid, key, value)
      when is_binary(minted_uuid) and is_binary(key) do
    f = unwrap(f)

    with :ok <- validate_state_key(key),
         :ok <- validate_state_value(value) do
      if minted_this_run?(minted_uuid) do
        # A minted object is always an OBJECT — its meta is __object.json.
        do_put_state(f, minted_uuid, Schemas.object_filename(), key, value)
      else
        {:error, :not_minted_here}
      end
    end
  end

  # CX-ssi6 — see configure_attr's catch-all: mistyped args → clean {:error,
  # :bad_arg} (dim author-note via CX-3x5a) instead of a FunctionClauseError.
  def configure_state(%__MODULE__{}, _minted, _key, _value), do: {:error, :bad_arg}

  # ---- broadcasts (no doc write — no intersection check) ----

  @doc "Say `text` aloud in the invoker's current room."
  @spec say(t(), String.t()) :: :ok
  def say(%__MODULE__{} = f, text) when is_binary(text) do
    f = unwrap(f)
    World.broadcast_room(f.ctx.current_room_uuid, %{kind: :say, who: f.ctx[:player_name], text: text})
  end

  @doc """
  CX-<notify> — deliver `text` PRIVATELY to the INVOKER only (not the room)
  as plain, non-speech feedback. This is the puzzle-feedback channel: verb
  STATUS / self-directed results ("The gong resonates. Charge 3/5.") that
  would otherwise leak as `say` ("You say, ...") — mechanics shouted into the
  room + spamming co-present players. Delivered on the invoker's own actor-
  only tell topic (the SAME channel `whisper/3` + the CX-3x5a author-
  diagnostic use), rendered `kind: :notice` (plain text, NOT `:say`/
  `:whisper`). INVOKER-ONLY is structural: no target parameter, so a verb can
  only ever notify ITS OWN caller. Low-trust: no doc write, no authority, no
  rate cap (self-feedback) — strictly weaker than `whisper/3`.
  """
  @spec notify(t(), String.t()) :: :ok
  def notify(%__MODULE__{} = f, text) when is_binary(text) do
    f = unwrap(f)
    World.tell(f.ctx[:player_uuid], %{kind: :notice, text: text})
  end

  @doc """
  Broadcast a custom, UNATTRIBUTED text event to the invoker's current
  room. The author supplies only text (or a map carrying a `:text`); the
  event is server-stamped `kind: :custom` so an author CANNOT forge a
  first-class attributed event — `%{kind: :say | :take | :give | ...,
  who: "<victim>"}` — that `PlayerSession.render_event` would attribute
  to another player (CX-aw4r impersonation fix). For ATTRIBUTED actions
  ("You lift the lid" / "toby lifts the lid") use `emit_action/3`, which
  fills the actor name server-side.
  """
  @spec emit(t(), String.t() | map()) :: :ok
  def emit(%__MODULE__{} = f, event) do
    f = unwrap(f)
    World.broadcast_room(f.ctx.current_room_uuid, %{kind: :custom, text: coerce_text(event)})
  end

  defp coerce_text(text) when is_binary(text), do: text
  defp coerce_text(%{text: text}) when is_binary(text), do: text
  defp coerce_text(other), do: inspect(other)

  @doc """
  Broadcast an ATTRIBUTED action to the invoker's current room. The
  author passes only templates — a first-person form (`"lift the lid"`)
  and a third-person form (`"lifts the lid"`); the actor's name is filled
  SERVER-SIDE from the bound ctx (the author never sees or sets it — raw
  actor-name access stays banned by the allowlist). The actor reads
  `"You <first_person>"`, every observer reads `"<name> <third_person>"`
  — composed per-recipient at render time, exactly like the builtin
  `say`. Cosmetic render-only attribution: no doc write, no effect, so
  `who` is display metadata, never an authorization input.
  """
  @spec emit_action(t(), String.t(), String.t()) :: :ok
  def emit_action(%__MODULE__{} = f, first_person, third_person)
      when is_binary(first_person) and is_binary(third_person) do
    f = unwrap(f)

    World.broadcast_room(f.ctx.current_room_uuid, %{
      kind: :action,
      who: f.ctx[:player_name],
      first_person: first_person,
      third_person: third_person
    })
  end

  # CX-cj3t.10 — the per-target rate cap (harassment bound, plan #6050).
  @whisper_per_target_per_run 3
  # CX-cj3t.10 — a generous global-per-run ceiling: a pure runaway-loop
  # DoS floor, NOT the harassment bound (that's the per-target cap above —
  # do not conflate the two; this one exists so a broken loop can't spam
  # arbitrarily many distinct targets either).
  @whisper_per_run_ceiling 256
  @whisper_target_counts_key :cp_safe_verb_whisper_target_counts
  @whisper_total_counter :cp_safe_verb_whisper_total

  @doc """
  CX-cj3t.10 — send a private directed message to `target_name` (a
  PLAYER in the invoker's CURRENT ROOM). Returns `:ok`,
  `{:error, :not_here}` (no such player in this room), or
  `{:error, :rate_limited}` (per-target or global-per-run cap hit).

  THREE TRUST PROPERTIES (load-bearing — do not weaken, plan #6050):

    1. SAME-ROOM-ONLY RESOLUTION (also a privacy bound): `target_name`
       is resolved ONLY among players in `f.ctx.current_room_uuid` (via
       `World.list_players_in/2`) — NEVER a global player lookup. This
       means whisper can never be used as a global player-existence
       oracle: an off-room name always comes back `:not_here`, whether
       or not that player exists elsewhere in the world.
    2. SERVER-STAMPED ATTRIBUTION: the delivered event's `who` is the
       INVOKER, taken from `f.ctx[:player_name]` server-side (the SAME
       discipline as `emit_action/3`/`say/2`) — NEVER author-supplied.
       The author passes only `text`.
    3. PER-TARGET PER-RUN RATE CAP: `@whisper_per_target_per_run` (3)
       whispers to any ONE target per run (the harassment bound) WITHOUT
       breaking legitimate one-to-many (whisper each room player once —
       the deal-cards / private-result-per-player pattern). This is a
       DEDICATED counter, deliberately NOT the object-lifecycle N=8
       counter (that would break one-to-many the moment a room has more
       than 8 players — a different concern entirely). A separate,
       generous `@whisper_per_run_ceiling` (256) is a pure runaway-loop
       DoS floor. Both counters live in THIS run's process dict (the
       safe-verb's own `spawn_monitor` child), same pattern as the
       existing `@lifecycle_op_counter`.

  Delivery is `World.tell/2` (the actor-only tell topic, PubSub-only) —
  no doc write, no authority gate, same posture as `emit_action/3`.
  Self-whisper (target resolves to the invoker's own presence) is
  ALLOWED — it's the valid "private result to the actor" pattern.

  NAMED RESIDUAL (plan #6050): unlike public `say`/`emit` (witnessed by
  the room, so socially self-moderating), whisper is a PRIVATE/UNWITNESSED
  channel — there is no bystander to observe abuse. A recipient-side
  IGNORE-LIST is its designed eventual mitigation (the named prerequisite
  for a wider/adversarial tier, same posture as the OS-sandbox horizon —
  not a v1 blocker). For invited-friends, the coherent interim bound is
  exactly the triad above: same-room scoping + server attribution +
  per-target rate. Do not ship whisper to an adversarial tier without the
  ignore-list.
  """
  @spec whisper(t(), String.t(), String.t()) ::
          :ok | {:error, :not_here} | {:error, :rate_limited}
  def whisper(%__MODULE__{} = f, target_name, text)
      when is_binary(target_name) and is_binary(text) do
    f = unwrap(f)

    with {:ok, target_uuid} <- resolve_room_player(f, target_name),
         :ok <- charge_whisper(target_uuid) do
      World.tell(target_uuid, %{kind: :whisper, who: f.ctx[:player_name], text: text})
    end
  end

  # CX-cj3t.10 — property 1: resolve target_name ONLY among players
  # present in the invoker's CURRENT room. `World.list_players_in/2`
  # returns `.usr` presence entries; each entry's `.node_id` IS the
  # target's player_uuid (presence_uuid == player_uuid). Strip the
  # ".usr" suffix from each entry's name and match case-insensitively —
  # prefer an exact match, else the first prefix/substring match. No
  # match -> `:not_here`.
  defp resolve_room_player(f, target_name) do
    needle = String.downcase(target_name)

    players =
      World.list_players_in(f.ctx.current_room_uuid, f.store)
      |> Enum.map(fn entry -> {String.trim_trailing(entry.name, ".usr"), entry.node_id} end)

    match =
      Enum.find(players, fn {name, _uuid} -> String.downcase(name) == needle end) ||
        Enum.find(players, fn {name, _uuid} -> String.contains?(String.downcase(name), needle) end)

    case match do
      {_name, uuid} -> {:ok, uuid}
      nil -> {:error, :not_here}
    end
  end

  # CX-cj3t.10 — property 3: charge the per-target + global-per-run
  # whisper budgets. Fresh per run (process dict of this safe-verb's own
  # spawn_monitor child) — no cross-run leakage, no reset bookkeeping.
  defp charge_whisper(target_uuid) do
    total = Process.get(@whisper_total_counter, 0)
    counts = Process.get(@whisper_target_counts_key, %{})
    target_count = Map.get(counts, target_uuid, 0)

    cond do
      total >= @whisper_per_run_ceiling ->
        {:error, :rate_limited}

      target_count >= @whisper_per_target_per_run ->
        {:error, :rate_limited}

      true ->
        Process.put(@whisper_total_counter, total + 1)
        Process.put(@whisper_target_counts_key, Map.put(counts, target_uuid, target_count + 1))
        :ok
    end
  end

  # --- private ---

  defp write_guarded(f, scope_uuids, fun) do
    if Enum.all?(scope_uuids, &(&1 in f.owner_grant)) do
      fun.()
    else
      {:error, :owner_grant_exceeded}
    end
  end

  # CX-r8vp — THE THIN-HANDLE BACKING (generalizes the P0 signer-material
  # move to the WHOLE facade). A safe verb holds the verb-facing `%Facade{}`
  # and the allowlist permits `inspect/1`, `world.<field>` reads, `Map.get`,
  # destructure, and comprehensions over `world.ctx` — so EVERY capability/
  # identity/store field in the struct's object graph is verb-reachable by
  # the DATA axis, not just the private key the P0 fix scrubbed. So the value
  # the verb receives is a THIN HANDLE (`to_verb_facing/1`): `store`, `ctx`,
  # `object_uuid`, `owner_grant`, and `via_verb` are all nil/empty, leaving
  # only inert `host_kind`. The FULL facade (its `ctx` still carrying
  # `signing_context`/`cert_cids`/`signer_id` — the private key) is installed
  # PROCESS-SIDE (`install_backing/1`, in the Bounds child's process dict,
  # which verb code cannot read — `Process.*`/`self`/`receive` are allowlist-
  # banned) and every method recovers it via `unwrap/1` as its first line.
  # This SUBSUMES the separate signer pdict entry (the signer keys are just
  # part of the backing ctx). Because the thin facade's sensitive fields are
  # nil, a missed unwrap FAILS LOUD (nil store → crash), never leaks.
  #
  # Direct/trusted callers (the dispatcher and the ~270 facade tests) pass the
  # FULL facade with NO pdict installed → `unwrap/1` returns `f` (the OR-`f`
  # fallback, exactly the shape the old `write_opts` signer read used), so
  # they keep working unchanged.
  @facade_backing_key :cp_safe_verb_facade_backing

  # CX-3x5a — the per-run drop accumulator. Every PUBLIC facade method's
  # return flows through `__accumulate__/2` (wired by the `AccumDef` `def`
  # override — see the `use` near the top). Any `{:error, reason}` a verb
  # SILENTLY DROPS (ignores the return and continues) is recorded here and
  # later surfaced to the invoker as a DIM author-diagnostic by
  # `emit_verb_drops/2`. Lives in THIS run's process dict (the safe-verb's
  # own `Bounds` child), same pattern as the lifecycle/whisper counters — no
  # cross-run leakage, dies with the child.
  @facade_errors_key :cp_safe_verb_facade_errors

  # NOTE: `__accumulate__/2` MUST be defined with `Kernel.def`, NOT the
  # `AccumDef` override — wrapping the accumulator through itself would
  # recurse infinitely. `drain_errors/0`/`emit_verb_drops/2` likewise use
  # `Kernel.def` so the accumulator infrastructure never accumulates on
  # itself. (SCOPE N3: only `{:error, _}` records; every other return —
  # `:ok`, `{:ok, _}`, `nil`, `false`, integers, strings, structs — is a pure
  # pass-through, so `get_state(nil)` / `actor_carries?(false)` / `pick([])`
  # do NOT accumulate.)
  @doc false
  Kernel.def __accumulate__(method, result) do
    case result do
      {:error, reason} ->
        Process.put(@facade_errors_key, [{method, reason} | Process.get(@facade_errors_key, [])])

      _ ->
        :ok
    end

    result
  end

  @doc false
  Kernel.def drain_errors do
    errs = Process.get(@facade_errors_key, []) |> Enum.reverse()
    Process.delete(@facade_errors_key)
    errs
  end

  @doc """
  CX-3x5a — drain the run's accumulated facade-method drops and, if any,
  emit ONE dim author-diagnostic to the INVOKER only (never the room).

  `full_facade` is the FULL facade captured in `SafeVerb.run`'s Bounds-child
  closure (it still carries `ctx.player_uuid`) — NOT the thin verb-facing
  handle. N1 precedence: show the FIRST drop (earliest failure = likely root
  cause) with a `(+N more)` suffix if several. Delivered via `World.tell/2`
  (the invoker's own actor-only tell topic) as a `:verb_diagnostic` event —
  a dim, clearly-a-diagnostic line, distinct from gameplay narration (N2:
  a handled error degrades to a tolerable dim note; a truly-silent drop
  becomes VISIBLE to the author).
  """
  Kernel.def emit_verb_drops(%__MODULE__{} = full_facade, _module) do
    case drain_errors() do
      [] ->
        :ok

      drops ->
        {permission_drops, author_drops} =
          Enum.split_with(drops, fn {_method, reason} -> permission_class?(reason) end)

        emit_permission_refusal(full_facade, permission_drops)
        emit_author_diagnostic(full_facade, author_drops)
        :ok
    end
  end

  # CX-gjpi (graceful-refusal) — a PERMISSION-class facade drop is the
  # player lacking STANDING to affect the object (they don't own it, and
  # — until the object-owner-authority elevation lands — a verb write on
  # it is refused), NOT an author bug. Surface it as a plain player-facing
  # refusal (`:notice`, invoker-only gameplay feedback), never the raw
  # `{:trust_rejected, _}` tuple as a dim author-diagnostic. Mirrors the
  # builder verbs' "You don't have permission to …" (verbs.ex). Empty ->
  # no-op.
  #
  # `:owner_grant_exceeded` gets the player-flavor refusal too, but ALSO
  # stays OPERATOR-VISIBLE (plan carve): it means the verb tried to write
  # BEYOND its `owner_grant` reach bound — author overreach or an
  # attack-probe — and the reach bound FIRING must never be silently
  # downgraded to pure flavor (loud-not-silent, the accumulator's own
  # spine).
  defp emit_permission_refusal(_full_facade, []), do: :ok

  defp emit_permission_refusal(full_facade, permission_drops) do
    Enum.each(permission_drops, fn
      {method, :owner_grant_exceeded} ->
        Logger.warning(
          "safe-verb reach bound fired: #{method} → :owner_grant_exceeded " <>
            "(via_verb=#{inspect(full_facade.via_verb)})"
        )

      _ ->
        :ok
    end)

    World.tell(full_facade.ctx.player_uuid, %{
      kind: :notice,
      text: "Nothing happens — it doesn't respond to you."
    })
  end

  # AUTHOR-class drops keep the existing dim `:verb_diagnostic` (N1
  # precedence: FIRST drop = likely root cause, with a `(+N more)` suffix).
  defp emit_author_diagnostic(_full_facade, []), do: :ok

  defp emit_author_diagnostic(full_facade, [{method, reason} | rest]) do
    suffix = if rest == [], do: "", else: " (+#{length(rest)} more)"
    line = "(verb note: #{method} → #{format_drop_reason(reason)}#{suffix})"
    World.tell(full_facade.ctx.player_uuid, %{kind: :verb_diagnostic, text: line})
  end

  defp permission_class?({:trust_rejected, _}), do: true
  defp permission_class?(:owner_grant_exceeded), do: true
  defp permission_class?(_), do: false

  # A bare atom reason renders cleanly (`not_carrying`); a compound reason
  # (`{:trust_rejected, _}`) falls back to `inspect/1`.
  defp format_drop_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_drop_reason(reason), do: inspect(reason)

  @doc false
  def install_backing(%__MODULE__{} = f), do: Process.put(@facade_backing_key, f)

  # The verb-facing THIN handle: only inert display data (host_kind) survives;
  # every capability/identity/store field is nil'd. Still a `%__MODULE__{}` so
  # method dispatch and the allowlist `facade_receiver?` are unchanged.
  @doc false
  def to_verb_facing(%__MODULE__{} = f) do
    %{f | store: nil, ctx: nil, object_uuid: nil, owner_grant: MapSet.new(), via_verb: nil}
  end

  # pdict-OR-`f` fallback. Verb run: the full backing is installed → returns
  # it (the thin `f` is ignored). Direct/test call (no pdict): returns `f`.
  defp unwrap(%__MODULE__{} = f), do: Process.get(@facade_backing_key) || f

  # Callers have all unwrapped `f` (it is the full backing), so read the
  # signer directly from `f.ctx` — no separate signer pdict entry.
  defp write_opts(f) do
    [
      store: f.store,
      signing_context: f.ctx[:signing_context],
      cert_cids: f.ctx[:cert_cids] || [],
      signer_id: f.ctx[:signer_id],
      via_verb: f.via_verb
    ]
  end

  # CX-lfo3 — instance-unique child entry key: the entry is
  # "<name>-<short-uuid>.obj", so N same-named mints never overwrite one
  # entry (the data-loss bug) or collide on move (a raider CAN give a 2nd
  # identical sword). The DISPLAY name stays "<name>" (from meta), and
  # resolution substring-matches "<name>" (World.find_entry_by_name strips
  # the extension then substring-checks the base), so "get grain" still
  # finds each instance one at a time. CRDT-safe: the suffix is derived
  # from the object's own uuid — no cross-replica counter coordination.
  # (Stack-COUNTS for fungibles — "grain x136" under one entry, lifting the
  # M=128 per-container cap — is the deferred layer-2 of CX-lfo3.)
  defp instance_entry_name(name, uuid) do
    short = uuid |> String.replace("-", "") |> String.slice(0, 8)
    "#{name}-#{short}.obj"
  end

  defp add_child_entry(parent_uuid, name, child_uuid, f) do
    {:ok, schema} = Schemas.load_dir_schema(parent_uuid, f.store)
    schema = Schema.add_directory(schema, name, child_uuid)
    commit_schema(parent_uuid, schema, f)
  end

  # CX-cj3t.1.1 — the shared, BOUNDED object creator behind both
  # `create_child` (into the bound object) and `spawn`/`give_to_actor`
  # (into a room / the invoker's inventory). Enforces the per-container
  # cap HERE so every creation path is bounded uniformly. The AUTHORITY
  # check (write_guarded / the invoker-own exception) is the CALLER's
  # responsibility — this helper only creates + links + counts.
  defp create_object_in(f, parent_uuid, name) do
    case Schemas.load_dir_schema(parent_uuid, f.store) do
      {:ok, schema} ->
        if length(Schema.list_entries(schema)) >= @container_max_entries do
          {:error, :container_full}
        else
          obj_json = Schemas.encode_object(%Object{name: name, description: "(no description yet)"})

          with {:ok, new_uuid} <-
                 Schemas.create_dir_with_meta(Schemas.object_filename(), obj_json, f.store, write_opts(f)),
               :ok <- add_child_entry(parent_uuid, instance_entry_name(name, new_uuid), new_uuid, f) do
            # CX-nyj9 — record ONLY here (server-side, from our own return
            # value) so configure_* can later validate an author-passed uuid
            # against the run's minted-set.
            record_minted(new_uuid)
            {:ok, new_uuid}
          end
        end

      {:error, _} = err ->
        err
    end
  end

  # CX-cj3t.1.1 — locate the bound object's parent container the SAME way
  # dispatch resolves a target noun: inventory first, then the current
  # room. Returns `{:ok, parent_uuid, entry_name}` or `:error`. The
  # inventory-first order is load-bearing for `consume`'s authority split
  # (a carried object → invoker-own-container exception).
  defp locate_parent(f, obj_uuid) do
    [f.ctx[:inventory_uuid], f.ctx[:current_room_uuid]]
    |> Enum.reject(&is_nil/1)
    |> Enum.find_value(:error, fn dir ->
      case entry_name(dir, obj_uuid, f.store) do
        {:ok, name} -> {:ok, dir, name}
        :error -> nil
      end
    end)
  end

  # CX-cj3t.1.1 — UNLINK a named entry from a parent schema (drop the
  # entry; the child doc stays in history, GC-reachability handles
  # liveness). `:not_found` if the entry isn't present (fail-visible,
  # never a silent no-op). No authority check here — the CALLER guards.
  defp unlink_child(parent_uuid, entry, f) do
    case Schemas.load_dir_schema(parent_uuid, f.store) do
      {:ok, schema} ->
        case Schema.get_entry(schema, entry) do
          {:ok, _} -> commit_schema(parent_uuid, Schema.remove_entry(schema, entry), f)
          _ -> {:error, :not_found}
        end

      {:error, _} = err ->
        err
    end
  end

  # CX-cj3t.1.1 — chained, invoker-signed commit of a mutated dir schema
  # (shared by add_child_entry / unlink_child).
  defp commit_schema(uuid, schema, f) do
    update = Encoding.encode_update(schema)
    {metadata, commit_opts} = SignedWrite.opts_for(uuid, Keyword.put(write_opts(f), :store, f.store))

    case CommitStoreClient.create_chained_commit(f.store, uuid, update, metadata, commit_opts) do
      {:error, _} = err -> err
      _commit -> :ok
    end
  end

  # CX-cj3t.1.1 — the per-INVOCATION lifecycle-op budget (N=8). The
  # counter lives in the process dictionary of the safe-verb's OWN
  # `spawn_monitor` child (see `Commonplace.MUD.SafeVerb.Bounds`), so it
  # is naturally per-run and discarded when the child dies — no cross-run
  # leakage, no reset bookkeeping. Every object-lifecycle method charges
  # ONE op up front; over budget → `{:error, :spawn_limit}` (fail-visible).
  defp charge_lifecycle_op do
    n = Process.get(@lifecycle_op_counter, 0)

    if n >= @lifecycle_ops_per_run do
      {:error, :spawn_limit}
    else
      Process.put(@lifecycle_op_counter, n + 1)
      :ok
    end
  end

  # CX-nyj9 — record/query the per-run minted-set. record_minted/1 is
  # called ONLY from create_object_in (server-side, our own return value),
  # never from author-reachable code. minted_this_run?/1 is the re-gate
  # configure_* apply to an author-passed uuid (uuid is not a bearer token).
  defp record_minted(uuid) do
    Process.put(@minted_set_key, MapSet.put(Process.get(@minted_set_key, MapSet.new()), uuid))
    uuid
  end

  defp minted_this_run?(uuid) do
    MapSet.member?(Process.get(@minted_set_key, MapSet.new()), uuid)
  end

  defp entry_name(dir_uuid, node_uuid, store) do
    case Schemas.load_dir_schema(dir_uuid, store) do
      {:ok, schema} ->
        case Enum.find(Schema.list_entries(schema), &(&1.node_id == node_uuid)) do
          %Schema.Entry{name: name} -> {:ok, name}
          nil -> :error
        end

      _ ->
        :error
    end
  end

  defp load_any(uuid, store) do
    case World.get_object(uuid, store) do
      {:ok, obj} ->
        {:ok, Map.from_struct(obj)}

      _ ->
        case World.get_room(uuid, store) do
          {:ok, room} ->
            {:ok, Map.from_struct(room)}

          _ ->
            case World.get_player(uuid, store) do
              {:ok, pl} -> {:ok, Map.from_struct(pl)}
              _ -> {:error, :not_found}
            end
        end
    end
  end
end

defimpl Inspect, for: Commonplace.MUD.World.Facade do
  # CX-3x5a — DEFIMPL-LEAK GUARD (verified): the `AccumDef` `def` override is
  # imported only within the `Commonplace.MUD.World.Facade` module body above.
  # This `defimpl` expands to a SIBLING top-level module
  # (`Inspect.Commonplace.MUD.World.Facade`), not lexically nested inside
  # Facade, so it does NOT inherit that import — `def` here is normal
  # `Kernel.def` and `Inspect.inspect/2` is never wrapped through the
  # accumulator. (A blanket `import Kernel, only: [def: 2]` would be WRONG: it
  # narrows Kernel to ONLY `def/2`, dropping `&&`/`||`/`is_map` used below.)

  # CX-<p0-keyleak> — OPAQUE render (defense-in-depth, plan #6107 part 3):
  # never dump the struct's object graph (store handle, ctx, owner_grant) so
  # `inspect(world)` inside a verb discloses no internals even if a field
  # were to regress. The scrub is the load-bearing fix; this neuters the
  # inspect symptom specifically and hides the store handle. Shows only the
  # non-secret player name for debuggability.
  def inspect(facade, _opts) do
    name = (is_map(facade.ctx) && Map.get(facade.ctx, :player_name)) || "?"
    "#MUD.World.Facade<player: #{name}>"
  end
end
