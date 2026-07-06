defmodule Commonplace.InvitesTest do
  @moduledoc """
  CX-qat5.2 §2.1: invite minting + redemption — acceptance pin 3
  (`docs/plans/2026-07-06-qat5.2-browser-identity-spec.md` §2.5).

  Covers: mint registers a `:usr` player + hashes the token at rest;
  redeem is single-use (second redeem of the same token → `:invalid`);
  an expired token → `:expired`; the raw token is NEVER found verbatim
  in SecretStore (only its SHA-256 hash, under the `"invite:" <> hash`
  slot).
  """
  use ExUnit.Case, async: false

  alias Commonplace.Invites
  alias Commonplace.Presence.Identity
  alias Commonplace.Store.{CommitStore, SecretStore}
  alias Commonplace.Tree.Schema

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_invites_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    store = :"invites_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store})

    secrets_dir =
      Path.join(System.tmp_dir!(), "cp_invites_secrets_#{:rand.uniform(1_000_000_000)}")

    File.mkdir_p!(secrets_dir)
    secrets = :"invites_secrets_#{:rand.uniform(1_000_000)}"
    start_supervised!({SecretStore, data_dir: secrets_dir, name: secrets})

    on_exit(fn ->
      File.rm_rf!(dir)
      File.rm_rf!(secrets_dir)
    end)

    root_uuid = UUID.uuid4()
    root_doc = Schema.new_schema()
    update = Yelixer.Encoding.encode_update(root_doc)
    CommitStore.create_commit(store, root_uuid, update, nil)

    %{store: store, root: root_uuid, secrets: secrets}
  end

  test "mint/4 registers a :usr player and returns {identity_uuid, token, expires_at}", %{
    store: store,
    root: root,
    secrets: secrets
  } do
    assert {:ok, %{identity_uuid: uuid, token: token, expires_at: %DateTime{}}} =
             Invites.mint("alice", root, store, secret_store: secrets)

    assert is_binary(uuid)
    assert is_binary(token)
    assert {:ok, ^uuid} = Identity.lookup("alice", :usr, root, store)
  end

  test "the raw token is never stored — only its SHA-256 hash slot exists", %{
    store: store,
    root: root,
    secrets: secrets
  } do
    {:ok, %{token: token}} = Invites.mint("bob", root, store, secret_store: secrets)

    names = SecretStore.list(secrets)
    refute token in names

    expected_slot = "invite:" <> Base.encode64(:crypto.hash(:sha256, token))
    assert expected_slot in names

    # And the raw token doesn't appear as a *value* anywhere in the
    # store either.
    refute Enum.any?(names, fn name ->
             case SecretStore.get(secrets, name) do
               {:ok, value} -> value == token or String.contains?(value, token)
               :not_found -> false
             end
           end)
  end

  test "redeem/2 resolves the token to the identity_uuid", %{
    store: store,
    root: root,
    secrets: secrets
  } do
    {:ok, %{identity_uuid: uuid, token: token}} =
      Invites.mint("carol", root, store, secret_store: secrets)

    assert {:ok, ^uuid} = Invites.redeem(token, secrets)
  end

  test "redeem/2 is single-use: a second redemption of the same token fails :invalid", %{
    store: store,
    root: root,
    secrets: secrets
  } do
    {:ok, %{token: token}} = Invites.mint("dave", root, store, secret_store: secrets)

    assert {:ok, _uuid} = Invites.redeem(token, secrets)
    assert {:error, :invalid} = Invites.redeem(token, secrets)
  end

  test "redeem/2 rejects an unknown token as :invalid", %{secrets: secrets} do
    assert {:error, :invalid} = Invites.redeem("not-a-real-token", secrets)
  end

  test "redeem/2 rejects an expired token as :expired, then :invalid on a second attempt", %{
    store: store,
    root: root,
    secrets: secrets
  } do
    {:ok, %{token: token}} =
      Invites.mint("erin", root, store, secret_store: secrets, ttl_seconds: -1)

    assert {:error, :expired} = Invites.redeem(token, secrets)
    # Expired tokens are deleted on contact — a second attempt sees the
    # slot already gone, same as any other unknown token.
    assert {:error, :invalid} = Invites.redeem(token, secrets)
  end

  test "minting twice for the same player name yields two independent, both-redeemable tokens",
       %{store: store, root: root, secrets: secrets} do
    {:ok, %{identity_uuid: uuid1, token: token1}} =
      Invites.mint("frank", root, store, secret_store: secrets)

    {:ok, %{identity_uuid: uuid2, token: token2}} =
      Invites.mint("frank", root, store, secret_store: secrets)

    # Same player identity both times (register_player is idempotent).
    assert uuid1 == uuid2
    refute token1 == token2

    assert {:ok, ^uuid1} = Invites.redeem(token1, secrets)
    assert {:ok, ^uuid2} = Invites.redeem(token2, secrets)
  end
end
