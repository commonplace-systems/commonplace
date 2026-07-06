defmodule Commonplace.MUD.World.FacadeTest do
  @moduledoc """
  CX-ndvi §2/§6 pins 1-3, 7 — the intersection authority model:
  invoker-signed writes authorized iff (a) `Trust.authorized?(invoker,
  :write, scope)` [the EXISTING local-write gate
  (`Commonplace.Store.CommitStore`'s `local_write_gate_check/2`),
  exercised end-to-end here — the facade doesn't reimplement it, it
  just always signs as the invoker] AND (b) `scope ⊆ owner_grant`
  [checked HERE, in the facade, BEFORE any commit is even attempted].

  Setup mirrors `Commonplace.MUD.SectionOwnershipTest`'s named-store +
  strict-trust + `:enforce`-gate pattern.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Crypto.{Signing, SigningContext}
  alias Commonplace.MUD.Schemas
  alias Commonplace.MUD.World.Facade
  alias Commonplace.Store.CommitStore

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_facade_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    n = :rand.uniform(1_000_000_000)
    store = :"facade_store_#{n}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: dir,
       name: :"facade_sup_#{n}",
       commit_store_name: store,
       trust_side_store_name: :"facade_tss_#{n}",
       pending_imports_name: :"facade_pi_#{n}"}
    )

    old_trust = Application.get_env(:commonplace, :trust)
    old_knob = Application.get_env(:commonplace, :local_write_gate)

    on_exit(fn ->
      case old_trust do
        nil -> Application.delete_env(:commonplace, :trust)
        v -> Application.put_env(:commonplace, :trust, v)
      end

      case old_knob do
        nil -> Application.delete_env(:commonplace, :local_write_gate)
        v -> Application.put_env(:commonplace, :local_write_gate, v)
      end

      File.rm_rf!(dir)
    end)

    {trusted_pub, trusted_priv} = Signing.generate_keypair()
    trusted_identity = "invA-#{:rand.uniform(999_999_999_999)}"

    trusted_ctx = %SigningContext{
      identity_uuid: trusted_identity,
      private_key: trusted_priv,
      public_key: trusted_pub
    }

    Application.put_env(:commonplace, :trust, %{
      accept_unsigned: false,
      trusted_identities: %{trusted_identity => Signing.encode_key(trusted_pub)}
    })

    Application.put_env(:commonplace, :local_write_gate, :enforce)

    {:ok, obj_uuid} =
      Schemas.create_dir_with_meta(
        Schemas.object_filename(),
        Schemas.encode_object(%Schemas.Object{name: "widget", description: "a thing"}),
        store,
        signing_context: trusted_ctx
      )

    {uncapped_pub, uncapped_priv} = Signing.generate_keypair()
    uncapped_identity = "invB-#{:rand.uniform(999_999_999_999)}"

    uncapped_ctx = %SigningContext{
      identity_uuid: uncapped_identity,
      private_key: uncapped_priv,
      public_key: uncapped_pub
    }

    %{store: store, obj_uuid: obj_uuid, trusted_ctx: trusted_ctx, uncapped_ctx: uncapped_ctx}
  end

  test "pin 1: invoker write-authorized + owner-grant covers → lands, signed by invoker, via_verb present", %{
    store: store,
    obj_uuid: obj_uuid,
    trusted_ctx: trusted_ctx
  } do
    facade =
      Facade.new(
        %{signing_context: trusted_ctx, cert_cids: [], signer_id: nil},
        obj_uuid,
        [obj_uuid],
        {"verbs/poke.safe.elx", "owner-x"},
        store
      )

    assert :ok = Facade.set_attr(facade, "note", "poked")

    # `set_attr` writes the object's __object.json META FILE (a child
    # doc of the object directory), not the directory schema doc itself
    # — resolve that child uuid to check the actual write.
    meta_uuid = meta_file_uuid(store, obj_uuid)
    assert {:ok, head} = CommitStore.latest_commit(store, meta_uuid)
    assert head.signer_id == Signing.signer_id(trusted_ctx.identity_uuid, trusted_ctx.public_key)
    assert head.metadata[:via_verb] == {"verbs/poke.safe.elx", "owner-x"}
  end

  defp meta_file_uuid(store, obj_uuid) do
    {:ok, schema} = Schemas.load_dir_schema(obj_uuid, store)
    {:ok, entry} = Commonplace.Tree.Schema.get_entry(schema, Schemas.object_filename())
    entry.node_id
  end

  test "pin 2: intersection denial — invoker without :write on the target is DENIED (confused-deputy/setuid case)", %{
    store: store,
    obj_uuid: obj_uuid,
    uncapped_ctx: uncapped_ctx
  } do
    facade =
      Facade.new(
        %{signing_context: uncapped_ctx, cert_cids: [], signer_id: nil},
        obj_uuid,
        [obj_uuid],
        {"verbs/poke.safe.elx", "owner-x"},
        store
      )

    assert {:error, {:trust_rejected, {:untrusted_signer, _}}} = Facade.set_attr(facade, "note", "poked")

    # Nothing landed — the meta file's head is still the setup write,
    # no via_verb tag anywhere.
    meta_uuid = meta_file_uuid(store, obj_uuid)
    assert {:ok, head} = CommitStore.latest_commit(store, meta_uuid)
    refute head.metadata[:via_verb]
  end

  test "pin 3: owner-grant narrowing — invoker COULD write directly, but the verb's grant doesn't cover this target", %{
    store: store,
    obj_uuid: obj_uuid,
    trusted_ctx: trusted_ctx
  } do
    other_uuid = UUID.uuid4()

    facade =
      Facade.new(
        %{signing_context: trusted_ctx, cert_cids: [], signer_id: nil},
        obj_uuid,
        # Grant covers a DIFFERENT uuid, not obj_uuid — monotone
        # narrowing: even though trusted_ctx is a pinned root that could
        # write obj_uuid directly, the FACADE denies before attempting
        # any commit, because the owner never attached obj_uuid to this
        # verb's grant.
        [other_uuid],
        {"verbs/poke.safe.elx", "owner-x"},
        store
      )

    assert {:error, :owner_grant_exceeded} = Facade.set_attr(facade, "note", "poked")
  end

  test "pin 7: no effect surface leak — the facade is the only capability-bearing value; it exposes no raw store accessor" do
    facade = Facade.new(%{}, "obj", [], nil, :some_store)

    assert %Facade{} = facade
    # The struct's public fields are data (store handle, ctx, grant,
    # audit tag) needed for the facade's OWN internal ops — but nothing
    # in this module's public API returns a bare `CommitStoreClient`/
    # store reference to the CALLER; every public function is one of
    # the nine locked read/write/broadcast methods. See
    # `Commonplace.MUD.SafeVerbTest` "no_leaked_bindings" for the
    # complementary compile-time proof that a safe-verb BODY has no
    # `store`/`ctx` variable in scope at all — only `world` (this
    # facade value) and `args`.
    refute function_exported?(Facade, :store, 1)
    refute function_exported?(Facade, :raw_store, 1)
  end
end
