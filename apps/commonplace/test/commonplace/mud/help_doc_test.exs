defmodule Commonplace.MUD.HelpDocTest do
  @moduledoc """
  CX-hbb2 (self-hosting slice A) — the MUD's in-world `help` text as a
  node-signed CRDT document, editable without redeploy, with the compiled
  string as a non-brick floor. Setup mirrors `EngineModuleTest` (the Gate-B
  reference for this doc-hosted-content family): a pinned "trusted"
  (node-stand-in) identity and an unpinned "player" (adversary) identity,
  under a fresh isolated `CommitStore`.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Crypto.{Signing, SigningContext}
  alias Commonplace.Document.ContentType
  alias Commonplace.Code.SourceDoc
  alias Commonplace.MUD.{Bootstrap, HelpDoc}
  alias Commonplace.Store.{CommitStore, CommitStoreClient}

  @store CommitStoreClient

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_help_doc_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    Application.put_env(:commonplace, :data_dir, dir)

    sup = Commonplace.Store.CommitStoreSupervisor
    _ = Supervisor.terminate_child(sup, Commonplace.Store.CommitStore)
    _ = Supervisor.delete_child(sup, Commonplace.Store.CommitStore)
    {:ok, _pid} = Supervisor.start_child(sup, {Commonplace.Store.CommitStore, data_dir: dir})

    Commonplace.Tree.DocCache.clear()
    SourceDoc.reset_cache()

    {trusted_pub, trusted_priv} = Signing.generate_keypair()
    trusted_id = "eea11111-0000-0000-0000-#{:rand.uniform(999_999_999_999)}"

    trusted = %SigningContext{
      identity_uuid: trusted_id,
      public_key: trusted_pub,
      private_key: trusted_priv
    }

    {player_pub, player_priv} = Signing.generate_keypair()
    player_id = "b0b22222-0000-0000-0000-#{:rand.uniform(999_999_999_999)}"

    player = %SigningContext{
      identity_uuid: player_id,
      public_key: player_pub,
      private_key: player_priv
    }

    old_manifest = Application.get_env(:commonplace, :mud_engine_manifest)
    old_trust = Application.get_env(:commonplace, :trust)

    on_exit(fn ->
      if is_nil(old_manifest),
        do: Application.delete_env(:commonplace, :mud_engine_manifest),
        else: Application.put_env(:commonplace, :mud_engine_manifest, old_manifest)

      if is_nil(old_trust),
        do: Application.delete_env(:commonplace, :trust),
        else: Application.put_env(:commonplace, :trust, old_trust)

      _ = Supervisor.terminate_child(sup, Commonplace.Store.CommitStore)
      _ = Supervisor.delete_child(sup, Commonplace.Store.CommitStore)
      Application.put_env(:commonplace, :data_dir, "tmp/test_data")

      {:ok, _pid} =
        Supervisor.start_child(sup, {Commonplace.Store.CommitStore, data_dir: "tmp/test_data"})

      Commonplace.Tree.DocCache.clear()
      SourceDoc.reset_cache()
      File.rm_rf!(dir)
    end)

    %{trusted: trusted, trusted_id: trusted_id, trusted_pub: trusted_pub, player: player}
  end

  defp permissive!,
    do:
      Application.put_env(:commonplace, :trust, %{accept_unsigned: true, trusted_identities: %{}})

  defp strict!(trusted),
    do:
      Application.put_env(:commonplace, :trust, %{
        accept_unsigned: false,
        trusted_identities: trusted
      })

  defp clear_help_manifest do
    manifest = Application.get_env(:commonplace, :mud_engine_manifest, %{})
    Application.put_env(:commonplace, :mud_engine_manifest, Map.delete(manifest, :help))
  end

  defp set_help_manifest(uuid) do
    manifest = Application.get_env(:commonplace, :mud_engine_manifest, %{})
    Application.put_env(:commonplace, :mud_engine_manifest, Map.put(manifest, :help, uuid))
  end

  defp help_content_update(text) do
    Yelixer.Doc.new()
    |> ContentType.create(:text, "_mud_help.txt")
    |> ContentType.insert_text(0, text)
    |> Yelixer.Encoding.encode_update()
  end

  defp mint_help(text, opts) do
    uuid = UUID.uuid4()

    CommitStore.create_chained_commit(
      CommitStore,
      uuid,
      help_content_update(text),
      %{kind: :regular},
      opts
    )

    uuid
  end

  defp edit_help(uuid, text, opts) do
    CommitStore.create_chained_commit(
      CommitStore,
      uuid,
      help_content_update(text),
      %{kind: :regular},
      opts
    )

    SourceDoc.reset_cache()
    :ok
  end

  test "(a) no manifest entry -> the compiled-in floor text is returned" do
    permissive!()
    clear_help_manifest()

    assert HelpDoc.text(@store) == HelpDoc.floor()
  end

  test "(b) after Bootstrap.ensure_mud_help, doc content is returned and == floor initially" do
    permissive!()
    assert :ok = Bootstrap.ensure_mud_help(@store)

    assert HelpDoc.text(@store) == HelpDoc.floor()
  end

  test "(c) editing the seeded doc (node-signed) -> help returns the EDITED text (the self-hosting win)",
       %{trusted: trusted, trusted_id: trusted_id, trusted_pub: trusted_pub} do
    strict!(%{trusted_id => Signing.encode_key(trusted_pub)})

    uuid = mint_help(HelpDoc.floor(), signing_context: trusted)
    set_help_manifest(uuid)

    assert HelpDoc.text(@store) == HelpDoc.floor()

    edited = "Commands:\n  look                 look around\n  EDITED HELP TEXT LIVE\n"
    :ok = edit_help(uuid, edited, signing_context: trusted)

    assert HelpDoc.text(@store) == edited
    refute HelpDoc.text(@store) == HelpDoc.floor()
  end

  test "(d) ensure_mud_help is idempotent — a second call does not reseed/duplicate" do
    permissive!()
    assert :ok = Bootstrap.ensure_mud_help(@store)
    manifest_after_first = Application.get_env(:commonplace, :mud_engine_manifest, %{})[:help]
    {:ok, _source, hash_after_first} = SourceDoc.read(manifest_after_first, @store)

    assert :ok = Bootstrap.ensure_mud_help(@store)
    manifest_after_second = Application.get_env(:commonplace, :mud_engine_manifest, %{})[:help]
    {:ok, _source, hash_after_second} = SourceDoc.read(manifest_after_second, @store)

    assert manifest_after_first == manifest_after_second
    assert hash_after_first == hash_after_second
  end

  # (e) defacement defense: a player-signed latest commit -> floor.
  test "(e) a player-signed latest commit on the help doc -> the floor (defacement defense)",
       %{trusted: trusted, trusted_id: trusted_id, trusted_pub: trusted_pub, player: player} do
    strict!(%{trusted_id => Signing.encode_key(trusted_pub)})

    uuid = mint_help(HelpDoc.floor(), signing_context: trusted)
    set_help_manifest(uuid)
    assert HelpDoc.text(@store) == HelpDoc.floor()

    defaced = "PWNED HELP TEXT"
    :ok = edit_help(uuid, defaced, signing_context: player)

    # The player-signed commit is refused authority (Gate B) -> floor served,
    # the defacement never surfaces to players.
    assert HelpDoc.text(@store) == HelpDoc.floor()
    refute HelpDoc.text(@store) =~ "PWNED"
  end

  test "Bootstrap.ensure_mud_help seeds a node-signed help doc registered under :help in the manifest" do
    permissive!()
    clear_help_manifest()

    assert :ok = Bootstrap.ensure_mud_help(@store)

    manifest = Application.get_env(:commonplace, :mud_engine_manifest, %{})
    assert is_binary(manifest[:help])
    assert HelpDoc.text(@store) == HelpDoc.floor()
  end
end
