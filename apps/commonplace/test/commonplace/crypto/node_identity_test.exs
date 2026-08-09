defmodule Commonplace.Crypto.NodeIdentityTest do
  @moduledoc """
  CX-tdkq.24 (phase 2.5): the workspace's node signing identity. System-
  minted commits (snapshots, merges) have no user signer; signing them
  with a stable, locally-anchored NODE identity gives them an accountable
  signer so strict mode (accept_unsigned: false) accepts them.

  The keypair is minted on first use under the workspace data_dir
  (never synced, like node_id and the SecretStore), and the identity is
  the workspace node_id — so the node's commits trace to the node.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Crypto.{NodeIdentity, Signing, SigningContext}

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_node_id_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    old = Application.get_env(:commonplace, :data_dir)
    Application.put_env(:commonplace, :data_dir, dir)

    on_exit(fn ->
      Application.put_env(:commonplace, :data_dir, old || "tmp/test_data")

      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  test "signing_context/0 returns a SigningContext rooted at the node_id" do
    assert {:ok, %SigningContext{} = ctx} = NodeIdentity.signing_context()
    {:ok, node_id} = Commonplace.Workspace.node_id()
    assert ctx.identity_uuid == node_id
    assert is_binary(ctx.private_key) and byte_size(ctx.private_key) == 32
    assert is_binary(ctx.public_key) and byte_size(ctx.public_key) == 32
  end

  test "the keypair is stable across calls (minted once, then read)" do
    assert {:ok, ctx1} = NodeIdentity.signing_context()
    assert {:ok, ctx2} = NodeIdentity.signing_context()
    assert ctx1.public_key == ctx2.public_key
    assert ctx1.private_key == ctx2.private_key
  end

  test "a missing key is refused when a prior world is present", %{dir: dir} do
    File.write!(Path.join(dir, "root"), "prior-world")

    assert {:error, {:node_signing_key_absent, :prior_world_present}} =
             NodeIdentity.signing_context()

    refute File.exists?(Path.join(dir, "node_signing_key"))
  end

  test "an existing key loads unchanged when a prior world is present", %{dir: dir} do
    assert {:ok, ctx_before} = NodeIdentity.signing_context()
    key_path = Path.join(dir, "node_signing_key")
    key_contents = File.read!(key_path)
    File.write!(Path.join(dir, "root"), "prior-world")

    assert {:ok, ctx_after} = NodeIdentity.signing_context()
    assert ctx_after == ctx_before
    assert File.read!(key_path) == key_contents
  end

  test "public_key/0 and identity/0 agree with the context" do
    assert {:ok, ctx} = NodeIdentity.signing_context()
    assert {:ok, pub} = NodeIdentity.public_key()
    assert pub == ctx.public_key
    assert {:ok, id} = NodeIdentity.identity()
    assert id == ctx.identity_uuid
  end

  test "the private key is persisted under data_dir, not synced", %{dir: dir} do
    assert {:ok, _ctx} = NodeIdentity.signing_context()
    # A node signing key file exists locally; its name is node-scoped.
    assert File.exists?(Path.join(dir, "node_signing_key"))
  end

  test "a context produced here actually verifies a commit it signs" do
    {:ok, ctx} = NodeIdentity.signing_context()
    commit = Commonplace.Store.Commit.new("d", "u", nil)
    signer_id = Signing.signer_id(ctx.identity_uuid, ctx.public_key)
    signed = Signing.sign_commit(commit, ctx.private_key, signer_id)
    assert :ok = Signing.verify_commit(signed, ctx.public_key)
  end
end
