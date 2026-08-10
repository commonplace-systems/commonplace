defmodule Commonplace.CLI.ProcessTest do
  @moduledoc """
  Integration tests for `commonplace process remove <name>` (CX-didr).

  Drives the Process subcommand against a tmp-dir workspace with a
  hand-crafted `__processes.json` and asserts the named key is gone
  from the chained-commit head.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Document.ContentType
  alias Commonplace.Store.{CommitStore, CommitStoreClient}
  alias Commonplace.Tree.{DocBuilder, Schema}
  alias Yelixer.{Doc, Encoding}

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_cli_process_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    Application.put_env(:commonplace, :data_dir, dir)

    sup = Commonplace.Store.CommitStoreSupervisor
    _ = Supervisor.terminate_child(sup, Commonplace.Store.CommitStore)
    _ = Supervisor.delete_child(sup, Commonplace.Store.CommitStore)

    {:ok, _pid} =
      Supervisor.start_child(sup, {Commonplace.Store.CommitStore, data_dir: dir})

    Commonplace.Tree.DocCache.clear()

    on_exit(fn ->
      _ = Supervisor.terminate_child(sup, Commonplace.Store.CommitStore)
      _ = Supervisor.delete_child(sup, Commonplace.Store.CommitStore)
      Application.put_env(:commonplace, :data_dir, "tmp/test_data")

      {:ok, _pid} =
        Supervisor.start_child(sup, {Commonplace.Store.CommitStore, data_dir: "tmp/test_data"})

      Commonplace.Tree.DocCache.clear()
      File.rm_rf!(dir)
    end)

    %{data_dir: dir}
  end

  defp mint_doc(doc) do
    uuid = UUID.uuid4()
    update = Encoding.encode_update(doc)
    CommitStore.create_commit(CommitStore, uuid, update, nil)
    uuid
  end

  defp mint_processes_text(json_map) do
    body = Jason.encode!(json_map)
    doc = Doc.new() |> ContentType.create(:text, "__processes.json")
    doc = ContentType.insert_text(doc, 0, body)
    mint_doc(doc)
  end

  defp setup_workspace(data_dir, json_map) do
    Commonplace.Test.WorkspaceFixture.complete_workspace!(data_dir,
      store: Commonplace.Store.CommitStore
    )

    processes_uuid = mint_processes_text(json_map)

    root_doc =
      Schema.new_schema()
      |> Schema.add_file("__processes.json", processes_uuid)

    root_uuid = mint_doc(root_doc)
    File.write!(Path.join(data_dir, "root"), root_uuid)

    {root_uuid, processes_uuid}
  end

  defp read_processes_json(processes_uuid) do
    Commonplace.Tree.DocCache.clear()
    {:ok, doc} = DocBuilder.reconstruct_snapshot(CommitStoreClient, processes_uuid)
    ContentType.get_content(doc) |> Jason.decode!()
  end

  defp run_remove(data_dir, name) do
    test_pid = self()

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        code = Commonplace.CLI.Process.run(data_dir, "/", ["remove", name])
        send(test_pid, {:exit_code, code})
      end)

    receive do
      {:exit_code, code} -> %{output: output, exit: code}
    after
      500 -> %{output: output, exit: nil}
    end
  end

  describe "process remove" do
    test "removes a present entry, leaves siblings", %{data_dir: dir} do
      {_root, processes_uuid} =
        setup_workspace(dir, %{
          "alice" => %{"mode" => "elixir", "source" => "a.exs"},
          "bartleby" => %{"mode" => "command", "command" => "/bin/cat", "args" => []}
        })

      run_remove(dir, "bartleby")

      remaining = read_processes_json(processes_uuid)
      assert Map.keys(remaining) == ["alice"]
      assert remaining["alice"]["source"] == "a.exs"
    end

    test "removing a non-existent name is an idempotent no-op", %{data_dir: dir} do
      {_root, processes_uuid} =
        setup_workspace(dir, %{"alice" => %{"mode" => "elixir"}})

      run_remove(dir, "ghost")

      remaining = read_processes_json(processes_uuid)
      assert Map.keys(remaining) == ["alice"]
    end

    test "removes the last entry → empty map", %{data_dir: dir} do
      {_root, processes_uuid} =
        setup_workspace(dir, %{"alice" => %{"mode" => "elixir"}})

      run_remove(dir, "alice")

      remaining = read_processes_json(processes_uuid)
      assert remaining == %{}
    end

    test "preserves a sibling's nested config keys exactly", %{data_dir: dir} do
      {_root, processes_uuid} =
        setup_workspace(dir, %{
          "alice" => %{
            "mode" => "elixir",
            "source" => "a.exs",
            "depends_on" => ["beta", "gamma"],
            "env" => %{"FOO" => "bar"}
          },
          "delete-me" => %{"mode" => "command"}
        })

      run_remove(dir, "delete-me")

      remaining = read_processes_json(processes_uuid)
      assert remaining["alice"]["depends_on"] == ["beta", "gamma"]
      assert remaining["alice"]["env"] == %{"FOO" => "bar"}
    end

    test "missing __processes.json prints a friendly message", %{data_dir: dir} do
      Commonplace.Test.WorkspaceFixture.complete_workspace!(dir,
        store: Commonplace.Store.CommitStore
      )

      root_uuid = mint_doc(Schema.new_schema())
      File.write!(Path.join(dir, "root"), root_uuid)

      result = run_remove(dir, "alice")
      assert result.output =~ "No __processes.json"
    end
  end
end
