defmodule CommonplaceWebWeb.SessionIdentityTest do
  @moduledoc """
  CX-qat5.2 §2.3: the session → `{SigningContext, hand}` resolution
  seam. Acceptance pin 4 (hand stability + cross-session distinctness +
  the 53-bit ceiling) lives here.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Invites
  alias Commonplace.Store.{CommitStore, SecretStore}
  alias Commonplace.Tree.Schema
  alias CommonplaceWebWeb.SessionIdentity

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_session_identity_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    Application.put_env(:commonplace, :data_dir, dir)

    sup = Commonplace.Store.CommitStoreSupervisor
    _ = Supervisor.terminate_child(sup, CommitStore)
    _ = Supervisor.delete_child(sup, CommitStore)
    {:ok, _pid} = Supervisor.start_child(sup, {CommitStore, data_dir: dir})

    root_uuid = UUID.uuid4()
    root_doc = Schema.new_schema()
    update = Yelixer.Encoding.encode_update(root_doc)
    CommitStore.create_commit(CommitStore, root_uuid, update, nil)
    File.write!(Path.join(dir, "root"), root_uuid)

    on_exit(fn ->
      _ = Supervisor.terminate_child(sup, CommitStore)
      _ = Supervisor.delete_child(sup, CommitStore)
      Application.put_env(:commonplace, :data_dir, "tmp/test_data")
      {:ok, _pid} = Supervisor.start_child(sup, {CommitStore, data_dir: "tmp/test_data"})
      File.rm_rf!(dir)
    end)

    %{root: root_uuid}
  end

  defp mint_and_redeem(root) do
    {:ok, %{token: token}} = Invites.mint("resolvetest-#{:rand.uniform(1_000_000)}", root)
    {:ok, identity_uuid} = Invites.redeem(token, SecretStore)
    identity_uuid
  end

  test "resolves a valid session to {:ok, resolved} with matching identity_uuid", %{root: root} do
    identity_uuid = mint_and_redeem(root)
    nonce = Base.encode64(:crypto.strong_rand_bytes(16))

    session = %{"player_identity_uuid" => identity_uuid, "session_nonce" => nonce}

    assert {:ok, resolved} = SessionIdentity.resolve(session)
    assert resolved.identity_uuid == identity_uuid
    assert String.ends_with?(resolved.presence_path, ".usr")
    assert is_binary(resolved.signer_id)
    assert resolved.hand < 0x20_0000_0000_0000
  end

  test "pin 4: the SAME session (same nonce) resolves the SAME hand across two calls", %{
    root: root
  } do
    identity_uuid = mint_and_redeem(root)
    nonce = Base.encode64(:crypto.strong_rand_bytes(16))
    session = %{"player_identity_uuid" => identity_uuid, "session_nonce" => nonce}

    {:ok, first} = SessionIdentity.resolve(session)
    {:ok, second} = SessionIdentity.resolve(session)

    assert first.hand == second.hand
  end

  test "pin 4: two sessions of the SAME player (two nonces) get DIFFERENT hands", %{root: root} do
    identity_uuid = mint_and_redeem(root)

    session_a = %{
      "player_identity_uuid" => identity_uuid,
      "session_nonce" => Base.encode64(:crypto.strong_rand_bytes(16))
    }

    session_b = %{
      "player_identity_uuid" => identity_uuid,
      "session_nonce" => Base.encode64(:crypto.strong_rand_bytes(16))
    }

    {:ok, resolved_a} = SessionIdentity.resolve(session_a)
    {:ok, resolved_b} = SessionIdentity.resolve(session_b)

    refute resolved_a.hand == resolved_b.hand
  end

  test "pin 4: hand < 2^53 (the JS-safe-integer ceiling)", %{root: root} do
    identity_uuid = mint_and_redeem(root)

    session = %{
      "player_identity_uuid" => identity_uuid,
      "session_nonce" => Base.encode64(:crypto.strong_rand_bytes(16))
    }

    {:ok, resolved} = SessionIdentity.resolve(session)
    assert resolved.hand < 0x20_0000_0000_0000
  end

  test "no session cookie at all resolves to :anonymous" do
    assert :anonymous = SessionIdentity.resolve(%{})
  end

  test "an identity_uuid with no minted key (SecretStore wiped) resolves to :anonymous, never crashes" do
    session = %{
      "player_identity_uuid" => UUID.uuid4(),
      "session_nonce" => Base.encode64(:crypto.strong_rand_bytes(16))
    }

    assert :anonymous = SessionIdentity.resolve(session)
  end
end
