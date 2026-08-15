defmodule Commonplace.Trust.SubtreeDelegationTest do
  use ExUnit.Case, async: false

  alias Commonplace.Crypto.{Signing, SigningContext}
  alias Commonplace.MUD.{Schemas, World}
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Trust
  alias Commonplace.Trust.{Capability, VerifyChain}

  setup do
    root_ctx = signing_context()
    dir = Path.join(System.tmp_dir!(), "cp_subtree_delegation_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    n = :rand.uniform(1_000_000_000)
    store = :"subtree_delegation_store_#{n}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: dir,
       name: :"subtree_delegation_sup_#{n}",
       commit_store_name: store,
       trust_side_store_name: :"subtree_delegation_tss_#{n}",
       pending_imports_name: :"subtree_delegation_pi_#{n}"}
    )

    old = %{
      data_dir: Application.get_env(:commonplace, :data_dir),
      trust: Application.get_env(:commonplace, :trust),
      gate: Application.get_env(:commonplace, :local_write_gate)
    }

    Application.put_env(:commonplace, :data_dir, dir)
    Application.put_env(:commonplace, :trust, trust_config(root_ctx))
    Application.put_env(:commonplace, :local_write_gate, :enforce)

    on_exit(fn ->
      for {key, value} <- old do
        app_key = %{data_dir: :data_dir, trust: :trust, gate: :local_write_gate}[key]

        if is_nil(value),
          do: Application.delete_env(:commonplace, app_key),
          else: Application.put_env(:commonplace, app_key, value)
      end

      File.rm_rf!(dir)
    end)

    {:ok, room} =
      Schemas.create_dir_with_meta(
        Schemas.room_filename(),
        Schemas.encode_room(%Schemas.Room{name: "Room", description: "delegation target"}),
        store,
        signing_context: root_ctx
      )

    %{store: store, root_ctx: root_ctx, room: room}
  end

  test "same-root subtree delegation: six acceptance arms stay distinct", %{
    store: store,
    root_ctx: root_ctx,
    room: room
  } do
    root = UUID.uuid4()

    :ok =
      World.set_meta(room, Schemas.room_filename(), "zone", root, store,
        signing_context: root_ctx
      )

    delegator_ctx = signing_context()
    leaf_ctx = signing_context()
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    parent_not_before = DateTime.add(now, -600, :second)
    parent_not_after = DateTime.add(now, 3_600, :second)
    child_not_before = DateTime.add(now, -300, :second)
    child_not_after = DateTime.add(now, 1_800, :second)

    parent_claim = %{
      verbs: [:read, :write, :delegate],
      scope: {:subtree, root},
      caveats: %{not_before: parent_not_before, not_after: parent_not_after}
    }

    {:ok, parent} =
      Capability.issue(
        root_ctx,
        {delegator_ctx.identity_uuid, delegator_ctx.public_key},
        parent_claim,
        nil,
        store: store
      )

    :ok = CommitStoreClient.store_capability(store, parent)

    child_claim = %{
      verbs: [:write],
      scope: {:subtree, root},
      caveats: %{not_before: child_not_before, not_after: child_not_after}
    }

    same_root_mint =
      Capability.issue(
        delegator_ctx,
        {leaf_ctx.identity_uuid, leaf_ctx.public_key},
        child_claim,
        parent.id,
        parent: parent
      )

    assert {:ok, child} = same_root_mint
    :ok = CommitStoreClient.store_capability(store, child)

    same_root_verify =
      VerifyChain.verify_chain(child.id, MapSet.new([root_ctx.public_key]), store)

    assert {:ok,
            %{
              verbs: [:write],
              scope: {:subtree, ^root},
              caveats: %{not_before: ^child_not_before, not_after: ^child_not_after}
            }} = same_root_verify

    {:ok, target} = World.meta_doc_uuid(room, Schemas.room_filename(), store)

    same_root_authorizes =
      Trust.writer_authorized?(
        leaf_ctx.identity_uuid,
        leaf_ctx.public_key,
        [child.id],
        target,
        trust_config(root_ctx),
        store
      )

    assert same_root_authorizes

    foreign_root_mint =
      Capability.issue(
        delegator_ctx,
        {leaf_ctx.identity_uuid, leaf_ctx.public_key},
        %{child_claim | scope: {:subtree, UUID.uuid4()}},
        parent.id,
        parent: parent
      )

    assert {:error, :subtree_scope_root_mismatch} = foreign_root_mint

    widening_mint =
      Capability.issue(
        delegator_ctx,
        {leaf_ctx.identity_uuid, leaf_ctx.public_key},
        %{child_claim | verbs: [:write, :execute]},
        parent.id,
        parent: parent
      )

    assert {:error, {:not_attenuation, :child_exceeds_parent}} = widening_mint

    looser_window_mint =
      Capability.issue(
        delegator_ctx,
        {leaf_ctx.identity_uuid, leaf_ctx.public_key},
        %{
          child_claim
          | caveats: %{
              not_before: child_not_before,
              not_after: DateTime.add(parent_not_after, 1, :second)
            }
        },
        parent.id,
        parent: parent
      )

    assert {:error, {:not_attenuation, :child_exceeds_parent}} = looser_window_mint

    no_delegate_ctx = signing_context()
    no_delegate_leaf_ctx = signing_context()

    {:ok, no_delegate_parent} =
      Capability.issue(
        root_ctx,
        {no_delegate_ctx.identity_uuid, no_delegate_ctx.public_key},
        %{parent_claim | verbs: [:write]},
        nil,
        store: store
      )

    :ok = CommitStoreClient.store_capability(store, no_delegate_parent)

    no_delegate_mint =
      Capability.issue(
        no_delegate_ctx,
        {no_delegate_leaf_ctx.identity_uuid, no_delegate_leaf_ctx.public_key},
        child_claim,
        no_delegate_parent.id,
        parent: no_delegate_parent
      )

    assert {:ok, no_delegate_child} = no_delegate_mint
    :ok = CommitStoreClient.store_capability(store, no_delegate_child)

    no_delegate_verify =
      VerifyChain.verify_chain(no_delegate_child.id, MapSet.new([root_ctx.public_key]), store)

    assert {:error, :delegation_not_permitted} = no_delegate_verify

    mixed_scope_guarded_mint =
      Capability.issue(
        delegator_ctx,
        {leaf_ctx.identity_uuid, leaf_ctx.public_key},
        %{child_claim | scope: {:presence, leaf_ctx.identity_uuid}},
        parent.id,
        parent: parent
      )

    assert {:error, :subtree_scope_not_delegable} = mixed_scope_guarded_mint

    mixed_scope_bypass_mint =
      Capability.issue(
        delegator_ctx,
        {leaf_ctx.identity_uuid, leaf_ctx.public_key},
        %{child_claim | scope: {:presence, leaf_ctx.identity_uuid}},
        parent.id
      )

    assert {:ok, mixed_scope_child} = mixed_scope_bypass_mint
    :ok = CommitStoreClient.store_capability(store, mixed_scope_child)

    mixed_scope_verify =
      VerifyChain.verify_chain(mixed_scope_child.id, MapSet.new([root_ctx.public_key]), store)

    assert {:error, :mixed_scope_type_chain} = mixed_scope_verify

    arms = [
      {1, "same-root narrowed child",
       %{mint: :ok, verify: same_root_verify, authorizes: same_root_authorizes}},
      {2, "foreign-root child", foreign_root_mint},
      {3, "verb-widening child", widening_mint},
      {4, "looser-window child", looser_window_mint},
      {5, "parent lacking :delegate", %{mint: :ok, verify: no_delegate_verify}},
      {6, "mixed scope chain",
       %{
         guarded_mint: mixed_scope_guarded_mint,
         bypass_mint: :ok,
         verify: mixed_scope_verify
       }}
    ]

    Enum.each(arms, fn {number, label, outcome} ->
      IO.puts("D1 ARM #{number} — #{label}: #{inspect(outcome)}")
    end)

    pairs = [
      {"same-root mint / foreign-root mint", :ok, foreign_root_mint},
      {"same-root mint / verb-widening mint", :ok, widening_mint},
      {"same-root mint / looser-window mint", :ok, looser_window_mint},
      {"same-root verify / missing-delegate verify", same_root_verify, no_delegate_verify},
      {"same-root verify / mixed-scope verify", same_root_verify, mixed_scope_verify}
    ]

    Enum.each(pairs, fn {label, accepted, refused} ->
      IO.puts("D1 PAIR — #{label}: #{inspect(accepted)} != #{inspect(refused)}")
      refute accepted == refused
    end)
  end

  defp signing_context do
    {pub, priv} = Signing.generate_keypair()

    %SigningContext{
      identity_uuid: UUID.uuid4(),
      public_key: pub,
      private_key: priv
    }
  end

  defp trust_config(root_ctx) do
    %{
      accept_unsigned: false,
      trusted_identities: %{
        root_ctx.identity_uuid => Signing.encode_key(root_ctx.public_key)
      }
    }
  end
end
