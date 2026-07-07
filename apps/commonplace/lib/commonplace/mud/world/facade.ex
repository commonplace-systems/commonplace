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
    case load_any(target_uuid, f.store) do
      {:ok, %{name: name, description: description}} -> {:ok, "#{name}\n#{description}"}
      {:error, _} = err -> err
    end
  end

  @doc "Raw attribute map (room/object/player metadata) for any target uuid."
  @spec get_attr(t(), String.t()) :: {:ok, map()} | {:error, term()}
  def get_attr(%__MODULE__{} = f, target_uuid) when is_binary(target_uuid) do
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
  def move_object(%__MODULE__{object_uuid: nil}, _dest_room_uuid), do: {:error, :no_bound_object}
  # CX-v6j4 (plan #6135) — OBJECT-host only: a room is not a movable object.
  def move_object(%__MODULE__{host_kind: :room}, _dest_room_uuid), do: {:error, :requires_object_host}

  def move_object(%__MODULE__{} = f, dest_room_uuid) when is_binary(dest_room_uuid) do
    write_guarded(f, [f.object_uuid, f.ctx.current_room_uuid, dest_room_uuid], fn ->
      case entry_name(f.ctx.current_room_uuid, f.object_uuid, f.store) do
        {:ok, name} ->
          Move.move(f.object_uuid, name, f.ctx.current_room_uuid, dest_room_uuid, write_opts(f))

        :error ->
          {:error, :not_found}
      end
    end)
  end

  @doc """
  Set a metadata attribute (`key`/`value`) on this facade's bound
  object. Grant-checked against `{object_uuid}`.
  """
  @spec set_attr(t(), String.t(), term()) :: :ok | {:error, term()}
  def set_attr(%__MODULE__{object_uuid: nil}, _key, _value), do: {:error, :no_bound_object}

  def set_attr(%__MODULE__{} = f, key, value) when is_binary(key) do
    write_guarded(f, [f.object_uuid], fn ->
      World.set_meta(f.object_uuid, meta_filename(f), key, value, f.store, write_opts(f))
    end)
  end

  # CX-hqk5 — freeform per-object state bounds (plan #5968). State lives in
  # __object.json which is a CRDT doc that SYNCS, so bloat = sync/storage
  # cost across every replica — bound it (size only; write-frequency is
  # bounded by the session rate-limit + exec bounds, not here).
  @state_key_max_bytes 64
  @state_value_max_bytes 1024
  @state_max_keys 64

  @doc """
  CX-hqk5 — read freeform per-object state written by `put_state/3`.
  Reads the BOUND object's own `meta["state"][key]`; returns the value or
  `nil` (missing key / object). Read-only, bound-object only: there is no
  target-uuid param, so a verb can only read its OWN object's state — NOT
  another object's (cross-object read is a separate, bigger capability by
  design, not smuggled in here).
  """
  @spec get_state(t(), String.t()) :: term()
  def get_state(%__MODULE__{object_uuid: nil}, _key), do: nil

  def get_state(%__MODULE__{} = f, key) when is_binary(key) do
    case World.get_meta_map(f.object_uuid, meta_filename(f), f.store) do
      {:ok, %{"state" => state}} when is_map(state) -> Map.get(state, key)
      _ -> nil
    end
  end

  def get_state(%__MODULE__{}, _key), do: nil

  @doc """
  CX-hqk5 — write freeform per-object state. Owner-scoped (`write_guarded`
  on the bound object, the SAME intersection as `set_attr`) into a
  DEDICATED `meta["state"]` submap, so it can NEVER clobber typed fields
  (name/fixed/container). Bounds (plan #5968): key ≤ 64 bytes; value a
  JSON SCALAR only — string (≤ 1024 bytes) / number / boolean / nil, NOT
  a list or map; ≤ 64 keys per object. Over-limit → `{:error,
  :state_bounds}` (fail-visible, never truncates). One verb `put_state`s,
  another (or a later run) `get_state`s — the whole stateful-mechanic
  class (lit/unlit, unlocked, score, already-solved).
  """
  @spec put_state(t(), String.t(), term()) :: :ok | {:error, term()}
  def put_state(%__MODULE__{object_uuid: nil}, _key, _value), do: {:error, :no_bound_object}

  def put_state(%__MODULE__{} = f, key, value) when is_binary(key) do
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

  defp validate_state_value(v) when is_boolean(v) or is_nil(v) or is_number(v), do: :ok

  defp validate_state_value(v) when is_binary(v) do
    if byte_size(v) <= @state_value_max_bytes, do: :ok, else: {:error, :state_bounds}
  end

  # Reject list/map/tuple/other — JSON scalars only.
  defp validate_state_value(_), do: {:error, :state_bounds}

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

  @doc """
  Create a new child object named `name` under this facade's bound
  object. Grant-checked against `{object_uuid}` (the parent). Returns
  `{:ok, new_uuid}` on success.
  """
  @spec create_child(t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def create_child(%__MODULE__{object_uuid: nil}, _name), do: {:error, :no_bound_object}

  def create_child(%__MODULE__{} = f, name) when is_binary(name) do
    # CX-cj3t.1.1 — now shares the capped/charged creator with `spawn`, so
    # create_child is subject to the SAME per-container (M=128) and
    # per-invocation (N=8) bounds (it was previously uncapped — a latent
    # object-spam DoS). Authority is unchanged: strict intersection on the
    # bound object.
    with :ok <- charge_lifecycle_op() do
      write_guarded(f, [f.object_uuid], fn -> create_object_in(f, f.object_uuid, name) end)
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
  def consume(%__MODULE__{object_uuid: nil}), do: {:error, :no_bound_object}
  # CX-v6j4 (plan #6135) — OBJECT-host only: a room's children are shared/
  # mixed-ownership, and consume/destroy_child guard only the parent, so
  # they must not fire on room hosts (cross-owner setuid).
  def consume(%__MODULE__{host_kind: :room}), do: {:error, :requires_object_host}

  def consume(%__MODULE__{} = f) do
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

  @doc """
  Destroy (UNLINK) a named child object of the invoker's BOUND object.
  STRICT INTERSECTION on the bound object (`write_guarded` + invoker-
  signed) — symmetric with `create_child/2`, which the child lives under.
  Bounded (per-invocation cap).
  """
  @spec destroy_child(t(), String.t()) :: :ok | {:error, term()}
  def destroy_child(%__MODULE__{object_uuid: nil}, _name), do: {:error, :no_bound_object}
  # CX-v6j4 (plan #6135) — OBJECT-host only (see consume).
  def destroy_child(%__MODULE__{host_kind: :room}, _name), do: {:error, :requires_object_host}

  def destroy_child(%__MODULE__{} = f, name) when is_binary(name) do
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
    if minted_this_run?(minted_uuid) do
      World.set_meta(minted_uuid, Schemas.object_filename(), key, value, f.store, write_opts(f))
    else
      {:error, :not_minted_here}
    end
  end

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

  # ---- broadcasts (no doc write — no intersection check) ----

  @doc "Say `text` aloud in the invoker's current room."
  @spec say(t(), String.t()) :: :ok
  def say(%__MODULE__{} = f, text) when is_binary(text) do
    World.broadcast_room(f.ctx.current_room_uuid, %{kind: :say, who: f.ctx[:player_name], text: text})
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

  # CX-<p0-keyleak> — SIGNING MATERIAL IS NOT VERB-REACHABLE. A safe verb
  # holds the `%Facade{}` and the allowlist permits `inspect/1` and
  # `world.<field>` reads, so ANY secret in the struct's object graph leaks
  # (`world.ctx.signing_context.private_key` by direct field access;
  # `inspect(world)` renders it). So the SIGNING MATERIAL
  # (`signing_context`/`cert_cids`/`signer_id` — the private key) is
  # SCRUBBED from the ctx the verb sees (`scrub_signer/1`, applied in
  # `Commonplace.MUD.SafeVerb.run/3` BEFORE the verb is handed the facade)
  # and stashed in the invocation process's dict (`install_signer/1`), which
  # verb code cannot read (`Process.*`/`self`/`receive` are allowlist-banned).
  # `write_opts/1` (module code, not verb code) reads it back from the dict,
  # falling back to `f.ctx` for TRUSTED direct callers (dispatcher/tests)
  # that never expose the facade to author code. Data-reachability axis, not
  # execution — see the standing review note.
  @signer_keys [:signing_context, :cert_cids, :signer_id]
  @signer_pdict_key :cp_safe_verb_signer

  @doc false
  def signer_material(%__MODULE__{ctx: ctx}) do
    %{
      signing_context: Map.get(ctx, :signing_context),
      cert_cids: Map.get(ctx, :cert_cids, []),
      signer_id: Map.get(ctx, :signer_id)
    }
  end

  @doc false
  def scrub_signer(%__MODULE__{ctx: ctx} = f), do: %{f | ctx: Map.drop(ctx, @signer_keys)}

  @doc false
  def install_signer(material), do: Process.put(@signer_pdict_key, material)

  defp write_opts(f) do
    m = Process.get(@signer_pdict_key) || signer_material(f)

    [
      store: f.store,
      signing_context: m.signing_context,
      cert_cids: m.cert_cids || [],
      signer_id: m.signer_id,
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
