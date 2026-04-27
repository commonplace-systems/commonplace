defmodule Commonplace.View.ComputeRunnerTest do
  @moduledoc """
  CX-b52t (sub-bead i of CX-a9cv M7): substrate-tier compute caller.

  Reads an Elixir source-doc, compiles via Commonplace.Code.SourceDoc,
  and calls `module.compute(raw, ctx)`. Replaces M5 ComputeSpec for
  the compute layer.

  Tests cover compute/4 happy path + validate/2 + error paths +
  Wallaby anchor T (non-chat synthetic Elixir compute) which proves
  substrate domain-agnosticism.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Code.SourceDoc
  alias Commonplace.Document.ContentType
  alias Commonplace.Store.{CommitStore, CommitStoreClient}
  alias Commonplace.View.ComputeRunner

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_compute_runner_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    Application.put_env(:commonplace, :data_dir, dir)

    sup = Commonplace.Store.CommitStoreSupervisor
    _ = Supervisor.terminate_child(sup, Commonplace.Store.CommitStore)
    _ = Supervisor.delete_child(sup, Commonplace.Store.CommitStore)

    {:ok, _pid} =
      Supervisor.start_child(sup, {Commonplace.Store.CommitStore, data_dir: dir})

    Commonplace.Tree.DocCache.clear()
    SourceDoc.reset_cache()

    on_exit(fn ->
      _ = Supervisor.terminate_child(sup, Commonplace.Store.CommitStore)
      _ = Supervisor.delete_child(sup, Commonplace.Store.CommitStore)
      Application.put_env(:commonplace, :data_dir, "tmp/test_data")

      {:ok, _pid} =
        Supervisor.start_child(sup, {Commonplace.Store.CommitStore, data_dir: "tmp/test_data"})

      Commonplace.Tree.DocCache.clear()
      SourceDoc.reset_cache()
      File.rm_rf!(dir)
    end)

    %{store: CommitStoreClient}
  end

  defp mint_compute_doc(source_string) do
    uuid = UUID.uuid4()
    doc = Yelixer.Doc.new()
    doc = ContentType.create(doc, :text, "_compute")
    doc = ContentType.insert_text(doc, 0, source_string)
    update = Yelixer.Encoding.encode_update(doc)
    CommitStore.create_commit(Commonplace.Store.CommitStore, uuid, update, nil)
    uuid
  end

  describe "compute/4 — happy path" do
    test "compiles + calls compute(raw, ctx); returns the fn's result", %{store: store} do
      source = ~S"""
      defmodule Cp.Test.M7Happy do
        def compute(raw, ctx) do
          "got #{length(raw)} entries for #{ctx.label}"
        end
      end
      """

      uuid = mint_compute_doc(source)

      assert {:ok, "got 3 entries for hello"} =
               ComputeRunner.compute(uuid, [:a, :b, :c], %{label: "hello"}, store)
    end

    test "subsequent calls hit SourceDoc cache (same content_hash)", %{store: store} do
      source = """
      defmodule Cp.Test.M7Cache do
        def compute(_raw, _ctx), do: :cached
      end
      """

      uuid = mint_compute_doc(source)

      assert {:ok, :cached} = ComputeRunner.compute(uuid, [], %{}, store)
      assert {:ok, :cached} = ComputeRunner.compute(uuid, [], %{}, store)
    end
  end

  describe "validate/2" do
    test "succeeds when compute/2 exported", %{store: store} do
      source = """
      defmodule Cp.Test.M7Valid do
        def compute(_raw, _ctx), do: :ok
      end
      """

      uuid = mint_compute_doc(source)
      assert :ok = ComputeRunner.validate(uuid, store)
    end

    test "fails when compute/2 missing", %{store: store} do
      source = """
      defmodule Cp.Test.M7NoCompute do
        def something_else(_a, _b), do: :nope
      end
      """

      uuid = mint_compute_doc(source)

      assert {:error, reason} = ComputeRunner.validate(uuid, store)
      assert reason =~ "compute/2 not exported"
    end

    test "fails when compute/2 has wrong arity", %{store: store} do
      source = """
      defmodule Cp.Test.M7WrongArity do
        def compute(only_one_arg), do: :wrong
      end
      """

      uuid = mint_compute_doc(source)
      assert {:error, _reason} = ComputeRunner.validate(uuid, store)
    end
  end

  describe "compute/4 — error paths" do
    test "compile error surfaces as {:error, _}", %{store: store} do
      bad_source = "defmodule Broken do\n  def compute(a, b), do:"
      uuid = mint_compute_doc(bad_source)

      assert {:error, _} = ComputeRunner.compute(uuid, [], %{}, store)
    end

    test "missing compute/2 surfaces as {:error, _} from compute/4", %{store: store} do
      source = """
      defmodule Cp.Test.M7MissingCompute do
        def hi, do: :hi
      end
      """

      uuid = mint_compute_doc(source)

      assert {:error, reason} = ComputeRunner.compute(uuid, [], %{}, store)
      assert reason =~ "compute/2"
    end

    test "code-doc not found returns {:error, :not_found}", %{store: store} do
      assert {:error, :not_found} = ComputeRunner.compute(UUID.uuid4(), [], %{}, store)
    end
  end

  describe "Anchor T — non-chat synthetic Elixir compute (substrate domain-agnosticism)" do
    test "arbitrary Elixir compute fn drives ComputeRunner end-to-end", %{store: store} do
      # Synthetic compute fn: a "task summary" that has nothing to do
      # with chat. Proves ComputeRunner is substrate-tier, domain-agnostic.
      source = """
      defmodule Cp.Test.M7TaskSummary do
        def compute(raw, ctx) do
          owner = Map.get(ctx, :owner, "unknown")

          tasks =
            raw
            |> Enum.map(&Jason.decode!/1)
            |> Enum.filter(fn t -> t["owner"] == owner end)
            |> Enum.map(& &1["title"])

          %{owner: owner, count: length(tasks), titles: tasks}
        end
      end
      """

      uuid = mint_compute_doc(source)

      raw = [
        Jason.encode!(%{"id" => "t1", "title" => "A", "owner" => "alice"}),
        Jason.encode!(%{"id" => "t2", "title" => "B", "owner" => "bob"}),
        Jason.encode!(%{"id" => "t3", "title" => "C", "owner" => "alice"})
      ]

      assert {:ok, result} =
               ComputeRunner.compute(uuid, raw, %{owner: "alice"}, store)

      assert result.owner == "alice"
      assert result.count == 2
      assert "A" in result.titles
      assert "C" in result.titles
      refute "B" in result.titles
    end
  end
end
