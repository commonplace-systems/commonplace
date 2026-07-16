defmodule Commonplace.MUD.WorldMetaTest do
  @moduledoc """
  CX-lr73 (self-hosting slice 2, part C) — the MUD world's own TITLE
  (previously the hardcoded `<h1>` in `CommonplaceWebWeb.MudLive`) as a
  node-signed CRDT document, with the compiled title as a non-brick
  floor. Setup mirrors `HelpDocTest`/`HomeTemplateTest`.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Crypto.{Signing, SigningContext}
  alias Commonplace.Document.ContentType
  alias Commonplace.Code.SourceDoc
  alias Commonplace.MUD.{Bootstrap, WorldMeta}
  alias Commonplace.Store.{CommitStore, CommitStoreClient}

  @store CommitStoreClient

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_world_meta_#{:rand.uniform(1_000_000_000)}")
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

  defp clear_manifest do
    manifest = Application.get_env(:commonplace, :mud_engine_manifest, %{})
    Application.put_env(:commonplace, :mud_engine_manifest, Map.delete(manifest, :world_meta))
  end

  defp set_manifest(uuid) do
    manifest = Application.get_env(:commonplace, :mud_engine_manifest, %{})
    Application.put_env(:commonplace, :mud_engine_manifest, Map.put(manifest, :world_meta, uuid))
  end

  defp meta_content_update(json) do
    Yelixer.Doc.new()
    |> ContentType.create(:text, "_world_meta.json")
    |> ContentType.insert_text(0, json)
    |> Yelixer.Encoding.encode_update()
  end

  defp mint_meta(json, opts) do
    uuid = UUID.uuid4()

    CommitStore.create_chained_commit(
      CommitStore,
      uuid,
      meta_content_update(json),
      %{kind: :regular},
      opts
    )

    uuid
  end

  defp edit_meta(uuid, json, opts) do
    CommitStore.create_chained_commit(
      CommitStore,
      uuid,
      meta_content_update(json),
      %{kind: :regular},
      opts
    )

    SourceDoc.reset_cache()
    :ok
  end

  test "(a) no manifest entry -> the compiled-in floor title is returned" do
    permissive!()
    clear_manifest()

    assert WorldMeta.title(@store) == WorldMeta.floor()
    assert WorldMeta.floor() == "The Emberlight Vault"
  end

  test "(b) after Bootstrap.ensure_world_meta, doc content is returned and == floor initially" do
    permissive!()
    assert :ok = Bootstrap.ensure_world_meta(@store)

    assert WorldMeta.title(@store) == WorldMeta.floor()
  end

  test "(c) editing the seeded doc (node-signed) -> title returns the EDITED text (the self-hosting win)",
       %{trusted: trusted, trusted_id: trusted_id, trusted_pub: trusted_pub} do
    strict!(%{trusted_id => Signing.encode_key(trusted_pub)})

    uuid = mint_meta(WorldMeta.floor_json(), signing_context: trusted)
    set_manifest(uuid)

    assert WorldMeta.title(@store) == WorldMeta.floor()

    edited = Jason.encode!(%{"title" => "The Sunken Archive"})
    :ok = edit_meta(uuid, edited, signing_context: trusted)

    assert WorldMeta.title(@store) == "The Sunken Archive"
    refute WorldMeta.title(@store) == WorldMeta.floor()
  end

  test "(d) ensure_world_meta is idempotent — a second call does not reseed/duplicate" do
    permissive!()
    assert :ok = Bootstrap.ensure_world_meta(@store)

    manifest_after_first =
      Application.get_env(:commonplace, :mud_engine_manifest, %{})[:world_meta]

    {:ok, _source, hash_after_first} = SourceDoc.read(manifest_after_first, @store)

    assert :ok = Bootstrap.ensure_world_meta(@store)

    manifest_after_second =
      Application.get_env(:commonplace, :mud_engine_manifest, %{})[:world_meta]

    {:ok, _source, hash_after_second} = SourceDoc.read(manifest_after_second, @store)

    assert manifest_after_first == manifest_after_second
    assert hash_after_first == hash_after_second
  end

  # (e) defacement defense: a player-signed latest commit -> floor.
  test "(e) a player-signed latest commit on the world-meta doc -> the floor (defacement defense)",
       %{trusted: trusted, trusted_id: trusted_id, trusted_pub: trusted_pub, player: player} do
    strict!(%{trusted_id => Signing.encode_key(trusted_pub)})

    uuid = mint_meta(WorldMeta.floor_json(), signing_context: trusted)
    set_manifest(uuid)
    assert WorldMeta.title(@store) == WorldMeta.floor()

    defaced = Jason.encode!(%{"title" => "PWNED"})
    :ok = edit_meta(uuid, defaced, signing_context: player)

    # The player-signed commit is refused authority (Gate B) -> floor served,
    # the defacement never surfaces to players.
    assert WorldMeta.title(@store) == WorldMeta.floor()
    refute WorldMeta.title(@store) =~ "PWNED"
  end

  test "Bootstrap.ensure_world_meta seeds a node-signed world-meta doc registered under :world_meta in the manifest" do
    permissive!()
    clear_manifest()

    assert :ok = Bootstrap.ensure_world_meta(@store)

    manifest = Application.get_env(:commonplace, :mud_engine_manifest, %{})
    assert is_binary(manifest[:world_meta])
    assert WorldMeta.title(@store) == WorldMeta.floor()
  end

  test "(f) unparseable doc content falls back to the floor" do
    permissive!()

    uuid = mint_meta("not json at all", [])
    set_manifest(uuid)

    assert WorldMeta.title(@store) == WorldMeta.floor()
  end
end
