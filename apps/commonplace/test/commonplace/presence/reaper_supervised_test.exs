defmodule Commonplace.Presence.ReaperSupervisedTest do
  @moduledoc """
  Verifies that the Presence.Reaper is wired into the application
  supervision tree (via `Commonplace.Application.presence_reaper_children/0`)
  and actually reaps stale presence entries when started.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Application, as: CApp
  alias Commonplace.Presence
  alias Commonplace.Presence.Reaper
  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.Schema

  describe "presence_reaper_children/0" do
    setup do
      prior = Application.get_env(:commonplace, :data_dir)

      on_exit(fn ->
        Application.put_env(:commonplace, :data_dir, prior || "tmp/test_data")
      end)

      :ok
    end

    test "returns [] when no workspace root is configured" do
      dir = Path.join(System.tmp_dir!(), "cp_reaper_sup_noroot_#{:rand.uniform(1_000_000)}")
      File.mkdir_p!(dir)
      Application.put_env(:commonplace, :data_dir, dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      assert CApp.presence_reaper_children() == []
    end

    test "returns a supervisor child_spec when a workspace root is configured" do
      dir = Path.join(System.tmp_dir!(), "cp_reaper_sup_root_#{:rand.uniform(1_000_000)}")
      File.mkdir_p!(dir)
      uuid = "11111111-2222-3333-4444-555555555555"
      File.write!(Path.join(dir, "root"), uuid)
      Application.put_env(:commonplace, :data_dir, dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      assert [spec] = CApp.presence_reaper_children()
      assert spec.id == Commonplace.Presence.ReaperSupervisor
      assert spec.type == :supervisor
    end
  end

  describe "workspace reroot (CX-4wl)" do
    setup do
      prior_data_dir = Application.get_env(:commonplace, :data_dir)
      dir = Path.join(System.tmp_dir!(), "cp_reaper_reroot_#{:rand.uniform(1_000_000)}")
      File.mkdir_p!(dir)
      Application.put_env(:commonplace, :data_dir, dir)

      store_name = :"commit_store_reroot_#{:rand.uniform(1_000_000)}"
      start_supervised!({CommitStore, data_dir: dir, name: store_name})
      Commonplace.Test.WorkspaceFixture.complete_workspace!(dir, store: store_name)

      on_exit(fn ->
        Application.put_env(:commonplace, :data_dir, prior_data_dir || "tmp/test_data")

        File.rm_rf!(dir)
      end)

      %{dir: dir, store: store_name}
    end

    test "reaper follows <data_dir>/root rewrite without restart",
         %{dir: dir, store: store} do
      # Initial workspace root
      root_a = UUID.uuid4()
      root_doc_a = Schema.new_schema()
      update = Yelixer.Encoding.encode_update(root_doc_a)
      CommitStore.create_commit(store, root_a, update, nil)
      File.write!(Path.join(dir, "root"), root_a)

      # Start reaper WITHOUT a static :root_uuid — it must consult
      # Workspace.root_uuid/0 each scan. Short interval keeps the test
      # quick.
      sup_name = :"reaper_reroot_sup_#{:rand.uniform(1_000_000)}"

      {:ok, _sup} =
        Supervisor.start_link(
          [
            {Reaper, [store: store, interval: 50, stale_threshold: 30_000]}
          ],
          strategy: :one_for_one,
          name: sup_name
        )

      # Reroot the workspace to a different root_uuid mid-flight.
      root_b = UUID.uuid4()
      root_doc_b = Schema.new_schema()
      update = Yelixer.Encoding.encode_update(root_doc_b)
      CommitStore.create_commit(store, root_b, update, nil)
      File.write!(Path.join(dir, "root"), root_b)

      # Plant a stale presence entry under the NEW root.
      {:ok, _uuid} = Presence.create("ghost", :exe, root_b, store)

      root_doc_after = load_schema(root_b, store)
      {:ok, entry} = Schema.get_entry(root_doc_after, "ghost.exe")

      old_time = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.to_iso8601()
      doc = load_doc(entry.node_id, store)
      doc = Commonplace.Document.ContentType.set_key(doc, "heartbeat", old_time)
      update = Yelixer.Encoding.encode_update(doc)
      CommitStore.create_commit(store, entry.node_id, update, nil)

      # Poll up to 5s for the reaper to follow the reroot and reap the
      # stale entry from root_b. Pre-fix, the reaper was pinned to root_a
      # and never noticed root_b's stale entry.
      deadline = System.monotonic_time(:millisecond) + 5_000

      reaped? =
        Stream.repeatedly(fn ->
          Process.sleep(50)

          case Schema.get_entry(load_schema(root_b, store), "ghost.exe") do
            :error -> true
            {:ok, _} -> false
          end
        end)
        |> Enum.reduce_while(false, fn gone?, _acc ->
          cond do
            gone? -> {:halt, true}
            System.monotonic_time(:millisecond) > deadline -> {:halt, false}
            true -> {:cont, false}
          end
        end)

      Supervisor.stop(sup_name)

      assert reaped?,
             "reaper did not pick up the workspace reroot — stale entry under new root remained"
    end
  end

  describe "end-to-end reaping under supervision" do
    setup do
      dir = Path.join(System.tmp_dir!(), "cp_reaper_supervised_#{:rand.uniform(1_000_000)}")
      File.mkdir_p!(dir)
      store_name = :"commit_store_reaper_sup_#{:rand.uniform(1_000_000)}"
      start_supervised!({CommitStore, data_dir: dir, name: store_name})
      on_exit(fn -> File.rm_rf!(dir) end)

      root_uuid = UUID.uuid4()
      root_doc = Schema.new_schema()
      update = Yelixer.Encoding.encode_update(root_doc)
      CommitStore.create_commit(store_name, root_uuid, update, nil)

      %{root: root_uuid, store: store_name}
    end

    test "stale entries are removed within 30s by supervised reaper", %{
      root: root,
      store: store
    } do
      # Plant a presence entry with a stale heartbeat.
      {:ok, _uuid} = Presence.create("dead-proc", :exe, root, store)

      root_doc = load_schema(root, store)
      {:ok, entry} = Schema.get_entry(root_doc, "dead-proc.exe")

      old_time =
        DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.to_iso8601()

      doc = load_doc(entry.node_id, store)
      doc = Commonplace.Document.ContentType.set_key(doc, "heartbeat", old_time)
      update = Yelixer.Encoding.encode_update(doc)
      CommitStore.create_commit(store, entry.node_id, update, nil)

      # Start the reaper under a supervisor (as the application does).
      # Short interval (50 ms) so the test finishes quickly while still
      # exercising the same code path as the production config.
      sup_name = :"reaper_sup_#{:rand.uniform(1_000_000)}"

      {:ok, _sup} =
        Supervisor.start_link(
          [
            {Reaper,
             [
               root_uuid: root,
               store: store,
               interval: 50,
               stale_threshold: 30_000
             ]}
          ],
          strategy: :one_for_one,
          name: sup_name
        )

      # Poll for up to 30s (the acceptance threshold) for the stale entry
      # to be reaped. In practice with interval=50ms it completes in <1s.
      deadline = System.monotonic_time(:millisecond) + 30_000

      reaped? =
        Stream.repeatedly(fn ->
          Process.sleep(50)

          case Schema.get_entry(load_schema(root, store), "dead-proc.exe") do
            :error -> true
            {:ok, _} -> false
          end
        end)
        |> Enum.reduce_while(false, fn gone?, _acc ->
          cond do
            gone? -> {:halt, true}
            System.monotonic_time(:millisecond) > deadline -> {:halt, false}
            true -> {:cont, false}
          end
        end)

      assert reaped?, "stale presence entry was not reaped within 30s"

      Supervisor.stop(sup_name)
    end
  end

  defp load_schema(uuid, store) do
    case CommitStore.latest_commit(store, uuid) do
      {:ok, commit} ->
        doc = Schema.new_schema()
        {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)
        doc

      :none ->
        Schema.new_schema()
    end
  end

  defp load_doc(uuid, store) do
    case CommitStore.latest_commit(store, uuid) do
      {:ok, commit} ->
        doc = Yelixer.Doc.new()
        {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)
        doc

      :none ->
        Yelixer.Doc.new()
    end
  end
end
