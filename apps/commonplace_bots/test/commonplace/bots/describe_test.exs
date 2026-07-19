defmodule Commonplace.Bots.DescribeTest do
  @moduledoc """
  Camillo C5b (cp-plan #8880) — the `describe` tool: the bot REWRITES a room's
  description, memory distilled onto a room's face.

  Pins authored FROM THE SPEC (not from reading the implementation — lesson
  #8): (a) a describe of the bot's own room LANDS under real enforce and the
  zone stamp byte-survives; (b) a describe outside the home is refused at the
  TOOL layer (before any write, even permissive) AND separately at the GATE
  layer (a direct write bypassing the tool check is DENIED under real
  enforce); (c) the CX-k20z class — unrelated fields of the room's
  `__room.json` byte-survive a describe (a sentinel field written first,
  unchanged after); (d) the ~4096-byte cap refuses honestly with no write;
  (e) covered in `agenda_test.exs` (dedupe / replace, not this tool).
  """
  use ExUnit.Case, async: false

  alias Commonplace.Bots.Identity, as: BotIdentity
  alias Commonplace.Bots.{Citizen, MudContext}
  alias Commonplace.Bots.Worker.Tools.Describe
  alias Commonplace.MUD.{Schemas, World}
  alias Commonplace.Store.SecretStore
  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.Schema
  alias Yelixer.Encoding

  setup do
    n = :rand.uniform(1_000_000_000)
    dir = Path.join(System.tmp_dir!(), "cp_bots_describe_#{n}")
    File.mkdir_p!(dir)
    store = :"describe_store_#{n}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: dir,
       name: :"describe_sup_#{n}",
       commit_store_name: store,
       trust_side_store_name: :"describe_tss_#{n}",
       pending_imports_name: :"describe_pi_#{n}"}
    )

    old_data_dir = Application.get_env(:commonplace, :data_dir)
    Application.put_env(:commonplace, :data_dir, dir)

    # PIN (b)'s tool-layer test moves a presence externally, which takes green
    # tokens (World.move_presence -> Move.move -> Bursar) — a Bursar must run
    # under its default name for that path to work (mirrors mud_tools_test.exs).
    case GenServer.whereis(Commonplace.Green.Bursar) do
      nil ->
        :ok

      pid ->
        try do
          GenServer.stop(pid)
        catch
          :exit, _ -> :ok
        end
    end

    {:ok, bursar_pid} =
      Commonplace.Green.Bursar.start_link(
        root_uuid: UUID.uuid4(),
        store: store,
        sweep_interval: 60_000
      )

    secrets_dir = Path.join(System.tmp_dir!(), "cp_bots_describe_secrets_#{n}")
    File.mkdir_p!(secrets_dir)
    secrets = :"describe_secrets_#{n}"
    {:ok, secrets_pid} = SecretStore.start_link(data_dir: secrets_dir, name: secrets)

    on_exit(fn ->
      Application.put_env(:commonplace, :data_dir, old_data_dir || "tmp/test_data")

      if Process.alive?(bursar_pid) do
        try do
          GenServer.stop(bursar_pid)
        catch
          :exit, _ -> :ok
        end
      end

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

  defp resolve_bot(name, ctx) do
    {:ok, prov} = Citizen.provision(name, ctx.mud_root, ctx.store, secret_store: ctx.secrets)

    {:ok, sc} =
      BotIdentity.resolve_signing_context(name, ctx.mud_root, ctx.store,
        secret_store: ctx.secrets
      )

    {:ok, mud_ctx} = MudContext.resolve(%{name: name}, sc, ctx.mud_root, ctx.store)
    {prov, sc, mud_ctx}
  end

  defp with_enforce(fun) do
    prior_gate = Application.get_env(:commonplace, :local_write_gate)
    prior_trust = Application.get_env(:commonplace, :trust)

    Application.put_env(:commonplace, :local_write_gate, :enforce)
    Application.put_env(:commonplace, :trust, %{accept_unsigned: false, trusted_identities: %{}})

    try do
      fun.()
    after
      case prior_gate do
        nil -> Application.delete_env(:commonplace, :local_write_gate)
        v -> Application.put_env(:commonplace, :local_write_gate, v)
      end

      case prior_trust do
        nil -> Application.delete_env(:commonplace, :trust)
        v -> Application.put_env(:commonplace, :trust, v)
      end
    end
  end

  ## (a) describe-his-room lands under real enforce; zone stamp byte-survives

  test "PIN (a): describing the room he's standing in LANDS under enforce; zone survives", ctx do
    with_enforce(fn ->
      {prov, _sc, mud_ctx} = resolve_bot("camillo", ctx)

      assert {:ok, msg} = Describe.call(%{mud_ctx: mud_ctx}, %{"text" => "A tidy little foyer."})
      assert msg =~ "described"

      {:ok, room} = World.get_room(prov.foyer_uuid, ctx.store)
      assert room.description == "A tidy little foyer."

      {:ok, note_map} = World.get_meta_map(prov.foyer_uuid, Schemas.room_filename(), ctx.store)
      assert note_map["zone"] == prov.home_room_uuid
    end)
  end

  test "describe writes are bot-signed (latest commit on the room meta)", ctx do
    {prov, sc, mud_ctx} = resolve_bot("camillo", ctx)

    assert {:ok, _} = Describe.call(%{mud_ctx: mud_ctx}, %{"text" => "Freshly described."})

    {:ok, meta_uuid} = World.meta_doc_uuid(prov.foyer_uuid, Schemas.room_filename(), ctx.store)
    {:ok, head} = CommitStore.latest_commit(ctx.store, meta_uuid)
    assert Commonplace.Crypto.Signing.signed?(head)
    assert head.signer_id == Commonplace.Crypto.Signing.signer_id(sc.identity_uuid, sc.public_key)
  end

  test "describe REPLACES (not appends): a second call overwrites the first text", ctx do
    {prov, _sc, mud_ctx} = resolve_bot("camillo", ctx)

    assert {:ok, _} = Describe.call(%{mud_ctx: mud_ctx}, %{"text" => "First draft."})
    assert {:ok, _} = Describe.call(%{mud_ctx: mud_ctx}, %{"text" => "Second, better draft."})

    {:ok, room} = World.get_room(prov.foyer_uuid, ctx.store)
    assert room.description == "Second, better draft."
    refute room.description =~ "First draft"
  end

  test "a named target within the home resolves and describes that room", ctx do
    {prov, _sc, mud_ctx} = resolve_bot("camillo", ctx)

    assert {:ok, msg} =
             Describe.call(%{mud_ctx: mud_ctx}, %{
               "target" => "Study",
               "text" => "Books everywhere."
             })

    assert msg =~ "described"

    {:ok, foyer} = World.get_room(prov.foyer_uuid, ctx.store)
    {:ok, study} = World.get_room(prov.study_uuid, ctx.store)
    assert study.description == "Books everywhere."
    refute foyer.description == "Books everywhere."
  end

  test "an unknown room name is a sanitized not-found refusal, no write", ctx do
    {prov, _sc, mud_ctx} = resolve_bot("camillo", ctx)
    {:ok, before} = World.get_room(prov.foyer_uuid, ctx.store)

    assert {:error, msg} =
             Describe.call(%{mud_ctx: mud_ctx}, %{"target" => "Nonexistent Cellar", "text" => "x"})

    assert is_binary(msg)

    {:ok, after_} = World.get_room(prov.foyer_uuid, ctx.store)
    assert after_.description == before.description
  end

  ## (b) describe-outside-home refused at TOOL layer + GATE layer, separately

  test "PIN (b) TOOL LAYER: standing outside his own home zone, describe('here') refuses BEFORE any write, even permissive",
       ctx do
    {camillo, sc, mud_ctx} = resolve_bot("camillo", ctx)
    {rival, _rival_sc, _rival_ctx} = resolve_bot("rival", ctx)

    # Externally relocate camillo's presence into rival's home (a real Room,
    # genuinely outside camillo's own zone) — as if summoned there.
    :ok =
      World.move_presence(
        mud_ctx.presence_uuid,
        "camillo.usr",
        camillo.foyer_uuid,
        rival.home_room_uuid,
        store: ctx.store,
        signing_context: sc,
        cert_cids: mud_ctx.cert_cids,
        signer_id: mud_ctx.signer_id,
        viewer: sc.identity_uuid
      )

    # Re-resolve so current_room_uuid reflects the (foreign) live position.
    {:ok, moved_ctx} = MudContext.resolve(%{name: "camillo"}, sc, ctx.mud_root, ctx.store)
    assert moved_ctx.current_room_uuid == rival.home_room_uuid

    {:ok, before} = World.get_room(rival.home_room_uuid, ctx.store)

    # Permissive local write gate (test default) — the refusal must still fire
    # at the TOOL layer, not rely on the gate to catch it.
    assert {:error, msg} =
             Describe.call(%{mud_ctx: moved_ctx}, %{"text" => "Squatting here now."})

    assert msg =~ "your own home"

    {:ok, after_} = World.get_room(rival.home_room_uuid, ctx.store)
    assert after_.description == before.description
  end

  test "PIN (b) GATE LAYER: a direct write bypassing the tool check is DENIED under real enforce",
       ctx do
    with_enforce(fn ->
      {_camillo, sc, mud_ctx} = resolve_bot("camillo", ctx)
      {rival, _rival_sc, _rival_ctx} = resolve_bot("rival", ctx)

      {:ok, before} = World.get_room(rival.home_room_uuid, ctx.store)

      # Bypass Describe entirely: a raw merge_meta with CAMILLO's own creds
      # against RIVAL's home. His {:subtree, home} cert doesn't cover it, so
      # the ordinary subtree write-carve denies it — independent of whether
      # the tool-layer check exists at all.
      result =
        World.merge_meta(
          rival.home_room_uuid,
          Schemas.room_filename(),
          %{"description" => "forged"},
          ctx.store,
          signing_context: sc,
          cert_cids: mud_ctx.cert_cids,
          signer_id: mud_ctx.signer_id
        )

      assert {:error, _} = result

      {:ok, after_} = World.get_room(rival.home_room_uuid, ctx.store)
      assert after_.description == before.description
    end)
  end

  ## (c) CX-k20z class: unrelated fields byte-survive a describe

  test "PIN (c): a sentinel field on the room meta survives a describe untouched", ctx do
    {prov, _sc, mud_ctx} = resolve_bot("camillo", ctx)

    :ok =
      World.set_meta(prov.foyer_uuid, Schemas.room_filename(), "sentinel", "keep-me", ctx.store,
        signing_context: mud_ctx.signing_context,
        cert_cids: mud_ctx.cert_cids,
        signer_id: mud_ctx.signer_id
      )

    {:ok, before} = World.get_meta_map(prov.foyer_uuid, Schemas.room_filename(), ctx.store)
    assert before["sentinel"] == "keep-me"
    assert before["exits"] != nil

    assert {:ok, _} = Describe.call(%{mud_ctx: mud_ctx}, %{"text" => "Newly described."})

    {:ok, after_} = World.get_meta_map(prov.foyer_uuid, Schemas.room_filename(), ctx.store)
    assert after_["sentinel"] == "keep-me"
    assert after_["exits"] == before["exits"]
    assert after_["zone"] == before["zone"]
    assert after_["description"] == "Newly described."
  end

  ## (d) cap refusal is honest, no write

  test "PIN (d): a description over the byte cap is refused honestly, no write", ctx do
    {prov, _sc, mud_ctx} = resolve_bot("camillo", ctx)
    {:ok, before} = World.get_room(prov.foyer_uuid, ctx.store)

    too_long = String.duplicate("x", 4097)

    assert {:error, msg} = Describe.call(%{mud_ctx: mud_ctx}, %{"text" => too_long})
    assert msg =~ "too long"

    {:ok, after_} = World.get_room(prov.foyer_uuid, ctx.store)
    assert after_.description == before.description
  end

  test "a description at exactly the cap boundary is accepted", ctx do
    {_prov, _sc, mud_ctx} = resolve_bot("camillo", ctx)
    at_cap = String.duplicate("x", 4096)

    assert {:ok, _} = Describe.call(%{mud_ctx: mud_ctx}, %{"text" => at_cap})
  end

  ## Ungrouped: graceful refusals, no mud_ctx

  test "no mud_ctx (unprovisioned) refuses gracefully", _ctx do
    assert {:error, "You are not in the world."} =
             Describe.call(%{mud_ctx: nil}, %{"text" => "x"})
  end

  test "an empty text field is refused", ctx do
    {_prov, _sc, mud_ctx} = resolve_bot("camillo", ctx)

    assert {:error, _} = Describe.call(%{mud_ctx: mud_ctx}, %{"text" => ""})
    assert {:error, _} = Describe.call(%{mud_ctx: mud_ctx}, %{})
  end

  test "describe is registered under the default-closed allowlist convention", _ctx do
    assert Describe.name() == "describe"
    defn = Describe.definition()
    assert defn["name"] == "describe"
    assert is_map(defn["input_schema"])
  end
end
