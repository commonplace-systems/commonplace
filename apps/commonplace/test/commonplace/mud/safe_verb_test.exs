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

      # CX-fhz4: the original body used a self-applying anonymous function
      # (`f.(f)`) — that shape is exactly what the AST allowlist's
      # `var.(...)` rejection closes (apply-in-disguise), so it no longer
      # compiles. A huge `Enum.each/2` range reaches the same "runs long
      # enough to be killed at the timeout" behavior using only
      # allowlisted surface.
      body = """
      Enum.each(1..1_000_000_000_000, fn _ -> :ok end)
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

      # CX-fhz4: the original body used a self-applying anonymous function
      # (`f.(f, ...)`) to explode the heap — that shape is exactly what the
      # AST allowlist's `var.(...)` rejection closes (apply-in-disguise), so
      # it no longer compiles. `List.duplicate/2` isn't on the allowlist
      # either (not an admitted `List` function), so `Enum.map/2` builds
      # the seed list instead; `Enum.reduce/3` over a small range with an
      # 8x-nesting accumulator reaches the same exponential blowup using
      # only allowlisted surface.
      body = """
      Enum.reduce(1..1000, Enum.map(1..100_000, fn _ -> 0 end), fn _, acc ->
        [acc, acc, acc, acc, acc, acc, acc, acc]
      end)
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

      # CX-fhz4: this body is now caught even earlier than a compile
      # error — `Commonplace.Store.CommitStoreClient` isn't on the AST
      # allowlist's admitted-module table, so `check_wrapped/1` refuses it
      # at save time, before it ever reaches the BEAM compiler. The
      # underlying guarantee this test is pinning (no leaked `store`/`ctx`
      # bindings — only `world`/`args` are ever in scope) still holds; it's
      # now enforced one layer earlier.
      assert {:error, {:unsafe_verb, {:disallowed, _reasons}}} =
               VerbSource.save_safe_verb(target_dir_uuid, "leaky", body, [target_dir_uuid], store)
    end

    # CX-qom0/CX-fhz4 confused-deputy keystone pin (the test the permissive
    # dogfood can't otherwise produce): the RUN boundary must re-verify the
    # STORED bytes, not trust the `.safe.elx` filename. Author a CLEAN safe
    # verb (passes save-time lint), then overwrite its stored doc via the
    # raw `write` tool — the exact non-@verb ingress an attacker uses — with
    # a well-formed substrate WRAPPER whose body calls System.cmd. Dispatch
    # must REFUSE it at compile (check_wrapped's inner-body allowlist),
    # never execute it.
    test "a dangerous body PLANTED into a stored safe verb (bypassing save-time lint) is refused at the run boundary",
         %{store: store, target_dir_uuid: target_dir_uuid} do
      :ok =
        VerbSource.save_safe_verb(
          target_dir_uuid,
          "tick",
          ~s|Commonplace.MUD.World.Facade.say(world, "ok")|,
          [target_dir_uuid],
          store
        )

      {:ok, source_uuid} = VerbSource.find_safe_source(target_dir_uuid, "tick", store)

      planted = """
      defmodule Commonplace.MUD.SafeVerbBody do
        def run(world, args) do
          System.cmd("id", [])
        end
      end
      """

      {:ok, _} = Commonplace.CommandRouter.write(source_uuid, planted, store: store)

      facade = Facade.new(%{}, target_dir_uuid, [target_dir_uuid], nil, store)

      # check_wrapped re-scans the stored body → System.cmd is disallowed →
      # refused before any BEAM compile / execution. NOT run.
      assert {:error, {:unsafe_verb, {:disallowed, _}}} =
               VerbSource.run_safe_verb(target_dir_uuid, "tick", [target_dir_uuid], facade, %{}, store)
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

  describe "CX-hqk5 stateful verbs — get_state / put_state" do
    test "put_state then get_state round-trips a scalar; missing key is nil", %{
      store: store,
      target_dir_uuid: dir
    } do
      f = Facade.new(%{}, dir, [dir], nil, store)

      assert :ok = Facade.put_state(f, "lit", true)
      assert Facade.get_state(f, "lit") == true

      assert :ok = Facade.put_state(f, "score", 7)
      assert Facade.get_state(f, "score") == 7

      assert Facade.get_state(f, "never_set") == nil
    end

    test "state lives in a dedicated submap and does NOT clobber typed fields", %{
      store: store,
      target_dir_uuid: dir
    } do
      f = Facade.new(%{}, dir, [dir], nil, store)
      {:ok, before} = Commonplace.MUD.World.get_object(dir, store)

      # A state key literally named "name" must not touch the typed name.
      assert :ok = Facade.put_state(f, "name", "hacked")

      {:ok, after_put} = Commonplace.MUD.World.get_object(dir, store)
      assert after_put.name == before.name
      assert Facade.get_state(f, "name") == "hacked"
    end

    test "bounds (CX-qexv): structured values OK; oversize/non-JSON/oversized-key/>64-keys → :state_bounds", %{
      store: store,
      target_dir_uuid: dir
    } do
      f = Facade.new(%{}, dir, [dir], nil, store)

      # CX-qexv — lists and string-keyed maps of JSON values now PERSIST.
      assert :ok = Facade.put_state(f, "list", [1, 2, 3])
      assert Facade.get_state(f, "list") == [1, 2, 3]
      assert :ok = Facade.put_state(f, "map", %{"a" => 1})
      assert Facade.get_state(f, "map") == %{"a" => 1}

      # ...but the total serialized value still can't exceed 1024 bytes,
      # and non-JSON shapes (tuple/atom/atom-keyed map) fail closed.
      assert {:error, :too_large} = Facade.put_state(f, "big", String.duplicate("x", 1025))
      assert {:error, :too_large} = Facade.put_state(f, "biglist", List.duplicate("xxxxxxxx", 200))
      assert {:error, :too_large} = Facade.put_state(f, "tuple", {1, 2})
      assert {:error, :too_large} = Facade.put_state(f, "atom", :nope)
      assert {:error, :too_large} = Facade.put_state(f, "atomkey", %{a: 1})
      assert {:error, :too_large} = Facade.put_state(f, String.duplicate("k", 65), "v")

      # Fill exactly 64 keys, then a 65th NEW key is refused...
      Enum.each(1..62, fn i -> assert :ok = Facade.put_state(f, "k#{i}", i) end)
      assert {:error, :too_large} = Facade.put_state(f, "k63", 1)
      # ...but UPDATING an existing key still works (no new key).
      assert :ok = Facade.put_state(f, "k1", 999)
    end

    test "put_state is owner-scoped (write outside the grant is denied)", %{
      store: store,
      target_dir_uuid: dir
    } do
      f = Facade.new(%{}, dir, [], nil, store)
      assert {:error, :refused} = Facade.put_state(f, "lit", true)
    end
  end

  describe "CX-9plf RNG — random / pick" do
    test "random returns 1..n; bad n → :bad_arg", %{store: store, target_dir_uuid: dir} do
      f = Facade.new(%{}, dir, [dir], nil, store)

      for _ <- 1..100 do
        r = Facade.random(f, 6)
        assert r in 1..6
      end

      assert Facade.random(f, 1) == 1
      assert {:error, :bad_arg} = Facade.random(f, 0)
      assert {:error, :bad_arg} = Facade.random(f, -3)
      assert {:error, :bad_arg} = Facade.random(f, "x")
    end

    test "pick returns a list element; nil on empty / non-list", %{store: store, target_dir_uuid: dir} do
      f = Facade.new(%{}, dir, [dir], nil, store)

      assert Facade.pick(f, [:only]) == :only
      assert Facade.pick(f, ["a", "b", "c"]) in ["a", "b", "c"]
      assert Facade.pick(f, []) == nil
      assert Facade.pick(f, "not a list") == nil
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
