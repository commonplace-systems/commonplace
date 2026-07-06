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

    test "(f) world.look(...) and world.emote(args) pass (facade carve-out)" do
      assert :ok == Allowlist.check(~s|world.look("here")|)
      assert :ok == Allowlist.check("world.emote(args)")
    end

    test "(g) rebinding world is refused even though the dispatch itself would pass" do
      assert_rejected("world = System\nworld.cmd(\"id\", [])")
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

  # Review regression (Fable): 3+ element tuple literals parse to the
  # call-shaped `{:{}, meta, elems}` AST, which was wrongly rejected as
  # `{}/N` by the generic local-call fallback. Pure data must pass; an
  # embedded call inside a tuple must still be caught.
  describe "N-element tuple literals (over-rejection regression)" do
    test "3+ element tuple of pure data passes" do
      assert :ok == Allowlist.check(~s|{:ok, "a", "b"}|)
      assert :ok == Allowlist.check("{1, 2, 3, 4}")
      assert :ok == Allowlist.check(~s|x = 1\n{:reply, x, world.look("here")}|)
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
      assert :ok == Allowlist.check(~S|world.say("you see #{args.thing}")|)
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
end
