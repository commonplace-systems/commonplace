defmodule Commonplace.Bots.Worker.Tools.PostMessageEnforceTest do
  @moduledoc """
  Camillo C1 — the ENFORCE pin (cp-plan gate ruling #8669).

  Proves the WHOLE C1 chain under the regime the live serve actually runs
  (`accept_unsigned: false`): a bot provisioned via
  `Commonplace.Bots.Identity.resolve_signing_context/4` and PINNED in
  `trusted_identities` posts a chat message that LANDS (signed by the bot's
  own key, authorized); the SAME provisioned-but-UNPINNED bot's post is
  DENIED at the trust gate.

  C2 later replaces the trusted_identities pin with citizenship/certs — the
  progression (pinned-in-C1 → cert-native-in-C2) is itself documented
  behavior. Here, global-trust pinning is the cheap stand-in that exercises
  the signature-verifies-AND-authorizes path end-to-end.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Bots.Entity
  alias Commonplace.Bots.Identity, as: BotIdentity
  alias Commonplace.Bots.Worker.Tools.PostMessage
  alias Commonplace.Chat.Messages
  alias Commonplace.Crypto.{Signing, SigningContext}
  alias Commonplace.Store.{CommitStore, CommitStoreClient, SecretStore}
  alias Commonplace.Tree.{DocBuilder, Schema}

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_bots_pm_enforce_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    prior_data_dir = Application.get_env(:commonplace, :data_dir)
    prior_trust = Application.get_env(:commonplace, :trust)
    prior_gate = Application.get_env(:commonplace, :local_write_gate)
    Application.put_env(:commonplace, :data_dir, dir)
    # ENFORCE, not the test-default dry_run — dry_run logs "would be denied"
    # but STILL LANDS the write, so a denial assertion is vacuous without this.
    Application.put_env(:commonplace, :local_write_gate, :enforce)

    sup = Commonplace.Store.CommitStoreSupervisor
    _ = Supervisor.terminate_child(sup, Commonplace.Store.CommitStore)
    _ = Supervisor.delete_child(sup, Commonplace.Store.CommitStore)
    {:ok, _pid} = Supervisor.start_child(sup, {Commonplace.Store.CommitStore, data_dir: dir})
    Commonplace.Tree.DocCache.clear()

    secrets_dir = Path.join(System.tmp_dir!(), "cp_bots_pm_enforce_secrets_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(secrets_dir)
    secrets = :"cp_bots_pm_enforce_secrets_#{:rand.uniform(1_000_000_000)}"
    {:ok, secrets_pid} = SecretStore.start_link(data_dir: secrets_dir, name: secrets)

    # A pinned registrar/creator identity: it attests the bot registrations
    # AND creates the root + messages doc, so every setup write is authorized
    # under enforce.
    {reg_pub, reg_priv} = Signing.generate_keypair()
    registrar_id = UUID.uuid4()
    registrar = %SigningContext{identity_uuid: registrar_id, private_key: reg_priv, public_key: reg_pub}

    put_trust(%{registrar_id => Signing.encode_key(reg_pub)})

    root = UUID.uuid4()
    root_update = Yelixer.Encoding.encode_update(Schema.new_schema())
    CommitStore.create_commit(Commonplace.Store.CommitStore, root, root_update, nil, %{},
      signing_context: registrar
    )

    messages_uuid = UUID.uuid4()
    msgs_update = Yelixer.Encoding.encode_update(Messages.new())
    CommitStore.create_commit(Commonplace.Store.CommitStore, messages_uuid, msgs_update, nil, %{},
      signing_context: registrar
    )

    on_exit(fn ->
      if Process.alive?(secrets_pid) do
        try do
          GenServer.stop(secrets_pid)
        catch
          :exit, _ -> :ok
        end
      end

      _ = Supervisor.terminate_child(sup, Commonplace.Store.CommitStore)
      _ = Supervisor.delete_child(sup, Commonplace.Store.CommitStore)
      Application.put_env(:commonplace, :data_dir, prior_data_dir || "tmp/test_data")

      {:ok, _pid} =
        Supervisor.start_child(sup, {Commonplace.Store.CommitStore, data_dir: prior_data_dir || "tmp/test_data"})

      case prior_trust do
        nil -> Application.delete_env(:commonplace, :trust)
        v -> Application.put_env(:commonplace, :trust, v)
      end

      case prior_gate do
        nil -> Application.delete_env(:commonplace, :local_write_gate)
        v -> Application.put_env(:commonplace, :local_write_gate, v)
      end

      Commonplace.Tree.DocCache.clear()
      File.rm_rf!(dir)
      File.rm_rf!(secrets_dir)
    end)

    %{root: root, secrets: secrets, registrar: registrar, registrar_id: registrar_id, messages_uuid: messages_uuid}
  end

  defp put_trust(identities) do
    Application.put_env(:commonplace, :trust, %{accept_unsigned: false, trusted_identities: identities})
  end

  defp pin(identity_uuid, pub, ctx) do
    base = Map.new([{ctx.registrar_id, Signing.encode_key(ctx.registrar.public_key)}])
    put_trust(Map.put(base, identity_uuid, Signing.encode_key(pub)))
  end

  defp provision(name, ctx) do
    {:ok, sc} =
      BotIdentity.resolve_signing_context(name, ctx.root, CommitStoreClient,
        secret_store: ctx.secrets,
        registrar_signing_context: ctx.registrar
      )

    sc
  end

  defp state_for(sc, messages_uuid) do
    %{
      signing_context: sc,
      entity: %Entity{name: "camillo"},
      room: "demo",
      event: %{},
      opts: [messages_uuid: messages_uuid]
    }
  end

  defp room_texts(messages_uuid) do
    case DocBuilder.reconstruct_snapshot(CommitStoreClient, messages_uuid) do
      {:ok, doc} -> doc |> Messages.materialize() |> Enum.map(&Map.get(&1, "text"))
      _ -> []
    end
  end

  test "a PINNED bot's signed post LANDS under enforce (signer == its own key)", ctx do
    sc = provision("camillo", ctx)
    pin(sc.identity_uuid, sc.public_key, ctx)

    assert {:ok, json} = PostMessage.call(state_for(sc, ctx.messages_uuid), %{"text" => "hello under enforce"})
    assert %{"message_id" => _} = Jason.decode!(json)

    assert "hello under enforce" in room_texts(ctx.messages_uuid)

    # The landed message carries the bot's REAL signer, not a placeholder.
    {:ok, doc} = DocBuilder.reconstruct_snapshot(CommitStoreClient, ctx.messages_uuid)
    entry = doc |> Messages.materialize() |> Enum.find(&(Map.get(&1, "text") == "hello under enforce"))
    assert Map.get(entry, "author_signer_id") == Signing.signer_id(sc.identity_uuid, sc.public_key)
    refute String.starts_with?(Map.get(entry, "author_signer_id"), "bot:")
  end

  test "the SAME provisioned but UNPINNED bot is DENIED under enforce", ctx do
    sc = provision("stranger", ctx)
    # NOT pinned: trust config still holds only the registrar.

    assert {:error, _reason} = PostMessage.call(state_for(sc, ctx.messages_uuid), %{"text" => "should be denied"})
    refute "should be denied" in room_texts(ctx.messages_uuid)
  end
end
