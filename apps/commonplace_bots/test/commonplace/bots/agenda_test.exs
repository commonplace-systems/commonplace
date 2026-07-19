defmodule Commonplace.Bots.AgendaTest do
  @moduledoc """
  Camillo C3b/C3d — the agenda is now a ZONED NOTE-META under the bot's HOME
  (`home/agenda/`), not a `agenda.jsonl` in the entity dir. These tests drive
  the ctx-based `Commonplace.Bots.Agenda` API against a provisioned citizen and
  pin that appends land + read back, are bot-signed, and survive under enforce.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Bots.Identity, as: BotIdentity
  alias Commonplace.Bots.{Agenda, Citizen, MudContext}
  alias Commonplace.Bots.Worker.Tools.UpdateAgenda
  alias Commonplace.Crypto.Signing
  alias Commonplace.MUD.World
  alias Commonplace.Store.{CommitStore, SecretStore}
  alias Commonplace.Tree.Schema
  alias Yelixer.Encoding

  setup do
    n = :rand.uniform(1_000_000_000)
    dir = Path.join(System.tmp_dir!(), "cp_bots_agenda_#{n}")
    File.mkdir_p!(dir)
    store = :"agenda_store_#{n}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: dir,
       name: :"agenda_sup_#{n}",
       commit_store_name: store,
       trust_side_store_name: :"agenda_tss_#{n}",
       pending_imports_name: :"agenda_pi_#{n}"}
    )

    old_data_dir = Application.get_env(:commonplace, :data_dir)
    Application.put_env(:commonplace, :data_dir, dir)

    secrets_dir = Path.join(System.tmp_dir!(), "cp_bots_agenda_secrets_#{n}")
    File.mkdir_p!(secrets_dir)
    secrets = :"agenda_secrets_#{n}"
    {:ok, secrets_pid} = SecretStore.start_link(data_dir: secrets_dir, name: secrets)

    on_exit(fn ->
      Application.put_env(:commonplace, :data_dir, old_data_dir || "tmp/test_data")

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

    {:ok, node_ctx} = Commonplace.Crypto.NodeIdentity.signing_context()

    mud_root = UUID.uuid4()

    CommitStore.create_commit(
      store,
      mud_root,
      Encoding.encode_update(Schema.new_schema()),
      nil,
      %{},
      signing_context: node_ctx
    )

    %{store: store, mud_root: mud_root, secrets: secrets}
  end

  defp resolve_camillo(ctx) do
    {:ok, prov} = Citizen.provision("camillo", ctx.mud_root, ctx.store, secret_store: ctx.secrets)

    {:ok, sc} =
      BotIdentity.resolve_signing_context("camillo", ctx.mud_root, ctx.store,
        secret_store: ctx.secrets
      )

    {:ok, mud_ctx} = MudContext.resolve(%{name: "camillo"}, sc, ctx.mud_root, ctx.store)
    {prov, sc, mud_ctx}
  end

  test "read/append round-trip; ensure_dir is idempotent", ctx do
    {prov, _sc, mud_ctx} = resolve_camillo(ctx)

    # Provision already made home/agenda; ensure_dir returns the same uuid.
    assert {:ok, uuid} = Agenda.ensure_dir(mud_ctx)
    assert uuid == prov.agenda_uuid
    assert {:ok, ^uuid} = Agenda.ensure_dir(mud_ctx)

    assert Agenda.read(mud_ctx) == []

    :ok = Agenda.append(%{"text" => "consolidate the pins"}, mud_ctx)
    :ok = Agenda.append(%{"text" => "file the association"}, mud_ctx)

    items = Agenda.read(mud_ctx)
    assert Enum.map(items, & &1["text"]) == ["consolidate the pins", "file the association"]
    # ts stamped when the caller omits it.
    assert Enum.all?(items, fn i -> is_binary(i["ts"]) end)
  end

  test "a nil mud_ctx reads empty and refuses appends gracefully", _ctx do
    assert Agenda.read(nil) == []
    assert {:error, :no_mud_ctx} = Agenda.append(%{"text" => "x"}, nil)
  end

  test "appends are bot-signed (latest commit on the agenda note-meta)", ctx do
    {prov, sc, mud_ctx} = resolve_camillo(ctx)

    :ok = Agenda.append(%{"text" => "signed item"}, mud_ctx)

    {:ok, meta_uuid} = World.meta_doc_uuid(prov.agenda_uuid, "__note.json", ctx.store)
    {:ok, head} = CommitStore.latest_commit(ctx.store, meta_uuid)
    assert Signing.signed?(head)
    assert head.signer_id == Signing.signer_id(sc.identity_uuid, sc.public_key)
  end

  test "the update_agenda tool appends an item (via mud_ctx)", ctx do
    {_prov, _sc, mud_ctx} = resolve_camillo(ctx)

    assert {:ok, _} = UpdateAgenda.call(%{mud_ctx: mud_ctx}, %{"text" => "from the tool"})

    assert Enum.map(Agenda.read(mud_ctx), & &1["text"]) == ["from the tool"]
  end

  test "update_agenda rejects an empty text field", ctx do
    {_prov, _sc, mud_ctx} = resolve_camillo(ctx)

    assert {:error, _} = UpdateAgenda.call(%{mud_ctx: mud_ctx}, %{"text" => ""})
    assert {:error, _} = UpdateAgenda.call(%{mud_ctx: mud_ctx}, %{})
  end
end
