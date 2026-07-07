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
  defstruct store: nil, ctx: nil, object_uuid: nil, owner_grant: MapSet.new(), via_verb: nil

  @type t :: %__MODULE__{
          store: GenServer.server(),
          ctx: map(),
          object_uuid: String.t() | nil,
          owner_grant: MapSet.t(),
          via_verb: term()
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

  # ---- writes (intersection-checked) ----

  @doc """
  Move this facade's bound object (`object_uuid`) from the invoker's
  current room into `dest_dir_uuid`. Grant-checked against
  `{object_uuid, current_room_uuid, dest_dir_uuid}` — all three uuids
  the move touches must be in `owner_grant`.
  """
  @spec move(t(), String.t()) :: :ok | {:error, term()}
  def move(%__MODULE__{object_uuid: nil}, _dest_dir_uuid), do: {:error, :no_bound_object}

  def move(%__MODULE__{} = f, dest_dir_uuid) when is_binary(dest_dir_uuid) do
    write_guarded(f, [f.object_uuid, f.ctx.current_room_uuid, dest_dir_uuid], fn ->
      case entry_name(f.ctx.current_room_uuid, f.object_uuid, f.store) do
        {:ok, name} ->
          Move.move(f.object_uuid, name, f.ctx.current_room_uuid, dest_dir_uuid, write_opts(f))

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
      World.set_meta(f.object_uuid, Schemas.object_filename(), key, value, f.store, write_opts(f))
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
    case World.get_meta_map(f.object_uuid, Schemas.object_filename(), f.store) do
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
      write_guarded(f, [f.object_uuid], fn ->
        state = read_state(f)

        if Map.has_key?(state, key) or map_size(state) < @state_max_keys do
          new_state = Map.put(state, key, value)
          World.set_meta(f.object_uuid, Schemas.object_filename(), "state", new_state, f.store, write_opts(f))
        else
          {:error, :state_bounds}
        end
      end)
    end
  end

  def put_state(%__MODULE__{}, _key, _value), do: {:error, :state_bounds}

  defp read_state(f) do
    case World.get_meta_map(f.object_uuid, Schemas.object_filename(), f.store) do
      {:ok, %{"state" => state}} when is_map(state) -> state
      _ -> %{}
    end
  end

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

  def destroy_child(%__MODULE__{} = f, name) when is_binary(name) do
    with :ok <- charge_lifecycle_op() do
      write_guarded(f, [f.object_uuid], fn ->
        unlink_child(f.object_uuid, "#{name}.obj", f)
      end)
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

  # --- private ---

  defp write_guarded(f, scope_uuids, fun) do
    if Enum.all?(scope_uuids, &(&1 in f.owner_grant)) do
      fun.()
    else
      {:error, :owner_grant_exceeded}
    end
  end

  defp write_opts(f) do
    [
      store: f.store,
      signing_context: Map.get(f.ctx, :signing_context),
      cert_cids: Map.get(f.ctx, :cert_cids, []),
      signer_id: Map.get(f.ctx, :signer_id),
      via_verb: f.via_verb
    ]
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
               :ok <- add_child_entry(parent_uuid, "#{name}.obj", new_uuid, f) do
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
