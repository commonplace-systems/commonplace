defmodule Commonplace.MUD.HomeTemplateTest do
  @moduledoc """
  CX-gkqk (self-hosting slice 2, part B) — the citizenship starter-home
  room's name/description as a node-signed CRDT document, with the
  compiled strings as a non-brick floor. Setup mirrors `HelpDocTest`
  (the CX-hbb2 reference for this doc-hosted-content family): a pinned
  "trusted" (node-stand-in) identity and an unpinned "player" (adversary)
  identity, under a fresh isolated `CommitStore`.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Crypto.{Signing, SigningContext}
  alias Commonplace.Document.ContentType
  alias Commonplace.Code.SourceDoc
  alias Commonplace.MUD.{Bootstrap, Citizenship, HomeTemplate}
  alias Commonplace.Store.{CommitStore, CommitStoreClient}
  alias Commonplace.Tree.Schema

  @store CommitStoreClient

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_home_template_#{:rand.uniform(1_000_000_000)}")
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
    Application.put_env(:commonplace, :mud_engine_manifest, Map.delete(manifest, :home_template))
  end

  defp set_manifest(uuid) do
    manifest = Application.get_env(:commonplace, :mud_engine_manifest, %{})

    Application.put_env(
      :commonplace,
      :mud_engine_manifest,
      Map.put(manifest, :home_template, uuid)
    )
  end

  defp template_content_update(json) do
    Yelixer.Doc.new()
    |> ContentType.create(:text, "_home_template.json")
    |> ContentType.insert_text(0, json)
    |> Yelixer.Encoding.encode_update()
  end

  defp mint_template(json, opts) do
    uuid = UUID.uuid4()

    CommitStore.create_chained_commit(
      CommitStore,
      uuid,
      template_content_update(json),
      %{kind: :regular},
      opts
    )

    uuid
  end

  defp edit_template(uuid, json, opts) do
    CommitStore.create_chained_commit(
      CommitStore,
      uuid,
      template_content_update(json),
      %{kind: :regular},
      opts
    )

    SourceDoc.reset_cache()
    :ok
  end

  test "(a) no manifest entry -> the compiled-in floor is rendered" do
    permissive!()
    clear_manifest()

    assert HomeTemplate.render("arwen", true, @store) == %{
             name: "arwen's Home",
             description:
               "A quiet room that is yours to shape — this is your own corner of the world." <>
                 " An exit leads <out> to the rest of the demesne."
           }
  end

  test "(a2) floor without an exit omits the exit-note fragment" do
    permissive!()
    clear_manifest()

    assert HomeTemplate.render("arwen", false, @store) == %{
             name: "arwen's Home",
             description:
               "A quiet room that is yours to shape — this is your own corner of the world."
           }
  end

  test "(b) after Bootstrap.ensure_home_template, doc content is returned and == floor initially" do
    permissive!()
    assert :ok = Bootstrap.ensure_home_template(@store)

    assert HomeTemplate.render("sam", true, @store) ==
             HomeTemplate.render("sam", true, @store)

    floor = HomeTemplate.floor()
    exit_note = floor.exit_note

    assert HomeTemplate.render("sam", true, @store) == %{
             name: "sam's Home",
             description:
               floor.description
               |> String.replace("{name}", "sam")
               |> String.replace("{exit_note}", exit_note)
           }
  end

  test "(c) editing the seeded doc (node-signed) -> render reflects the EDITED prose (self-hosting win)",
       %{trusted: trusted, trusted_id: trusted_id, trusted_pub: trusted_pub} do
    strict!(%{trusted_id => Signing.encode_key(trusted_pub)})

    json = HomeTemplate.floor_json()
    uuid = mint_template(json, signing_context: trusted)
    set_manifest(uuid)

    assert HomeTemplate.render("arwen", true, @store).name == "arwen's Home"

    edited =
      Jason.encode!(%{
        "name" => "{name}'s Sanctum",
        "description" => "EDITED PROSE{exit_note}",
        "exit_note" => " (edited exit note)"
      })

    :ok = edit_template(uuid, edited, signing_context: trusted)

    assert HomeTemplate.render("arwen", true, @store) == %{
             name: "arwen's Sanctum",
             description: "EDITED PROSE (edited exit note)"
           }
  end

  test "(d) ensure_home_template is idempotent — a second call does not reseed/duplicate" do
    permissive!()
    assert :ok = Bootstrap.ensure_home_template(@store)

    manifest_after_first =
      Application.get_env(:commonplace, :mud_engine_manifest, %{})[:home_template]

    {:ok, _source, hash_after_first} = SourceDoc.read(manifest_after_first, @store)

    assert :ok = Bootstrap.ensure_home_template(@store)

    manifest_after_second =
      Application.get_env(:commonplace, :mud_engine_manifest, %{})[:home_template]

    {:ok, _source, hash_after_second} = SourceDoc.read(manifest_after_second, @store)

    assert manifest_after_first == manifest_after_second
    assert hash_after_first == hash_after_second
  end

  # (e) defacement defense: a player-signed latest commit -> floor.
  test "(e) a player-signed latest commit on the template doc -> the floor (defacement defense)",
       %{trusted: trusted, trusted_id: trusted_id, trusted_pub: trusted_pub, player: player} do
    strict!(%{trusted_id => Signing.encode_key(trusted_pub)})

    json = HomeTemplate.floor_json()
    uuid = mint_template(json, signing_context: trusted)
    set_manifest(uuid)
    assert HomeTemplate.render("arwen", true, @store).name == "arwen's Home"

    defaced = Jason.encode!(%{"name" => "PWNED", "description" => "PWNED", "exit_note" => ""})
    :ok = edit_template(uuid, defaced, signing_context: player)

    # The player-signed commit is refused authority (Gate B) -> floor served,
    # the defacement never surfaces to players.
    rendered = HomeTemplate.render("arwen", true, @store)
    assert rendered.name == "arwen's Home"
    refute rendered.name =~ "PWNED"
  end

  test "(f) security fields are never templatable — render/3 returns ONLY name/description" do
    permissive!()
    clear_manifest()

    rendered = HomeTemplate.render("arwen", true, @store)
    assert Map.keys(rendered) |> Enum.sort() == [:description, :name]
  end

  test "(g) Citizenship.home_room_json keeps owner/visibility/exits fixed even with a node-signed edited template",
       %{trusted: trusted, trusted_id: trusted_id, trusted_pub: trusted_pub} do
    strict!(%{trusted_id => Signing.encode_key(trusted_pub)})

    json = HomeTemplate.floor_json()
    uuid = mint_template(json, signing_context: trusted)
    set_manifest(uuid)

    edited =
      Jason.encode!(%{
        "name" => "{name}'s Sanctum",
        "description" => "RESTYLED{exit_note}",
        "exit_note" => " (out there)"
      })

    :ok = edit_template(uuid, edited, signing_context: trusted)

    root_uuid = UUID.uuid4()
    update = Yelixer.Encoding.encode_update(Schema.new_schema())

    assert %Commonplace.Store.Commit{} =
             CommitStore.create_commit(CommitStore, root_uuid, update, nil, %{},
               signing_context: trusted
             )

    # A "start" room under root, so `has_exit?` is true and the exit-note
    # fragment is exercised (mirrors the real MUD root's layout).
    start_json =
      Commonplace.MUD.Schemas.encode_room(%Commonplace.MUD.Schemas.Room{
        name: "The Start Room",
        description: "..."
      })

    {:ok, start_uuid} =
      Commonplace.MUD.Schemas.create_dir_with_meta(
        Commonplace.MUD.Schemas.room_filename(),
        start_json,
        @store
      )

    {:ok, root_schema} = Commonplace.MUD.Schemas.load_dir_schema(root_uuid, @store)
    root_schema = Schema.add_directory(root_schema, "start", start_uuid)

    root_update = Yelixer.Encoding.encode_update(root_schema)

    %Commonplace.Store.Commit{} =
      CommitStore.create_chained_commit(CommitStore, root_uuid, root_update)

    {citizen_pub, _citizen_priv} = Signing.generate_keypair()
    citizen_id = UUID.uuid4()

    assert {:ok, %{home_room_uuid: home_uuid}} =
             Citizenship.ensure(citizen_id, citizen_pub, "zed", root_uuid, @store)

    assert {:ok, room} = Commonplace.MUD.Schemas.load_room(home_uuid, @store)
    assert room.name == "zed's Sanctum"
    assert room.description == "RESTYLED (out there)"
    # Security fields untouched by the template.
    assert room.owner == citizen_id
    assert room.visibility == :capability_gated
  end
end
