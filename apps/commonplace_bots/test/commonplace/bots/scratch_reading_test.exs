defmodule Commonplace.Bots.ScratchReadingTest do
  @moduledoc """
  Camillo C5c-iii (cp-plan #8892/#8895) — `list_scratch` + `read_scratch`,
  the filing loop's READ half. "scrollback is what just happened; scratch
  is what he chose to keep; rooms are what he chose to KEEP keeping" — these
  tools are what let a turn actually consult the middle tier.

  Pins authored FROM THE SPEC (lesson #8): (a) read-back — a note written
  via the `scratch` TOOL comes back via the `read_scratch` TOOL; (b) list —
  two written pages both list, the container's own `__note.json` never
  appears; (c) traversal — a page name carrying `/` or `..` is refused,
  sanitized, before any read; (d) cap — a page over ~4000 chars is
  truncated with the honest note; (e) empty/missing — no pages ever
  written renders an honest empty message, and a page name that doesn't
  exist renders a gentle "(no such page)" message, NEVER an error tuple.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Bots.Identity, as: BotIdentity
  alias Commonplace.Bots.{Citizen, MudContext}
  alias Commonplace.Bots.Worker.Tools.{ListScratch, ReadScratch, Scratch}
  alias Commonplace.Store.SecretStore

  setup do
    n = :rand.uniform(1_000_000_000)
    dir = Path.join(System.tmp_dir!(), "cp_bots_scratchread_#{n}")
    File.mkdir_p!(dir)
    store = :"scratchread_store_#{n}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: dir,
       name: :"scratchread_sup_#{n}",
       commit_store_name: store,
       trust_side_store_name: :"scratchread_tss_#{n}",
       pending_imports_name: :"scratchread_pi_#{n}"}
    )

    old_data_dir = Application.get_env(:commonplace, :data_dir)
    Application.put_env(:commonplace, :data_dir, dir)

    secrets_dir = Path.join(System.tmp_dir!(), "cp_bots_scratchread_secrets_#{n}")
    File.mkdir_p!(secrets_dir)
    secrets = :"scratchread_secrets_#{n}"
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

    Commonplace.Store.CommitStore.create_commit(
      store,
      mud_root,
      Yelixer.Encoding.encode_update(Commonplace.Tree.Schema.new_schema()),
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

  ## --- PIN (a): read-back ---

  test "PIN (a): a note written via scratch comes back via read_scratch", ctx do
    {_prov, _sc, mud_ctx} = resolve_camillo(ctx)

    assert {:ok, _} = Scratch.call(%{mud_ctx: mud_ctx}, %{"note" => "remember this line"})

    assert {:ok, text} = ReadScratch.call(%{mud_ctx: mud_ctx}, %{})
    assert text =~ "remember this line"
  end

  test "PIN (a): read-back also works for a named (non-default) page", ctx do
    {_prov, _sc, mud_ctx} = resolve_camillo(ctx)

    assert {:ok, _} =
             Scratch.call(%{mud_ctx: mud_ctx}, %{"note" => "todo item one", "page" => "todo"})

    assert {:ok, text} = ReadScratch.call(%{mud_ctx: mud_ctx}, %{"page" => "todo"})
    assert text =~ "todo item one"

    # The default page ("notes") was never written — read_scratch is a PURE
    # lookup (never creates a page as a side effect of reading), so it
    # reads as absent, not as an empty-but-existing page.
    assert {:ok, notes_text} = ReadScratch.call(%{mud_ctx: mud_ctx}, %{})
    assert notes_text =~ "no such page"
  end

  ## --- PIN (b): list ---

  test "PIN (b): two written pages both list; the container's __note.json never appears", ctx do
    {_prov, _sc, mud_ctx} = resolve_camillo(ctx)

    assert {:ok, _} = Scratch.call(%{mud_ctx: mud_ctx}, %{"note" => "n1"})
    assert {:ok, _} = Scratch.call(%{mud_ctx: mud_ctx}, %{"note" => "t1", "page" => "todo"})

    assert {:ok, listing} = ListScratch.call(%{mud_ctx: mud_ctx}, %{})
    assert listing =~ "notes"
    assert listing =~ "todo"
    refute listing =~ "__note.json"
  end

  ## --- PIN (c): traversal ---

  test "PIN (c): a page name with a slash or \"..\" is refused, sanitized, before any read",
       ctx do
    {_prov, _sc, mud_ctx} = resolve_camillo(ctx)

    # Seed a real page first so a "successful read landed anyway" false
    # pass isn't hiding behind an empty scratchpad.
    assert {:ok, _} = Scratch.call(%{mud_ctx: mud_ctx}, %{"note" => "seed"})

    assert {:error, "Bad page name."} =
             ReadScratch.call(%{mud_ctx: mud_ctx}, %{"page" => "../../etc/passwd"})

    assert {:error, "Bad page name."} = ReadScratch.call(%{mud_ctx: mud_ctx}, %{"page" => "a/b"})
    assert {:error, "Bad page name."} = ReadScratch.call(%{mud_ctx: mud_ctx}, %{"page" => ".."})
  end

  ## --- PIN (d): cap ---

  test "PIN (d): a page over ~4000 chars is truncated with the honest note", ctx do
    {_prov, _sc, mud_ctx} = resolve_camillo(ctx)

    long_note = String.duplicate("x", 4500)
    assert {:ok, _} = Scratch.call(%{mud_ctx: mud_ctx}, %{"note" => long_note})

    assert {:ok, text} = ReadScratch.call(%{mud_ctx: mud_ctx}, %{})
    assert String.length(text) < 4500
    assert text =~ "the page continues"
  end

  test "a page at/under the cap is returned whole, with no truncation note", ctx do
    {_prov, _sc, mud_ctx} = resolve_camillo(ctx)

    short_note = String.duplicate("y", 50)
    assert {:ok, _} = Scratch.call(%{mud_ctx: mud_ctx}, %{"note" => short_note})

    assert {:ok, text} = ReadScratch.call(%{mud_ctx: mud_ctx}, %{})
    refute text =~ "the page continues"
    assert text =~ short_note
  end

  ## --- PIN (e): empty / missing ---

  test "PIN (e): a bot who never jotted anything lists no pages, honestly", ctx do
    {_prov, _sc, mud_ctx} = resolve_camillo(ctx)

    assert {:ok, "(no scratch pages yet)"} = ListScratch.call(%{mud_ctx: mud_ctx}, %{})
  end

  test "PIN (e): reading a page that doesn't exist is a gentle absent message, NOT an error",
       ctx do
    {_prov, _sc, mud_ctx} = resolve_camillo(ctx)

    # No scratch dir exists AT ALL yet.
    assert {:ok, text} = ReadScratch.call(%{mud_ctx: mud_ctx}, %{"page" => "nonexistent"})
    assert text =~ "no such page"

    # Seed the scratch dir (via a DIFFERENT page), then ask for one that
    # still doesn't exist within it.
    assert {:ok, _} = Scratch.call(%{mud_ctx: mud_ctx}, %{"note" => "seed", "page" => "todo"})
    assert {:ok, text2} = ReadScratch.call(%{mud_ctx: mud_ctx}, %{"page" => "nope"})
    assert text2 =~ "no such page"
  end

  test "PIN (e): an existing-but-never-written page reads as gently empty (not an error)", ctx do
    {_prov, _sc, mud_ctx} = resolve_camillo(ctx)

    # `Scratch.call/2` always writes non-empty text as part of creating a
    # page (get-or-create + append happen together), so an EXISTING but
    # still-empty page never arises from the tool itself — mint it directly
    # via NoteDoc, the same primitive `Scratch`'s own `ensure_page/2` uses,
    # to pin this branch of `read_scratch` honestly.
    assert {:ok, _page_uuid} =
             Commonplace.Bots.NoteDoc.ensure_zoned_dir(
               mud_ctx.home_room_uuid,
               "scratch",
               Jason.encode!(%{}),
               mud_ctx
             )
             |> then(fn {:ok, scratch_uuid} ->
               Commonplace.Bots.NoteDoc.ensure_zoned_dir(
                 scratch_uuid,
                 "blank",
                 Jason.encode!(%{"text" => ""}),
                 mud_ctx
               )
             end)

    assert {:ok, text} = ReadScratch.call(%{mud_ctx: mud_ctx}, %{"page" => "blank"})
    assert text =~ "is empty"
    refute text =~ "no such page"
  end

  ## --- Graceful no-ctx refusals ---

  test "no mud_ctx (unprovisioned) refuses gracefully for both tools", _ctx do
    assert {:error, "You are not in the world."} = ListScratch.call(%{mud_ctx: nil}, %{})

    assert {:error, "You are not in the world."} =
             ReadScratch.call(%{mud_ctx: nil}, %{"page" => "notes"})
  end

  test "no mud_ctx (state has no mud_ctx key at all)", _ctx do
    assert {:error, "You are not in the world."} = ListScratch.call(%{}, %{})
    assert {:error, "You are not in the world."} = ReadScratch.call(%{}, %{})
  end

  ## --- Registration sanity ---

  test "list_scratch and read_scratch are registered with the expected names/schemas", _ctx do
    assert ListScratch.name() == "list_scratch"
    assert ReadScratch.name() == "read_scratch"

    list_def = ListScratch.definition()
    assert list_def["name"] == "list_scratch"
    assert is_map(list_def["input_schema"])

    read_def = ReadScratch.definition()
    assert read_def["name"] == "read_scratch"
    assert is_map(read_def["input_schema"])
  end
end
