defmodule Commonplace.MUD.World.Facade.AccumDef do
  @moduledoc """
  CX-3x5a — override `def` in `Commonplace.MUD.World.Facade` so every PUBLIC
  method's return is post-processed through the drop-accumulator, BY
  CONSTRUCTION.

  The point of the macro (over hand-wrapping each method) is its failure
  mode: a manual per-method wrap fails SILENTLY the day someone adds a new
  facade method and forgets to wrap it — the exact silent-swallow this
  feature exists to kill. The macro wraps EVERY public `def` automatically,
  so a new method's `{:error, _}` drops are caught with no author action; the
  only way to regress is to break the macro, which fails LOUD (compile/test).

  `defp` is deliberately NOT overridden — private helpers keep normal `def`
  and propagate their errors up through the wrapped public return. The
  `defimpl Inspect` block in `facade.ex` is a sibling top-level module (not
  lexically nested), so this override does not reach it; it additionally
  restores `Kernel.def` as belt-and-suspenders.
  """

  defmacro __using__(_) do
    quote do
      import Kernel, except: [def: 2]
      import Commonplace.MUD.World.Facade.AccumDef, only: [def: 2]
    end
  end

  defmacro def(call, do: body) do
    name = fn_name(call)

    quote do
      Kernel.def unquote(call) do
        Commonplace.MUD.World.Facade.__accumulate__(unquote(name), unquote(body))
      end
    end
  end

  # name from `foo(args)` or `foo(args) when guard`
  defp fn_name({:when, _, [head | _]}), do: fn_name(head)
  defp fn_name({name, _, _}) when is_atom(name), do: name
end
