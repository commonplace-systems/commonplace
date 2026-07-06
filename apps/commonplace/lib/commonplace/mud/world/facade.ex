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

  @doc """
  Create a new child object named `name` under this facade's bound
  object. Grant-checked against `{object_uuid}` (the parent). Returns
  `{:ok, new_uuid}` on success.
  """
  @spec create_child(t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def create_child(%__MODULE__{object_uuid: nil}, _name), do: {:error, :no_bound_object}

  def create_child(%__MODULE__{} = f, name) when is_binary(name) do
    write_guarded(f, [f.object_uuid], fn ->
      obj_json = Schemas.encode_object(%Object{name: name, description: "(no description yet)"})

      with {:ok, new_uuid} <- Schemas.create_dir_with_meta(Schemas.object_filename(), obj_json, f.store, write_opts(f)),
           :ok <- add_child_entry(f.object_uuid, "#{name}.obj", new_uuid, f) do
        {:ok, new_uuid}
      end
    end)
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

  # ---- broadcasts (no doc write — no intersection check) ----

  @doc "Say `text` aloud in the invoker's current room."
  @spec say(t(), String.t()) :: :ok
  def say(%__MODULE__{} = f, text) when is_binary(text) do
    World.broadcast_room(f.ctx.current_room_uuid, %{kind: :say, who: f.ctx[:player_name], text: text})
  end

  @doc "Broadcast a custom event (text or event map) to the invoker's current room."
  @spec emit(t(), String.t() | map()) :: :ok
  def emit(%__MODULE__{} = f, event) do
    World.broadcast_room(f.ctx.current_room_uuid, event)
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
    update = Encoding.encode_update(schema)
    {metadata, commit_opts} = SignedWrite.opts_for(parent_uuid, Keyword.put(write_opts(f), :store, f.store))

    case CommitStoreClient.create_chained_commit(f.store, parent_uuid, update, metadata, commit_opts) do
      {:error, _} = err -> err
      _commit -> :ok
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
