defmodule Commonplace.MUD.SafeVerbTest do
  @moduledoc """
  CX-ndvi §3/§4/§6 pins 4, 5, 7, 8 — lint rejection, execution bounds
  (timeout + heap-kill), the no-leaked-bindings structural proof, and
  the legacy-vs-safe authoring boundary (both paths compile+run,
  neither regresses the other).
  """
  use ExUnit.Case, async: false

  alias Commonplace.Code.SourceDoc
  alias Commonplace.MUD.SafeVerb.Lint
  alias Commonplace.MUD.World.Facade
  alias Commonplace.MUD.{Schemas, VerbSource}
  alias Commonplace.Store.CommitStoreClient

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_safe_verb_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    Application.put_env(:commonplace, :data_dir, dir)

    sup = Commonplace.Store.CommitStoreSupervisor
    _ = Supervisor.terminate_child(sup, Commonplace.Store.CommitStore)
    _ = Supervisor.delete_child(sup, Commonplace.Store.CommitStore)

    {:ok, _pid} = Supervisor.start_child(sup, {Commonplace.Store.CommitStore, data_dir: dir})

    Commonplace.Tree.DocCache.clear()
    SourceDoc.reset_cache()

    on_exit(fn ->
      _ = Supervisor.terminate_child(sup, Commonplace.Store.CommitStore)
      _ = Supervisor.delete_child(sup, Commonplace.Store.CommitStore)
      Application.put_env(:commonplace, :data_dir, "tmp/test_data")
      {:ok, _pid} = Supervisor.start_child(sup, {Commonplace.Store.CommitStore, data_dir: "tmp/test_data"})
      Commonplace.Tree.DocCache.clear()
      SourceDoc.reset_cache()
      File.rm_rf!(dir)
    end)

    {:ok, target_dir_uuid} =
      Schemas.create_dir_with_meta(
        Schemas.object_filename(),
        Schemas.encode_object(%Schemas.Object{name: "host", description: "a verb host"}),
        CommitStoreClient
      )

    %{store: CommitStoreClient, target_dir_uuid: target_dir_uuid}
  end

  describe "Lint v1 (pin 4)" do
    test "clean body passes" do
      assert :ok = Lint.check("world")
    end

    test "rejects apply/2" do
      assert {:error, {:lint_violation, reasons}} = Lint.check("apply(Kernel, :self, [])")
      assert Enum.any?(reasons, &(&1 =~ "apply"))
    end

    test "rejects spawn" do
      assert {:error, {:lint_violation, reasons}} = Lint.check("spawn(fn -> :ok end)")
      assert Enum.any?(reasons, &(&1 =~ "spawn"))
    end

    test "rejects Process module reference" do
      assert {:error, {:lint_violation, reasons}} = Lint.check("Process.sleep(1)")
      assert Enum.any?(reasons, &(&1 =~ "Process"))
    end

    test "rejects Task module reference" do
      assert {:error, {:lint_violation, reasons}} = Lint.check("Task.async(fn -> :ok end)")
      assert Enum.any?(reasons, &(&1 =~ "Task"))
    end

    test "rejects String.to_atom" do
      assert {:error, {:lint_violation, reasons}} = Lint.check(~s|String.to_atom("evil")|)
      assert Enum.any?(reasons, &(&1 =~ "to_atom"))
    end

    test "rejects File module reference" do
      assert {:error, {:lint_violation, reasons}} = Lint.check(~s|File.read!("/etc/passwd")|)
      assert Enum.any?(reasons, &(&1 =~ "File"))
    end

    test "rejects System module reference" do
      assert {:error, {:lint_violation, reasons}} = Lint.check(~s|System.cmd("ls", [])|)
      assert Enum.any?(reasons, &(&1 =~ "System"))
    end

    test "rejects Code module reference" do
      assert {:error, {:lint_violation, reasons}} = Lint.check(~s|Code.eval_string("1+1")|)
      assert Enum.any?(reasons, &(&1 =~ "Code"))
    end

    test "rejects Node module reference" do
      assert {:error, {:lint_violation, reasons}} = Lint.check("Node.list()")
      assert Enum.any?(reasons, &(&1 =~ "Node"))
    end

    test "rejects raw :os calls" do
      assert {:error, {:lint_violation, reasons}} = Lint.check(~s|:os.cmd(~c"ls")|)
      assert Enum.any?(reasons, &(&1 =~ ":os"))
    end

    test "rejects defmodule (authors write a body, not a module)" do
      assert {:error, {:lint_violation, reasons}} =
               Lint.check("defmodule Sneaky do\n  def run(_w, _a), do: :ok\nend\n")

      assert Enum.any?(reasons, &(&1 =~ "defmodule"))
    end

    test "save_safe_verb refuses a lint-dirty body BEFORE writing anything", %{
      store: store,
      target_dir_uuid: target_dir_uuid
    } do
      assert {:error, {:lint_violation, _}} =
               VerbSource.save_safe_verb(target_dir_uuid, "evil", "File.rm_rf!(\"/\")", [target_dir_uuid], store)

      assert :not_found = VerbSource.find_safe_source(target_dir_uuid, "evil", store)
    end
  end

  describe "execution bounds (pin 5)" do
    test "an infinite-loop verb is killed at the timeout; the caller survives", %{
      store: store,
      target_dir_uuid: target_dir_uuid
    } do
      Application.put_env(:commonplace, :safe_verb_timeout_ms, 100)
      on_exit(fn -> Application.delete_env(:commonplace, :safe_verb_timeout_ms) end)

      body = """
      loop = fn f -> f.(f) end
      loop.(loop)
      """

      assert :ok = VerbSource.save_safe_verb(target_dir_uuid, "spin", body, [target_dir_uuid], store)

      facade = Facade.new(%{}, target_dir_uuid, [target_dir_uuid], nil, store)

      assert {:error, :timeout} =
               VerbSource.run_safe_verb(target_dir_uuid, "spin", [target_dir_uuid], facade, %{}, store)

      # The caller (this test process) is alive and the store is
      # responsive — the bounded Task's death didn't take anything else
      # down with it.
      assert Process.alive?(self())
      assert {:ok, _} = CommitStoreClient.latest_commit(store, target_dir_uuid)
    end

    test "a memory-bomb verb is heap-killed; the caller survives", %{
      store: store,
      target_dir_uuid: target_dir_uuid
    } do
      Application.put_env(:commonplace, :safe_verb_max_heap_bytes, 1024 * 1024)
      on_exit(fn -> Application.delete_env(:commonplace, :safe_verb_max_heap_bytes) end)

      body = """
      grow = fn f, acc -> f.(f, [acc, acc, acc, acc, acc, acc, acc, acc]) end
      grow.(grow, List.duplicate(0, 100_000))
      """

      assert :ok = VerbSource.save_safe_verb(target_dir_uuid, "bomb", body, [target_dir_uuid], store)

      facade = Facade.new(%{}, target_dir_uuid, [target_dir_uuid], nil, store)

      assert {:error, {:runtime_error, _}} =
               VerbSource.run_safe_verb(target_dir_uuid, "bomb", [target_dir_uuid], facade, %{}, store)

      assert Process.alive?(self())
      assert {:ok, _} = CommitStoreClient.latest_commit(store, target_dir_uuid)
    end
  end

  describe "no effect surface leak — structural proof (pin 7)" do
    test "a safe-verb body referencing `store`/`ctx` fails to compile (undefined variable) — only `world`/`args` are bound",
         %{store: store, target_dir_uuid: target_dir_uuid} do
      body = "Commonplace.Store.CommitStoreClient.commit_log(store, ctx.object_uuid)"

      assert {:error, {:compile_error, _msg}} =
               VerbSource.save_safe_verb(target_dir_uuid, "leaky", body, [target_dir_uuid], store)
    end

    test "a clean safe verb only ever sees world/args and can call the facade", %{
      store: store,
      target_dir_uuid: target_dir_uuid
    } do
      body = "Commonplace.MUD.World.Facade.set_attr(world, \"poked_by\", Map.get(args, \"who\", \"someone\"))"

      assert :ok = VerbSource.save_safe_verb(target_dir_uuid, "poke", body, [target_dir_uuid], store)

      facade = Facade.new(%{}, target_dir_uuid, [target_dir_uuid], {"verbs/poke.safe.elx", "owner"}, store)

      assert {:ok, :ok} =
               VerbSource.run_safe_verb(target_dir_uuid, "poke", [target_dir_uuid], facade, %{"who" => "alice"}, store)
    end
  end

  describe "legacy vs. safe authoring boundary (pin 8)" do
    test "the legacy full-defmodule path still compiles+runs unchanged (no regression)", %{
      store: store,
      target_dir_uuid: target_dir_uuid
    } do
      src = """
      defmodule Commonplace.UserCode.Mud.Verb.LegacyBow do
        def run(_ctx), do: :legacy_ok
      end
      """

      assert :ok = VerbSource.save_verb(target_dir_uuid, "bow", src, store)
      assert {:ok, mod} = VerbSource.compile_verb(target_dir_uuid, "bow", store)
      assert mod.run(%{}) == :legacy_ok
      assert {:ok, :legacy_ok} = VerbSource.run_verb(target_dir_uuid, "bow", %{}, store)
    end

    test "legacy (<name>.elx) and safe (<name>.safe.elx) verbs coexist under the SAME verb name without colliding", %{
      store: store,
      target_dir_uuid: target_dir_uuid
    } do
      legacy_src = """
      defmodule Commonplace.UserCode.Mud.Verb.DualLegacy do
        def run(_ctx), do: :from_legacy
      end
      """

      safe_body = ":from_safe"

      assert :ok = VerbSource.save_verb(target_dir_uuid, "dual", legacy_src, store)
      assert :ok = VerbSource.save_safe_verb(target_dir_uuid, "dual", safe_body, [target_dir_uuid], store)

      assert {:ok, :from_legacy} = VerbSource.run_verb(target_dir_uuid, "dual", %{}, store)

      facade = Facade.new(%{}, target_dir_uuid, [target_dir_uuid], nil, store)
      assert {:ok, :from_safe} = VerbSource.run_safe_verb(target_dir_uuid, "dual", [target_dir_uuid], facade, %{}, store)
    end

    test "the safe path is gated on :define_verb, not :execute — a define-denied contributor's safe verb is refused",
         %{store: store, target_dir_uuid: target_dir_uuid} do
      alias Commonplace.Crypto.{Signing, SigningContext}

      Application.put_env(:commonplace, :trust, %{accept_unsigned: false, trusted_identities: %{}})
      on_exit(fn -> Application.delete_env(:commonplace, :trust) end)

      {pub, priv} = Signing.generate_keypair()
      identity = "sv-#{:rand.uniform(999_999_999_999)}"
      ctx = %SigningContext{identity_uuid: identity, private_key: priv, public_key: pub}

      assert {:error, {:execution_denied, _}} =
               VerbSource.save_safe_verb(target_dir_uuid, "denied", ":ok", [target_dir_uuid], store,
                 signing_context: ctx
               )
    end
  end
end
