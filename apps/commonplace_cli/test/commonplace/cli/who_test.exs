defmodule Commonplace.CLI.WhoTest do
  @moduledoc """
  Tests for the `commonplace who` CLI command.
  """
  use ExUnit.Case

  import ExUnit.CaptureIO

  alias Commonplace.Tree.Schema
  alias Commonplace.Store.CommitStore
  alias Commonplace.Presence
  alias Commonplace.Presence.Identity

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_who_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    store_name = :"commit_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store_name})
    on_exit(fn -> File.rm_rf!(dir) end)

    # Create a root schema
    root_uuid = UUID.uuid4()
    root_doc = Schema.new_schema()
    update = Yelixer.Encoding.encode_update(root_doc)
    CommitStore.create_commit(store_name, root_uuid, update, nil)

    %{store: store_name, root: root_uuid}
  end

  describe "who output" do
    test "lists all actors with type indicators", %{store: store, root: root} do
      Presence.create("sync", :exe, root, store)
      Presence.create("jes", :usr, root, store)
      Presence.create("claude", :bot, root, store)

      output =
        capture_io(fn ->
          Commonplace.CLI.Who.run_with_store(root, store)
        end)

      assert output =~ "sync.exe"
      assert output =~ "jes.usr"
      assert output =~ "claude.bot"
    end

    test "filters by type", %{store: store, root: root} do
      Presence.create("alpha", :exe, root, store)
      Presence.create("beta", :exe, root, store)
      Presence.create("jes", :usr, root, store)

      output =
        capture_io(fn ->
          Commonplace.CLI.Who.run_with_store(root, store, ["--type", "exe"])
        end)

      assert output =~ "alpha.exe"
      assert output =~ "beta.exe"
      refute output =~ "jes.usr"
    end

    test "shows cold identities with --all flag", %{store: store, root: root} do
      # Register a cold identity (no hot presence)
      Identity.register("oldprocess", :exe, root, store)

      output =
        capture_io(fn ->
          Commonplace.CLI.Who.run_with_store(root, store, ["--all"])
        end)

      assert output =~ "oldprocess.exe"
    end

    test "shows empty message when no actors", %{store: store, root: root} do
      output =
        capture_io(fn ->
          Commonplace.CLI.Who.run_with_store(root, store)
        end)

      assert output =~ "No actors"
    end
  end
end
