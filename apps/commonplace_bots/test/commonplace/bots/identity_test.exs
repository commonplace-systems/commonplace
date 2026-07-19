defmodule Commonplace.Bots.IdentityTest do
  use ExUnit.Case, async: false

  alias Commonplace.Bots.Identity, as: BotIdentity
  alias Commonplace.Crypto.{Signing, SigningContext}
  alias Commonplace.Presence.Identity
  alias Commonplace.Store.{CommitStore, SecretStore}
  alias Commonplace.Tree.Schema
  alias Yelixer.Encoding

  # Named-store fixture (mirrors Commonplace.MUD.BotTest): an isolated
  # CommitStore + an isolated SecretStore so per-bot key custody assertions
  # don't touch the app's global stores or race concurrent tests. A test
  # registrar keypair signs the registration commits so NO node key is
  # needed in the tmp dir.
  setup do
    dir = Path.join(System.tmp_dir!(), "cp_bots_identity_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    store = :"cp_bots_identity_cs_#{:rand.uniform(1_000_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store})

    secrets_dir =
      Path.join(System.tmp_dir!(), "cp_bots_identity_secrets_#{:rand.uniform(1_000_000_000)}")

    File.mkdir_p!(secrets_dir)
    secrets = :"cp_bots_identity_secrets_#{:rand.uniform(1_000_000_000)}"
    {:ok, secrets_pid} = SecretStore.start_link(data_dir: secrets_dir, name: secrets)

    on_exit(fn ->
      if Process.alive?(secrets_pid) do
        try do
          GenServer.stop(secrets_pid)
        catch
          :exit, _ -> :ok
        end
      end

      File.rm_rf!(dir)
      File.rm_rf!(secrets_dir)
    end)

    root = UUID.uuid4()
    CommitStore.create_commit(store, root, Encoding.encode_update(Schema.new_schema()), nil)

    {pub, priv} = Signing.generate_keypair()
    registrar = %SigningContext{identity_uuid: UUID.uuid4(), private_key: priv, public_key: pub}

    %{store: store, root: root, secrets: secrets, registrar: registrar}
  end

  defp resolve(name, ctx) do
    BotIdentity.resolve_signing_context(name, ctx.root, ctx.store,
      secret_store: ctx.secrets,
      registrar_signing_context: ctx.registrar
    )
  end

  test "resolves a real per-bot SigningContext (no node key needed, test registrar signs)", ctx do
    assert {:ok, %SigningContext{} = sc} = resolve("scribe", ctx)

    assert is_binary(sc.identity_uuid) and sc.identity_uuid != ""
    assert byte_size(sc.private_key) > 0
    assert byte_size(sc.public_key) > 0

    # It's the BOT's own identity — a `:bot` cold identity registered under
    # the bare name, not the registrar's identity.
    assert {:ok, identity_uuid} = Identity.lookup("scribe", :bot, ctx.root, ctx.store)
    assert sc.identity_uuid == identity_uuid
    refute sc.identity_uuid == ctx.registrar.identity_uuid
  end

  test "is idempotent per bare name — two calls resolve the SAME identity + key", ctx do
    assert {:ok, sc1} = resolve("dup", ctx)
    assert {:ok, sc2} = resolve("dup", ctx)

    assert sc1.identity_uuid == sc2.identity_uuid
    assert sc1.public_key == sc2.public_key
    assert sc1.private_key == sc2.private_key
  end

  test "distinct bot names resolve to distinct principals", ctx do
    assert {:ok, a} = resolve("alice", ctx)
    assert {:ok, b} = resolve("bob", ctx)

    refute a.identity_uuid == b.identity_uuid
    refute a.public_key == b.public_key
  end

  test "signer_id derives from the resolved key (identity@fingerprint, not a placeholder)", ctx do
    assert {:ok, sc} = resolve("herald", ctx)
    signer_id = Signing.signer_id(sc.identity_uuid, sc.public_key)

    assert signer_id == "#{sc.identity_uuid}@#{Signing.fingerprint(sc.public_key)}"
    refute String.starts_with?(signer_id, "bot:")
  end
end
