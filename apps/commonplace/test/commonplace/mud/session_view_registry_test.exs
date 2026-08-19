defmodule Commonplace.MUD.SessionViewRegistryTest do
  @moduledoc """
  CX-i9j3 (UI Inc-1 increment 4): pins `SessionViewRegistry`'s basic
  get/put contract, plus a round-trip proof that a `put` uuid can be
  `SessionView.load/2`'d back into an equivalent transcript — the same
  path `MudLive.mount_authed/2` relies on for reconnect-persistence.

  The registry is started once, globally named, by
  `Commonplace.Application`'s supervision tree (it's already running
  under the test app), so these tests exercise the SAME live process
  MudLive talks to — each test uses a fresh random `identity_uuid` key
  to avoid cross-test collisions in that shared map.
  """
  use ExUnit.Case, async: false

  alias Commonplace.MUD.{SessionView, SessionViewRegistry}

  describe "get/2 and put/2" do
    test "get of an unknown identity returns nil" do
      assert SessionViewRegistry.get(UUID.uuid4()) == nil
    end

    test "put then get returns the stored view_uuid" do
      identity_uuid = UUID.uuid4()
      view_uuid = UUID.uuid4()

      assert :ok = SessionViewRegistry.put(identity_uuid, view_uuid)
      assert SessionViewRegistry.get(identity_uuid) == view_uuid
    end

    test "put overwrites a prior value for the same identity" do
      identity_uuid = UUID.uuid4()

      :ok = SessionViewRegistry.put(identity_uuid, UUID.uuid4())
      :ok = SessionViewRegistry.put(identity_uuid, "second-view-uuid")

      assert SessionViewRegistry.get(identity_uuid) == "second-view-uuid"
    end
  end

  describe "registry uuid -> SessionView.load/2 round trip" do
    setup do
      dir =
        Path.join(System.tmp_dir!(), "cp_session_view_registry_#{:rand.uniform(1_000_000_000)}")

      File.mkdir_p!(dir)
      n = :rand.uniform(1_000_000_000)
      store = :"session_view_registry_store_#{n}"

      start_supervised!(
        {Commonplace.Store.Supervisor,
         data_dir: dir,
         name: :"session_view_registry_sup_#{n}",
         commit_store_name: store,
         trust_side_store_name: :"session_view_registry_tss_#{n}",
         pending_imports_name: :"session_view_registry_pi_#{n}"}
      )

      old_data_dir = Application.get_env(:commonplace, :data_dir)
      Application.put_env(:commonplace, :data_dir, dir)

      on_exit(fn ->
        Application.put_env(:commonplace, :data_dir, old_data_dir || "tmp/test_data")

        File.rm_rf!(dir)
      end)

      %{store: store}
    end

    test "a registered view_uuid reloads via SessionView.load/2 with the appended turn intact", %{
      store: store
    } do
      identity_uuid = UUID.uuid4()

      view = SessionView.new(identity_uuid, store)
      view = SessionView.append_command_turn(view, "look", "You see a room.")

      :ok = SessionViewRegistry.put(identity_uuid, view.uuid)

      remembered_uuid = SessionViewRegistry.get(identity_uuid)
      assert remembered_uuid == view.uuid

      assert {:ok, loaded} = SessionView.load(remembered_uuid, store)
      assert SessionView.to_html(loaded) == SessionView.to_html(view)
      assert SessionView.to_html(loaded) =~ "You see a room."
    end
  end
end
