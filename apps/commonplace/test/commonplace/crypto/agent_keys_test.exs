defmodule Commonplace.Crypto.AgentKeysTest do
  @moduledoc """
  CX-88mw(i): per-agent Ed25519 keypairs — mint, custody, lookup, rotate.

  The per-agent analog of NodeIdentity: private keys live in the
  node-local SecretStore (never synced), keyed by the agent's identity
  UUID under `"signing_key:<uuid>"` / `"signing_pub:<uuid>"` (D5 —
  mirrors the `:default` slots, base64 at rest). Authority comes from a
  capability cert delegated to the key (D6), not from these slots.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Crypto.{AgentKeys, SigningContext}
  alias Commonplace.Store.SecretStore

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_agent_keys_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    name = :"agent_keys_secrets_#{:rand.uniform(1_000_000)}"
    {:ok, pid} = SecretStore.start_link(data_dir: dir, name: name)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      File.rm_rf!(dir)
    end)

    %{secrets: name, dir: dir, secrets_pid: pid}
  end

  test "ensure/2 mints a keypair on first call and is idempotent", %{secrets: secrets} do
    uuid = UUID.uuid4()

    assert {:ok, pub} = AgentKeys.ensure(uuid, secrets)
    assert is_binary(pub) and byte_size(pub) == 32

    # Second call returns the SAME public key — no re-mint.
    assert {:ok, ^pub} = AgentKeys.ensure(uuid, secrets)
  end

  test "ensure/2 stores keys under the D5 slot names, base64 at rest", %{secrets: secrets} do
    uuid = UUID.uuid4()
    {:ok, pub} = AgentKeys.ensure(uuid, secrets)

    assert {:ok, enc_pub} = SecretStore.get(secrets, "signing_pub:" <> uuid)
    assert {:ok, enc_priv} = SecretStore.get(secrets, "signing_key:" <> uuid)
    assert Base.decode64!(enc_pub) == pub
    assert {:ok, _priv} = Base.decode64(enc_priv)
  end

  test "signing_context_for/2 returns a SigningContext matching the minted key", %{secrets: secrets} do
    uuid = UUID.uuid4()
    {:ok, pub} = AgentKeys.ensure(uuid, secrets)

    assert {:ok, %SigningContext{} = ctx} = AgentKeys.signing_context_for(uuid, secrets)
    assert ctx.identity_uuid == uuid
    assert ctx.public_key == pub

    # The pair actually signs/verifies — raw bytes, not base64.
    sig = :crypto.sign(:eddsa, :none, "payload", [ctx.private_key, :ed25519])
    assert :crypto.verify(:eddsa, :none, "payload", sig, [ctx.public_key, :ed25519])
  end

  test "signing_context_for/2 returns :not_found for an unknown identity", %{secrets: secrets} do
    assert :not_found = AgentKeys.signing_context_for(UUID.uuid4(), secrets)
  end

  test "keys survive a SecretStore restart (CubDB-backed)", %{
    secrets: secrets,
    secrets_pid: pid,
    dir: dir
  } do
    uuid = UUID.uuid4()
    {:ok, pub} = AgentKeys.ensure(uuid, secrets)

    # Stop the underlying CubDB explicitly: a :normal GenServer.stop on
    # the SecretStore does not take its linked CubDB down, and CubDB
    # holds an exclusive file lock that would block the reopen.
    %{db: db} = :sys.get_state(pid)
    GenServer.stop(pid)
    CubDB.stop(db)
    name2 = :"agent_keys_secrets_restart_#{:rand.uniform(1_000_000)}"
    # CubDB releases its exclusive file lock asynchronously after the
    # owning SecretStore stops — retry briefly until the reopen sticks.
    pid2 = restart_secret_store(dir, name2, 50)
    on_exit(fn -> if Process.alive?(pid2), do: GenServer.stop(pid2) end)

    assert {:ok, %SigningContext{public_key: ^pub}} =
             AgentKeys.signing_context_for(uuid, name2)
  end

  test "rotate/2 mints a new pair; signing_context_for returns the NEW key", %{secrets: secrets} do
    uuid = UUID.uuid4()
    {:ok, old_pub} = AgentKeys.ensure(uuid, secrets)

    assert {:ok, new_pub} = AgentKeys.rotate(uuid, secrets)
    refute new_pub == old_pub

    assert {:ok, %SigningContext{public_key: ^new_pub}} =
             AgentKeys.signing_context_for(uuid, secrets)

    # ensure/2 after rotation keeps the rotated key (idempotent on the
    # current slots — no silent re-mint).
    assert {:ok, ^new_pub} = AgentKeys.ensure(uuid, secrets)
  end

  # Start a SecretStore on a dir whose previous owner just stopped,
  # retrying while CubDB's exclusive file lock drains. Exits are trapped
  # so a transient lock-contention crash doesn't kill the test process.
  defp restart_secret_store(dir, name, attempts) do
    old_trap = Process.flag(:trap_exit, true)

    try do
      do_restart(dir, name, attempts)
    after
      Process.flag(:trap_exit, old_trap)
    end
  end

  defp do_restart(_dir, _name, 0), do: flunk("SecretStore restart never succeeded")

  defp do_restart(dir, name, attempts) do
    case SecretStore.start_link(data_dir: dir, name: name, auto_compact: false) do
      {:ok, pid} ->
        pid

      {:error, _} ->
        Process.sleep(50)
        do_restart(dir, name, attempts - 1)
    end
  rescue
    _ ->
      Process.sleep(50)
      do_restart(dir, name, attempts - 1)
  catch
    :exit, _ ->
      Process.sleep(50)
      do_restart(dir, name, attempts - 1)
  end
end
