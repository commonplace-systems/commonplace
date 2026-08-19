defmodule Commonplace.MUD.SafeVerb.AllowlistTest do
  use ExUnit.Case, async: true

  alias Commonplace.MUD.SafeVerb.Allowlist

  defp assert_rejected(body) do
    assert {:error, {:disallowed, reasons}} = Allowlist.check(body)
    assert reasons != []
    reasons
  end

  describe "merge-blocker pins" do
    test "(a) OS/file escape hatches are rejected" do
      assert_rejected(~s|System.cmd("id", [])|)
      assert_rejected(~s|File.read("/etc/passwd")|)
      assert_rejected(~s|:os.cmd(~c"id")|)
    end

    test "(b) bare and Kernel-qualified apply are rejected" do
      assert_rejected("apply(m, f, a)")
      assert_rejected("Kernel.apply(m, f, a)")
    end

    test "(c) computed-atom module dispatch is rejected (both halves)" do
      reasons = assert_rejected(~s|mod = String.to_atom("Sys" <> "tem")\nmod.cmd("id")|)
      assert Enum.any?(reasons, &String.contains?(&1, "to_atom"))
      assert Enum.any?(reasons, &String.contains?(&1, "dynamic dispatch"))
    end

    test "(d) &System.cmd/2 capture is rejected" do
      assert_rejected("&System.cmd/2")
    end

    test "(e) :erlang.binary_to_term is rejected" do
      assert_rejected(":erlang.binary_to_term(bin)")
    end

    test "(f) the dot-call-with-args form world.foo(...) is rejected (crashes at runtime; use the qualified facade form)" do
      assert_rejected(~s|world.look("here")|)
      assert_rejected("world.emote(args)")
    end

    test "(f0) world.field (no-parens field read) is still allowed" do
      assert :ok == Allowlist.check("world.object_uuid")
    end

    test "(g) rebinding world is refused even though the dispatch itself would pass" do
      assert_rejected("world = System\nworld.cmd(\"id\", [])")
    end

    # CX-fhz4 wiring fix — `world.foo(...)` (struct dot-call WITH args) is
    # not valid Elixir dispatch (it always crashes at runtime: `world` is a
    # struct, not a module atom). The calling convention every safe verb
    # actually uses is the qualified form. Confirms the facade carve
    # extends to it, ONLY when `world` is the literal first argument.
    test "(f2) Commonplace.MUD.World.Facade.<fun>(world, ...) passes when world is the literal first arg" do
      assert :ok == Allowlist.check(~s|Commonplace.MUD.World.Facade.set_attr(world, "k", "v")|)
      # CX-cj3t.9 — the move SPLIT: move_object + move_self are admitted...
      assert :ok ==
               Allowlist.check(~s|Commonplace.MUD.World.Facade.move_object(world, "dest-uuid")|)

      assert :ok ==
               Allowlist.check(~s|Commonplace.MUD.World.Facade.move_self(world, "dest-uuid")|)

      # ...and the retired ambiguous {:move,2} now FAILS CLOSED (unknown verb).
      assert {:error, _} =
               Allowlist.check(~s|Commonplace.MUD.World.Facade.move(world, "dest-uuid")|)
    end

    # CX-aw4r — the attributed-action primitive is admitted (plan #5955).
    test "(f5) Facade.emit_action/3 passes; Facade.new/5 and unlisted facade fns still reject" do
      assert :ok ==
               Allowlist.check(
                 ~s|Commonplace.MUD.World.Facade.emit_action(world, "lift the lid", "lifts the lid")|
               )

      # actor_name/actor_ref are NOW admitted (CX-a2gd, pinned in (f9)); the
      # constructor and any genuinely-unlisted fn still reject.
      assert_rejected(~s|Commonplace.MUD.World.Facade.new(world, "x", [], nil, world)|)
      assert_rejected(~s|Commonplace.MUD.World.Facade.signer_material(world)|)
    end

    # CX-hqk5 — the stateful-verb primitives are admitted (plan #5968).
    test "(f6) Facade.get_state/2 + put_state/3 pass" do
      assert :ok == Allowlist.check(~s|Commonplace.MUD.World.Facade.get_state(world, "lit")|)

      assert :ok ==
               Allowlist.check(~s|Commonplace.MUD.World.Facade.put_state(world, "lit", true)|)
    end

    # CX-9plf — RNG primitives admitted; raw Enum.random/:rand still banned.
    test "(f7) Facade.random/2 + pick/2 pass; raw Enum.random / :rand stay rejected" do
      assert :ok == Allowlist.check(~s|Commonplace.MUD.World.Facade.random(world, 6)|)
      assert :ok == Allowlist.check(~s|Commonplace.MUD.World.Facade.pick(world, ["a", "b"])|)
      assert_rejected(~s|Enum.random([1, 2, 3])|)
      assert_rejected(~s|:rand.uniform(6)|)
    end

    # CX-5u5j — own-inventory quest/gift verbs admitted (plan #6171).
    test "(f8) Facade.consume_from_inventory/2 + give_from_inventory/3 pass" do
      assert :ok ==
               Allowlist.check(
                 ~s|Commonplace.MUD.World.Facade.consume_from_inventory(world, "apple")|
               )

      assert :ok ==
               Allowlist.check(
                 ~s|Commonplace.MUD.World.Facade.give_from_inventory(world, "coin", "bob")|
               )
    end

    # CX-a2gd — invoker identity accessors admitted (plan #6189/#6193).
    test "(f9) Facade.actor_name/1 + actor_ref/1 pass" do
      assert :ok == Allowlist.check(~s|Commonplace.MUD.World.Facade.actor_name(world)|)
      assert :ok == Allowlist.check(~s|Commonplace.MUD.World.Facade.actor_ref(world)|)
    end

    # CX-<notify> — invoker-private feedback primitive admitted.
    test "(f10) Facade.notify/2 passes" do
      assert :ok ==
               Allowlist.check(
                 ~s|Commonplace.MUD.World.Facade.notify(world, "STATUS: charged 3/5")|
               )
    end

    test "(f3) the qualified facade form is refused when the first arg isn't the literal world binding" do
      assert_rejected(~s|other = world\nCommonplace.MUD.World.Facade.set_attr(other, "k", "v")|)
      assert_rejected(~s|Commonplace.MUD.World.Facade.set_attr(args, "k", "v")|)
    end

    # CX-fhz4 — the facade carve admits the ACTION methods only, never the
    # constructor `new/5`: admitting new would let a body mint a facade
    # bound to an author-chosen object_uuid + owner_grant (a forging /
    # privilege-escalation vector), even with `world` as the first arg.
    test "(f4) Facade.new(world, ...) is refused even though world is the literal first arg" do
      assert_rejected(
        ~s|Commonplace.MUD.World.Facade.new(world, "victim-uuid", grant, via, store)|
      )
    end

    test "(h) pure field read and a clean pure body both pass" do
      assert :ok == Allowlist.check(~s|m = %{name: "x"}\nm.name|)
      assert :ok == Allowlist.check("Enum.map([1, 2, 3], fn x -> x * 2 end)")
    end

    test "String.to_atom/1 alone is rejected" do
      assert_rejected(~s|String.to_atom("x")|)
    end

    test "quote is rejected" do
      assert_rejected("quote do 1 end")
    end

    test "defmodule is rejected" do
      assert_rejected("defmodule Foo do end")
    end

    test "spawn is rejected" do
      assert_rejected("spawn(fn -> :ok end)")
    end

    test "a syntactically broken body yields a syntax_error" do
      assert {:error, {:syntax_error, _}} = Allowlist.check("def foo(")
    end
  end

  describe "additional structural coverage" do
    test "field access on a var (m.key) is distinct from a dynamic call (var.fun(args))" do
      assert :ok == Allowlist.check("m = %{a: 1}\nm.a")
      assert_rejected("m = %{a: 1}\nm.a(1)")
    end

    test "apply-in-disguise via held function value is rejected" do
      assert_rejected(~s|f = &String.length/1\nf.("hi")|)
    end

    test "Module.concat and Code.eval_string are rejected (unlisted modules)" do
      assert_rejected(~s|Module.concat([Foo, Bar])|)
      assert_rejected(~s|Code.eval_string("1 + 1")|)
    end

    test "Process/Task/Node/Port references are rejected" do
      assert_rejected("Process.exit(self(), :kill)")
      assert_rejected("Task.async(fn -> :ok end)")
    end

    test "destructuring that shadows world or args is refused" do
      assert_rejected("{world, x} = foo()")
      assert_rejected("[args | _] = list")
    end

    test "reading args (not rebinding it) is fine" do
      assert :ok == Allowlist.check("Map.get(args, :name)")
    end

    test "pipe operator arity is adjusted for the piped-in argument" do
      assert :ok == Allowlist.check("[1, 2, 3] |> Enum.sum()")
      assert_rejected("bin |> :erlang.binary_to_term()")
    end

    test "control flow (case/if/cond/for/with) is allowed as pure structure" do
      assert :ok ==
               Allowlist.check("""
               case args do
                 %{cmd: c} when is_binary(c) -> String.upcase(c)
                 _ -> "none"
               end
               """)

      assert :ok == Allowlist.check("if is_atom(args), do: :a, else: :b")
      assert :ok == Allowlist.check("cond do true -> 1; true -> 2 end")
      assert :ok == Allowlist.check("for x <- [1, 2, 3], do: x * 2")
      assert :ok == Allowlist.check("with {:ok, x} <- {:ok, 1}, do: x")
    end

    test "unknown/unlisted function on an allowed module is rejected" do
      # Enum.random is deliberately unlisted (impure — reads the RNG).
      assert_rejected("Enum.random([1, 2, 3])")
    end
  end

  describe "VECTOR 10 — macro-expansion entry points" do
    test "alias-then-dispatch is rejected at the alias" do
      reasons = assert_rejected(~s|alias System, as: S\nS.cmd("id")|)
      assert Enum.any?(reasons, &String.contains?(&1, "alias"))
    end

    test "import is rejected" do
      reasons = assert_rejected("import System")
      assert Enum.any?(reasons, &String.contains?(&1, "import"))
    end

    test "require is rejected" do
      reasons = assert_rejected("require Foo")
      assert Enum.any?(reasons, &String.contains?(&1, "require"))
    end

    test "use is rejected" do
      reasons = assert_rejected("use GenServer")
      assert Enum.any?(reasons, &String.contains?(&1, "use"))
    end

    test "defmacro/defimpl/defprotocol are rejected" do
      assert_rejected("defmacro m(x), do: x")
      assert_rejected("defimpl String.Chars, for: Foo do def to_string(_), do: \"x\" end")
      assert_rejected("defprotocol P do def f(x) end")
    end
  end

  describe "VECTOR 11 — reflective side-channels" do
    test "struct/2 and struct!/2 are rejected" do
      assert_rejected("struct(mod, %{})")
      assert_rejected("struct!(mod, %{})")
    end

    test "function_exported?, binding, dbg, make_ref, self, node are rejected" do
      assert_rejected("function_exported?(m, f, a)")
      assert_rejected("binding()")
      assert_rejected("dbg(x)")
      assert_rejected("make_ref()")
      assert_rejected("self()")
      assert_rejected("node()")
    end

    test "atom / module-name builders are rejected on any module" do
      assert_rejected(~s|Module.concat(["Sys", "tem"])|)
      assert_rejected("List.to_atom(~c\"x\")")
      assert_rejected(~s|String.to_existing_atom("x")|)
    end

    test "any :erlang.* remote call is rejected (function-level, none admitted)" do
      assert_rejected(":erlang.binary_to_atom(bin, :utf8)")
      assert_rejected(":erlang.list_to_atom(~c\"x\")")
      assert_rejected(":erlang.apply(m, f, a)")
      assert_rejected(":erlang.halt(0)")
      assert_rejected(":erlang.send(pid, :msg)")
    end
  end

  # Playtest regression: `[h | t]` cons destructuring/construction is
  # pure list structure (parses to {:|, _, [head, tail]}) — it was wrongly
  # rejected as "|/2 is not allowed", blocking normal list patterns.
  describe "cons cells [h | t] (over-rejection regression)" do
    test "cons in case/fn patterns and destructuring assign pass" do
      assert :ok ==
               Allowlist.check("""
               case args.argv do
                 [h | _t] -> h
                 _ -> "none"
               end
               """)

      assert :ok == Allowlist.check("[first | _rest] = args.argv\nfirst")
      assert :ok == Allowlist.check("Enum.map([[1, 2]], fn [a | _] -> a end)")
      assert :ok == Allowlist.check("[0 | args.argv]")
    end

    test "a disallowed call embedded in a cons is still rejected" do
      assert_rejected("[System.cmd(\"id\", []) | args.argv]")
    end
  end

  # Review regression (Fable): 3+ element tuple literals parse to the
  # call-shaped `{:{}, meta, elems}` AST, which was wrongly rejected as
  # `{}/N` by the generic local-call fallback. Pure data must pass; an
  # embedded call inside a tuple must still be caught.
  describe "N-element tuple literals (over-rejection regression)" do
    test "3+ element tuple of pure data passes" do
      assert :ok == Allowlist.check(~s|{:ok, "a", "b"}|)
      assert :ok == Allowlist.check("{1, 2, 3, 4}")

      assert :ok ==
               Allowlist.check(~s|x = 1\n{:reply, x, Commonplace.MUD.World.Facade.look(world)}|)
    end

    test "a call embedded in a tuple is still rejected" do
      assert_rejected(~s|{:ok, System.cmd("id", []), 3}|)
    end
  end

  # Review regression (Fable): string interpolation compiles to
  # `Kernel.to_string/1` with the module ALREADY resolved to the atom
  # `Kernel` (`:"Elixir.Kernel"`), not an `{:__aliases__,...}` node — the
  # bare-atom-module branch was rejecting it, which would break nearly
  # every verb. Elixir-module atoms route back through the allowlist;
  # Erlang atoms and non-allowlisted Elixir modules still reject.
  describe "resolved-atom module forms (interpolation regression)" do
    test "plain string interpolation passes" do
      assert :ok == Allowlist.check(~S|name = "x"; "hi #{name}"|)

      assert :ok ==
               Allowlist.check(
                 ~S|Commonplace.MUD.World.Facade.say(world, "you see #{args.thing}")|
               )
    end

    test "interpolation of a disallowed call is still rejected" do
      assert_rejected(~S|"result: #{System.cmd("id", [])}"|)
    end

    test "an Elixir-module atom literal routes through the same allowlist" do
      assert :ok == Allowlist.check(~S|:"Elixir.Enum".map([1, 2], fn x -> x end)|)
      assert_rejected(~S|:"Elixir.System".cmd("id", [])|)
      assert_rejected(~S|:"Elixir.Kernel".apply(m, f, a)|)
    end
  end

  # CX-fhz4 — the run-boundary re-verification. `check_wrapped/1` is what
  # `SourceDoc.compile/3` runs against STORED content on every compile
  # (cache hit or miss), independent of the `.safe.elx` filename.
  # `SafeVerb.wrap/1` is private (it's only ever reached through
  # `wrap_and_lint/1`, which would refuse a `System.cmd` body via `Lint`
  # before `check_wrapped/1` ever saw it) — so these tests build the
  # exact wrapper text `wrap/1` produces by hand, to exercise
  # `check_wrapped/1` as its OWN re-verification, independent of `Lint`.
  defp wrapped(body) do
    """
    defmodule Commonplace.MUD.SafeVerbBody do
      def run(world, args) do
    #{body}
      end
    end
    """
  end

  describe "check_wrapped/1 (CX-fhz4 run-boundary re-check)" do
    test "a correctly-wrapped clean body passes" do
      assert :ok ==
               Allowlist.check_wrapped(
                 wrapped(~s|Commonplace.MUD.World.Facade.say(world, "hi \#{args.name}")|)
               )
    end

    test "a wrapped body containing System.cmd is rejected as disallowed" do
      assert {:error, {:unsafe_verb, {:disallowed, reasons}}} =
               Allowlist.check_wrapped(wrapped(~s|System.cmd("id", [])|))

      assert reasons != []
    end

    test "a non-wrapper (legacy full module, wrong arity, wrong param names) is rejected as not_substrate_wrapped" do
      legacy = """
      defmodule Foo do
        def run(ctx) do
          :ok
        end
      end
      """

      assert {:error, {:unsafe_verb, :not_substrate_wrapped}} = Allowlist.check_wrapped(legacy)
    end

    test "a two-def module is rejected as not_substrate_wrapped" do
      two_def = """
      defmodule Commonplace.MUD.SafeVerbBody do
        def run(world, args) do
          :ok
        end

        def helper, do: :ok
      end
      """

      assert {:error, {:unsafe_verb, :not_substrate_wrapped}} = Allowlist.check_wrapped(two_def)
    end

    test "a module with an extra module attribute is rejected as not_substrate_wrapped" do
      with_attr = """
      defmodule Commonplace.MUD.SafeVerbBody do
        @foo :bar

        def run(world, args) do
          :ok
        end
      end
      """

      assert {:error, {:unsafe_verb, :not_substrate_wrapped}} = Allowlist.check_wrapped(with_attr)
    end

    test "a syntax error is reported as unsafe_verb/syntax_error" do
      assert {:error, {:unsafe_verb, {:syntax_error, _}}} =
               Allowlist.check_wrapped("defmodule Foo do")
    end
  end

  # P0 key-leak fix (data-reachability): the signing material lives in the
  # sandbox child's PROCESS DICT, so the fix's LOAD-BEARING dependency is that
  # verb code cannot read the process dict OR call the facade's signer
  # helpers. Pin it explicitly (plan's "test the load-bearing invariant, not
  # incidental" — the original miss was incidentally-closed-but-unaudited).
  describe "P0 fix dependency: process-dict + signer helpers are unreachable" do
    test "process-dict / reflection reads are all REJECTED" do
      for src <- [
            ~s|Process.get()|,
            ~s|Process.get(:cp_safe_verb_signer)|,
            ~s|Process.get_keys()|,
            ~s|Process.info(self())|,
            ~s|Process.info(self(), :dictionary)|,
            ~s|:erlang.get()|,
            ~s|:erlang.get(:cp_safe_verb_signer)|,
            ~s|:erlang.get_keys()|,
            # black-box sweep (probe7) surfaced these — a direct process-dict
            # read via process_info, and apply/:erlang.apply dynamic dispatch.
            ~s|:erlang.process_info(self(), :dictionary)|,
            ~s|apply(:erlang, :get, [:cp_safe_verb_signer])|,
            ~s|:erlang.apply(:erlang, :get, [])|,
            ~s|self()|
          ] do
        assert {:error, _} = Allowlist.check(src), "expected REJECT for: #{src}"
      end
    end

    test "the facade's signer helpers are NOT admitted (verb can't extract the material)" do
      assert {:error, _} =
               Allowlist.check(~s|Commonplace.MUD.World.Facade.signer_material(world)|)

      assert {:error, _} = Allowlist.check(~s|Commonplace.MUD.World.Facade.install_signer(%{})|)
    end
  end

  # plan #7573 allowlist-completeness review — two concrete gaps closed.
  describe "GAP-1: bitstring type-spec is scanned (RCE escape)" do
    test "an executable call embedded in a size type-spec is REJECTED" do
      # <<x::size(evil())>> would RUN the call at runtime before any type error;
      # the type-spec used to be ignored entirely — the escape.
      assert_rejected(~s|<<x::size(System.cmd("id", []))>>|)
      assert_rejected(~s|<<x::size(:erlang.system_time())>>|)
    end

    test "a disallowed call in a unit()/chained type-spec is rejected" do
      assert_rejected(~s|<<x::unit(File.read!("/x"))-size(8)>>|)
    end

    test "legit bitstring type-specs still pass (atoms, literal sizes, -/*, var sizes)" do
      assert :ok == Allowlist.check("<<x::size(8)>>")
      assert :ok == Allowlist.check("<<x::integer-size(16)>>")
      assert :ok == Allowlist.check("<<x::utf8>>")
      assert :ok == Allowlist.check("<<x::binary>>")
      assert :ok == Allowlist.check("<<x::size(n)>>")
    end
  end

  describe "GAP-2: compile-time reflection pseudo-vars rejected" do
    test "__ENV__ and friends are NOT treated as variable reads" do
      for pv <- ~w(__ENV__ __CALLER__ __MODULE__ __DIR__ __STACKTRACE__) do
        reasons = assert_rejected(pv)
        assert Enum.any?(reasons, &String.contains?(&1, "reserved pseudo-variable"))
      end
    end

    test "an ordinary variable read is still allowed" do
      assert :ok == Allowlist.check("x")
      assert :ok == Allowlist.check("world.object_uuid")
    end
  end
end
