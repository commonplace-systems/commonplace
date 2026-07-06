defmodule Commonplace.MUD.SafeVerb.Allowlist do
  @moduledoc """
  CX-bg1v — the P0 safe-verb AST allowlist: a CLOSED-BY-DEFAULT scan
  over a safe-verb `run/2` BODY (the raw text an author submits, same
  input contract as the sibling `Commonplace.MUD.SafeVerb.Lint`, which
  this module does NOT replace — see the division-of-labor note below).

  `Commonplace.MUD.SafeVerb.Lint` is a DENYLIST (raised bar against
  known-bad constructs). This module is the opposite posture: every
  AST node/call must be explicitly recognized as permitted or the
  whole body is rejected. Unknown stdlib surface — anything this
  module hasn't been taught about — fails closed. This is the
  response to CX-bg1v (a user-authored MUD verb reached
  `System.cmd/2` and achieved RCE): a denylist can only ever enumerate
  the exploits someone already thought of; a closed-by-default
  allowlist doesn't have that gap.

  ## What's allowed (see module attributes below for the exact tables)

    * `Enum`/`Map`/`List`/`String`/`Integer`/`Float` — a curated,
      conservatively-picked {function, arity} allowlist per module.
      `String.to_atom/1` and `String.to_existing_atom/1` are
      deliberately EXCLUDED even though the rest of `String` is
      allowed — atom construction from player-influenced strings is
      an atom-table exhaustion vector and a stepping stone to
      constructing a hostile module/function reference dynamically.
    * Bare/`Kernel.`-qualified arithmetic, comparison, boolean,
      list/binary-concat, membership/range, `is_*` type guards, and a
      short list of harmless one-offs (`to_string/1`, `inspect/1`,
      `length/1`, `hd/1`, `tl/1`, `elem/2`, `tuple_size/1`,
      `map_size/1`, `byte_size/1`) — see `@kernel_allowed`. Kernel is
      the trap: it also holds `apply`, `spawn`, `send`, `self`,
      `binary_to_atom`, etc. — none of those are on the list, so they
      fall through to the closed-by-default rejection.
    * Control flow needed to write anything nontrivial: `fn`, `case`,
      `cond`, `if`/`unless`, `for`, `with`, `|>`, blocks, map/tuple/
      list/binary literals, a small set of harmless data sigils
      (`~c`, `~s`, `~w`). None of these can themselves name arbitrary
      code — they're pure structure — so allowing them doesn't reopen
      the REACH this module exists to close.
    * The facade carve-out: any `.`-call whose receiver is the
      LITERAL bound parameter `world` (e.g. `world.look(...)`) is
      allowed unconditionally — `Commonplace.MUD.World.Facade` is the
      audited least-authority surface a safe verb is bound to; this
      checker doesn't need to re-enumerate its methods. Both `world`
      and `args` are protected from rebinding (`world = System` or a
      destructuring pattern that shadows either name) precisely
      because the whole carve-out's safety depends on `world` still
      being the original facade value at the point it's dispatched on.

  ## Structural rejections (REQ 2/3 — the "highest care" section)

  A `.`-call AST node has three shapes and they are NOT
  interchangeable:

    * `Enum.map(...)` — remote call with a LITERAL `{:__aliases__,
      ...}` module — checked against the per-module {fun, arity}
      table.
    * `m.key` (no parens, no args — Elixir's parser marks this with a
      `no_parens: true` meta flag, which is how this checker tells it
      apart from `m.key()`) — a pure field/struct read, allowed
      unconditionally since it can't execute anything.
    * `var.fun(args)` or `var.fun()` (explicit call parens) — DYNAMIC
      dispatch on a receiver that isn't a literal module alias.
      Rejected outright unless the receiver is the literal `world`
      param (the facade carve above). This is what closes
      `mod = String.to_atom(...); mod.cmd(...)` and
      `world = System; world.cmd(...)` — both hinge on a variable,
      not a literal alias, sitting in receiver position.

  A third, related shape — `fun.(a, b)`, invoking a value held in a
  variable as if it were a function (`{:., _, [callee]}` with a
  ONE-element dot arg list, no module/fun pair at all) — is also
  rejected outright; it's `apply` wearing different syntax.

  ## INTENTIONAL LIMITATION — direct `f.()` on an author's own anon fn

  Because `f.(x)` is structurally indistinguishable from smuggled-value
  dispatch, an author's OWN anonymous function invoked directly
  (`f = fn x -> x end; f.(1)`) is rejected. This is a deliberate
  conservative call, not an oversight: higher-order code still works
  because the anon fn is invoked INSIDE an allowlisted function
  (`Enum.map(coll, fn x -> ... end)`) rather than by an author `.()`.
  The first author who writes `f.()` and sees a rejection should
  restructure through `Enum`/`Map` combinators.

  ## Captures walk INTO their target (REQ 5)

  `&System.cmd/2` embeds a full MFA reference without ever "calling"
  anything at the top level — `&`'s argument is walked exactly like a
  0-arg call to the referenced `{module, function, arity}`, so it's
  checked against the same tables. Partial captures like
  `&(&1 * 2)` recurse into the expression normally; the `&1`/`&2`
  placeholders are just variable reads.

  ## Macro-expansion soundness (VECTOR 10 — load-bearing dependency)

  This checker walks the PRE-EXPANSION AST — the surface an author
  literally typed, before macro expansion. That is only SOUND because
  no author-defined or foreign macro can run at expansion time: this
  module rejects, outright and each with a named reason, every entry
  point through which a foreign name or macro could enter —

    * `alias` (`alias System, as: S` then `S.cmd`),
    * `import` (`import System` then a bare `cmd`),
    * `require` (arms a foreign macro for expansion),
    * `use` (injects a module's `__using__` code),
    * `quote` / `unquote` (author-constructed AST),
    * `defmacro` / `defmodule` / `defimpl` / `defprotocol`.

  With all of those refused, the ONLY macros reachable during
  expansion are the fixed `Kernel` / allowlisted-module set whose
  expansions are themselves known and audited. So "walk what was
  typed" == "walk what will execute." A full `Macro.expand`-and-
  re-walk belt is NOT implemented here (it needs a compile-time
  `__ENV__`, a wiring-time concern) — its job is instead discharged
  structurally by these rejections. If any of the above are ever
  re-admitted, this pre-expansion walk becomes UNSOUND and the
  expand-belt must be added first.

  Related: `inspect`/`to_string`/`Enumerable` etc. dispatch through
  Elixir PROTOCOLS. Those are safe here ONLY because `defimpl` /
  `defprotocol` are rejected — no author can install a hostile
  protocol impl, so only the existing, pure, audited impls can run.
  Re-enabling `defimpl` requires re-reviewing that guarantee.

  ## POSITIVE ADMIT SET (VECTOR 11 audit deliverable — what is IN)

  Auditing what is admitted is as load-bearing as what is banned; one
  over-broad admit (e.g. `struct/2`) reopens a whole class. The
  COMPLETE admitted surface:

      Remote {Module, function, arity} (literal-alias receiver only):
        Enum:    map/2 filter/2 reduce/2 reduce/3 each/2 count/1 count/2
                 member?/2 at/2 at/3 join/1 join/2 sort/1 sort/2 reverse/1
                 reverse/2 take/2 drop/2 sum/1 min/1 min/2 max/1 max/2
                 into/2 into/3 flat_map/2 to_list/1 uniq/1 uniq/2
                 with_index/1 with_index/2 empty?/1 all?/1 all?/2 any?/1
                 any?/2
        Map:     get/2 get/3 put/3 fetch/2 has_key?/2 keys/1 values/1
                 merge/2 merge/3 delete/2 new/0 new/1 to_list/1
        List:    first/1 first/2 last/1 last/2 flatten/1 flatten/2 wrap/1
                 delete/2 insert_at/3 to_tuple/1
        String:  length/1 downcase/1 downcase/2 upcase/1 upcase/2 trim/1
                 split/1 split/2 split/3 replace/3 replace/4 contains?/2
                 slice/2 slice/3 to_integer/1 to_float/1 starts_with?/2
                 ends_with?/2 capitalize/1 capitalize/2 reverse/1
                 pad_leading/2 pad_leading/3 pad_trailing/2 pad_trailing/3
        Integer: to_string/1 to_string/2 parse/1 parse/2 mod/2 floor_div/2
        Float:   round/1 round/2 ceil/1 ceil/2 floor/1 floor/2 to_string/1
                 to_string/2
        (NO other module is admitted. String.to_atom/to_existing_atom
         are DELIBERATELY absent. `Kernel.<fun>/<arity>` is admitted
         iff on the Kernel set below.)

      Kernel {name, arity} (bare local OR explicit `Kernel.`):
        arithmetic: +/1 +/2 -/1 -/2 */2 //2 div/2 rem/2 abs/1
        comparison: ==/2 !=/2 </2 >/2 <=/2 >=/2 ===/2 !==/2
        boolean:    and/2 or/2 not/1 &&/2 ||/2 !/1
        concat:     ++/2 --/2 <>/2
        member/rng: in/2 ../2 ..///3 (step range)
        type guards:is_atom/1 is_binary/1 is_list/1 is_map/1 is_integer/1
                    is_float/1 is_number/1 is_boolean/1 is_nil/1 is_tuple/1
        one-offs:   to_string/1 inspect/1 length/1 hd/1 tl/1 elem/2
                    tuple_size/1 map_size/1 byte_size/1

      Special forms / control flow (pure structure, recursed into):
        __block__, = (except when LHS rebinds world/args), fn, case,
        cond, if, unless, for, with, |> , map literal `%{}` (incl.
        update `%{m | ..}`), list/tuple/binary `<<>>` literals,
        `when` guards. (`%Struct{}` construction is REJECTED.)

      Facade carve: any `.`-call whose receiver is the LITERAL bound
        param `world` (e.g. `world.look(..)`) — the Facade module is
        the audited surface; `world`/`args` are un-rebindable.

      Sigils (data-only): ~c ~s ~w. (All others rejected.)

      Field read: `var.key` (no-parens dot) — pure map/struct read.

      String interpolation (`"a \#{x}"`) — compiles to an allowed
        `Kernel.to_string/1` over the interpolated expression, which is
        itself scanned; an interpolated disallowed call is still caught.
        (Elixir-module atoms `:"Elixir.X"` are normalized back through
        this same allowlist; Erlang atoms like `:os` have no admitted
        surface and are rejected.)

      EVERYTHING ELSE fails closed.

  ## Division of labor / honesty residual

  This module closes REACH — what code can NAME and invoke. It does
  NOT close resource exhaustion (infinite loops, unbounded recursion,
  huge terms) — that's `Commonplace.MUD.SafeVerb.Bounds`'s job
  (wall-clock timeout + `max_heap_size` kill), orthogonal to this
  checker and still required alongside it. Atom-table exhaustion IS
  closed here (no atom-construction function is reachable through any
  allowed path).

  An allowlist over a Turing-complete host language cannot PROVE the
  audited pure surface is exhaustively side-effect-free — this is
  defense-in-depth over a rich language, not a formal sandbox. OS-level
  process isolation remains the phase-4 horizon for genuine
  containment against a sophisticated adversary; this checker's bar is
  "demo-grade safe for untrusted authors," matching `Lint`'s and
  `Bounds`'s honesty notes.
  """

  @kernel_allowed MapSet.new([
                    {:+, 1},
                    {:+, 2},
                    {:-, 1},
                    {:-, 2},
                    {:*, 2},
                    {:/, 2},
                    {:div, 2},
                    {:rem, 2},
                    {:abs, 1},
                    {:==, 2},
                    {:!=, 2},
                    {:<, 2},
                    {:>, 2},
                    {:<=, 2},
                    {:>=, 2},
                    {:===, 2},
                    {:!==, 2},
                    {:and, 2},
                    {:or, 2},
                    {:not, 1},
                    {:&&, 2},
                    {:||, 2},
                    {:!, 1},
                    {:++, 2},
                    {:--, 2},
                    {:<>, 2},
                    {:in, 2},
                    {:.., 2},
                    {:"..//", 3},
                    {:is_atom, 1},
                    {:is_binary, 1},
                    {:is_list, 1},
                    {:is_map, 1},
                    {:is_integer, 1},
                    {:is_float, 1},
                    {:is_number, 1},
                    {:is_boolean, 1},
                    {:is_nil, 1},
                    {:is_tuple, 1},
                    {:to_string, 1},
                    {:inspect, 1},
                    {:length, 1},
                    {:hd, 1},
                    {:tl, 1},
                    {:elem, 2},
                    {:tuple_size, 1},
                    {:map_size, 1},
                    {:byte_size, 1}
                  ])

  @allowed_modules %{
    "Enum" =>
      MapSet.new([
        {:map, 2},
        {:filter, 2},
        {:reduce, 2},
        {:reduce, 3},
        {:each, 2},
        {:count, 1},
        {:count, 2},
        {:member?, 2},
        {:at, 2},
        {:at, 3},
        {:join, 1},
        {:join, 2},
        {:sort, 1},
        {:sort, 2},
        {:reverse, 1},
        {:reverse, 2},
        {:take, 2},
        {:drop, 2},
        {:sum, 1},
        {:min, 1},
        {:min, 2},
        {:max, 1},
        {:max, 2},
        {:into, 2},
        {:into, 3},
        {:flat_map, 2},
        {:to_list, 1},
        {:uniq, 1},
        {:uniq, 2},
        {:with_index, 1},
        {:with_index, 2},
        {:empty?, 1},
        {:all?, 1},
        {:all?, 2},
        {:any?, 1},
        {:any?, 2},
        # CX-bg1v keystone review (commonplace-plan #5892) — blessed
        # additions, all pure, no dispatch/atom/module construction.
        {:find, 2},
        {:find_value, 2},
        {:find_value, 3},
        {:group_by, 2},
        {:group_by, 3},
        {:zip, 1},
        {:zip, 2},
        {:chunk_every, 2},
        {:chunk_every, 3},
        {:chunk_every, 4},
        {:map_join, 2},
        {:map_join, 3},
        {:frequencies, 1},
        {:min_max, 1},
        {:uniq_by, 2}
      ]),
    "Map" =>
      MapSet.new([
        {:get, 2},
        {:get, 3},
        {:put, 3},
        {:fetch, 2},
        {:has_key?, 2},
        {:keys, 1},
        {:values, 1},
        {:merge, 2},
        {:merge, 3},
        {:delete, 2},
        {:new, 0},
        {:new, 1},
        {:to_list, 1},
        # CX-bg1v keystone review (#5892) — blessed pure additions.
        {:update, 3},
        {:update, 4},
        {:take, 2},
        {:drop, 2},
        {:put_new, 3}
      ]),
    "List" =>
      MapSet.new([
        {:first, 1},
        {:first, 2},
        {:last, 1},
        {:last, 2},
        {:flatten, 1},
        {:flatten, 2},
        {:wrap, 1},
        {:delete, 2},
        {:insert_at, 3},
        {:to_tuple, 1}
      ]),
    "String" =>
      MapSet.new([
        {:length, 1},
        {:downcase, 1},
        {:downcase, 2},
        {:upcase, 1},
        {:upcase, 2},
        {:trim, 1},
        {:split, 1},
        {:split, 2},
        {:split, 3},
        {:replace, 3},
        {:replace, 4},
        {:contains?, 2},
        {:slice, 2},
        {:slice, 3},
        {:to_integer, 1},
        {:to_float, 1},
        {:starts_with?, 2},
        {:ends_with?, 2},
        {:capitalize, 1},
        {:capitalize, 2},
        {:reverse, 1},
        {:pad_leading, 2},
        {:pad_leading, 3},
        {:pad_trailing, 2},
        {:pad_trailing, 3},
        # CX-bg1v keystone review (#5892) — blessed pure additions.
        {:replace_prefix, 3},
        {:replace_suffix, 3}
      ]),
    "Integer" =>
      MapSet.new([
        {:to_string, 1},
        {:to_string, 2},
        {:parse, 1},
        {:parse, 2},
        {:mod, 2},
        {:floor_div, 2}
      ]),
    "Float" =>
      MapSet.new([
        {:round, 1},
        {:round, 2},
        {:ceil, 1},
        {:ceil, 2},
        {:floor, 1},
        {:floor, 2},
        {:to_string, 1},
        {:to_string, 2}
      ])
  }

  @allowed_sigils [:sigil_c, :sigil_s, :sigil_w]

  # VECTOR 11 — reflective / capability side-channels that WEAR a
  # safe-looking bare-local face. Closed-by-default already rejects
  # every one of these (none is on any allow table), but they are pinned
  # here with explicit reasons so a reviewer sees each named and nobody
  # silently re-admits one by widening the Kernel set. Keyed by name,
  # rejected at ANY arity.
  @dangerous_locals %{
    struct: "struct/2 dispatches to the first argument's `__struct__` (dynamic dispatch)",
    struct!: "struct!/2 dispatches to the first argument's `__struct__` (dynamic dispatch)",
    function_exported?: "function_exported? is reflection over arbitrary modules",
    macro_exported?: "macro_exported? is reflection over arbitrary modules",
    binding: "binding leaks the caller's variable bindings",
    dbg: "dbg reflects and prints arbitrary evaluation context",
    apply: "apply is dynamic dispatch (can reach any exported function)",
    spawn: "spawn creates an uncontrolled process",
    spawn_link: "spawn_link creates an uncontrolled linked process",
    spawn_monitor: "spawn_monitor creates an uncontrolled monitored process",
    send: "send performs uncontrolled inter-process messaging",
    receive: "receive blocks on the process mailbox (uncontrolled I/O)",
    self: "self exposes the process identity (capability leak)",
    exit: "exit raises an uncatchable process signal",
    throw: "throw performs non-local control flow into unknown handlers",
    make_ref: "make_ref mints a capability reference",
    node: "node exposes distribution identity",
    spawn_request: "spawn_request creates an uncontrolled process"
  }

  @reserved_rebind_msg "reassignment of the reserved `world`/`args` binding is not allowed"

  @doc """
  Scan `source` (the raw `run/2` BODY text). Returns `:ok`,
  `{:error, {:disallowed, [String.t()]}}` (one message per distinct
  violation, deduplicated), or `{:error, {:syntax_error, String.t()}}`
  if the body doesn't parse as Elixir.
  """
  @spec check(String.t()) ::
          :ok | {:error, {:disallowed, [String.t()]}} | {:error, {:syntax_error, String.t()}}
  def check(source) when is_binary(source) do
    case Code.string_to_quoted(source) do
      {:ok, ast} ->
        case scan(ast) |> Enum.uniq() do
          [] -> :ok
          reasons -> {:error, {:disallowed, reasons}}
        end

      {:error, {_meta, message, token}} ->
        {:error, {:syntax_error, "#{inspect(message)}#{inspect(token)}"}}
    end
  end

  # ---- macro-surface entry points (VECTOR 10) — rejected outright -----
  # These are the ONLY ways a foreign/aliased name or an author-defined
  # macro can enter the body; the pre-expansion walk is sound ONLY
  # because all of them are refused here (see moduledoc "Macro-expansion
  # soundness"). Matched on the CALL form (`is_list(args)`) so a variable
  # that happens to share the name is untouched.
  defp scan({:alias, _, args}) when is_list(args),
    do: ["alias is not allowed (would introduce a foreign/aliased module name)"]

  defp scan({:import, _, args}) when is_list(args),
    do: ["import is not allowed (would bring foreign functions into bare-call scope)"]

  defp scan({:require, _, args}) when is_list(args),
    do: ["require is not allowed (would arm a foreign macro for expansion)"]

  defp scan({:use, _, args}) when is_list(args),
    do: ["use is not allowed (would inject a module's __using__ macro code)"]

  defp scan({:quote, _, args}) when is_list(args),
    do: ["quote is not allowed (author-constructed AST)"]

  defp scan({:unquote, _, args}) when is_list(args),
    do: ["unquote is not allowed (author-constructed AST)"]

  defp scan({def_form, _, args})
       when def_form in [:defmodule, :defmacro, :defmacrop, :defimpl, :defprotocol, :defdelegate] and
              is_list(args),
       do: ["#{def_form} is not allowed (a safe verb is a run/2 body, not a module/macro definition)"]

  # ---- blocks / assignment ----------------------------------------

  defp scan({:__block__, _, args}) when is_list(args), do: Enum.flat_map(args, &scan/1)

  defp scan({:=, _, [lhs, rhs]}) do
    base = scan(rhs) ++ scan(lhs)
    if binds_reserved?(lhs), do: base ++ [@reserved_rebind_msg], else: base
  end

  # ---- control flow --------------------------------------------------

  defp scan({:fn, _, clauses}) when is_list(clauses), do: Enum.flat_map(clauses, &scan_arrow_clause/1)

  defp scan({:case, _, [subject, [do: clauses]]}) when is_list(clauses),
    do: scan(subject) ++ Enum.flat_map(clauses, &scan_arrow_clause/1)

  defp scan({:cond, _, [[do: clauses]]}) when is_list(clauses),
    do: Enum.flat_map(clauses, &scan_cond_clause/1)

  defp scan({branch, _, [cond_expr, kw]}) when branch in [:if, :unless] and is_list(kw) do
    scan(cond_expr) ++ scan(Keyword.get(kw, :do)) ++ scan(Keyword.get(kw, :else))
  end

  defp scan({:for, _, args}) when is_list(args), do: scan_for(args)
  defp scan({:with, _, args}) when is_list(args), do: scan_with(args)

  defp scan({:|>, _, [lhs, rhs]}), do: scan(lhs) ++ scan_pipe_rhs(rhs)

  # ---- `.` operator: three forms, one structural trap -----------------

  # `fun.(a, b)` — invoking a held value as a function. Apply-in-disguise.
  defp scan({{:., _, [callee]}, _, args}) when is_list(args) do
    ["dynamic function invocation (`var.(...)`) is not allowed"] ++
      scan(callee) ++ Enum.flat_map(args, &scan/1)
  end

  # `mod.fun(...)` / `mod.fun` / `mod.fun()` — remote call or field read.
  defp scan({{:., _, [mod, fun]}, meta2, args}) when is_atom(fun) and is_list(args) do
    if args == [] and Keyword.get(meta2, :no_parens) && var_node?(mod) do
      scan(mod)
    else
      handle_call(mod, fun, args, 0)
    end
  end

  # ---- captures --------------------------------------------------------

  defp scan({:&, _, [inner]}), do: scan_capture(inner)

  # ---- struct / map / binary literals -----------------------------------

  defp scan({:%, _, [_struct_mod, map]}) do
    ["struct construction is not allowed"] ++ scan(map)
  end

  defp scan({:%{}, _, [{:|, _, [base_map, kvs]}]}), do: scan(base_map) ++ scan_pairs(kvs)
  defp scan({:%{}, _, pairs}) when is_list(pairs), do: scan_pairs(pairs)

  defp scan({:<<>>, _, parts}) when is_list(parts), do: Enum.flat_map(parts, &scan_bitstring_part/1)

  # ---- sigils (data-only allowlist) -------------------------------------

  defp scan({sigil, _, [str, _mods]}) when sigil in @allowed_sigils, do: scan(str)

  # ---- standalone module alias reference (e.g. `mod = System`) ---------

  defp scan({:__aliases__, _, parts}) when is_list(parts) do
    ["reference to module #{alias_name(parts)} is not allowed outside an allowlisted call"]
  end

  # ---- N-element tuple literal ({:{}, _, elems}, i.e. 3+ elements) --------
  # Pure data. 2-tuples are the literal `{a, b}` form (handled in the
  # plain-data section below); tuples of 3+ elements use this call-SHAPED
  # AST (`:{}` in head position), which would otherwise fall through to the
  # generic local-call fallback and be wrongly rejected as `{}/N`. Recurse
  # into the elements so an embedded call is still caught — the tuple
  # itself names no code.
  defp scan({:{}, _, elems}) when is_list(elems), do: Enum.flat_map(elems, &scan/1)

  # ---- variable read -----------------------------------------------------

  defp scan({name, _, ctx}) when is_atom(name) and not is_list(ctx), do: []

  # ---- generic local call fallback (closed by default) -------------------

  defp scan({name, _, args}) when is_atom(name) and is_list(args) do
    handle_local(name, args, 0)
  end

  # ---- literals / plain data ----------------------------------------------

  defp scan(node) when is_number(node) or is_binary(node) or is_atom(node), do: []
  defp scan(node) when is_list(node), do: Enum.flat_map(node, &scan/1)
  defp scan({a, b}), do: scan(a) ++ scan(b)

  # ---- closed by default: anything else is rejected -----------------------

  defp scan(_other), do: ["unrecognized syntax construct is not allowed"]

  # === helpers =============================================================

  defp alias_name(parts), do: parts |> Enum.map(&to_string/1) |> Enum.join(".")

  defp var_node?({name, _, ctx}) when is_atom(name) and not is_list(ctx), do: true
  defp var_node?(_), do: false

  defp scan_pairs(pairs) when is_list(pairs) do
    Enum.flat_map(pairs, fn
      {k, v} -> scan(k) ++ scan(v)
      other -> scan(other)
    end)
  end

  defp scan_bitstring_part({:"::", _, [expr, _type_spec]}), do: scan(expr)
  defp scan_bitstring_part(other), do: scan(other)

  # `when`-guarded pattern lists are wrapped as a single `{:when, _, args}`
  # element whose LAST element is the guard expression and whose preceding
  # elements are the real patterns. Unguarded clauses have no such wrapper.
  defp split_when([{:when, _, when_args}]) when is_list(when_args) do
    {patterns, [guard]} = Enum.split(when_args, length(when_args) - 1)
    {patterns, guard}
  end

  defp split_when(params), do: {params, nil}

  # Shared by `fn` clauses, `case` clauses, and `with`'s `:else` clauses.
  defp scan_arrow_clause({:->, _, [params, body]}) do
    {patterns, guard} = split_when(params)

    bind_reason = if Enum.any?(patterns, &binds_reserved?/1), do: [@reserved_rebind_msg], else: []
    guard_reasons = if guard, do: scan(guard), else: []

    bind_reason ++ guard_reasons ++ Enum.flat_map(patterns, &scan/1) ++ scan(body)
  end

  # `cond` clauses have no binding pattern — just a boolean guard expression.
  defp scan_cond_clause({:->, _, [[guard_expr], body]}), do: scan(guard_expr) ++ scan(body)

  defp scan_for(args) do
    {kw, clauses} = List.pop_at(args, -1)

    kw_reasons =
      case kw do
        kw when is_list(kw) -> Enum.flat_map(kw, fn {_k, v} -> scan(v) end)
        other -> scan(other)
      end

    kw_reasons ++ Enum.flat_map(clauses, &scan_generator_or_filter/1)
  end

  defp scan_with(args) do
    {kw, clauses} = List.pop_at(args, -1)

    kw = if is_list(kw), do: kw, else: []

    do_reasons = scan(Keyword.get(kw, :do))

    else_reasons =
      case Keyword.get(kw, :else) do
        else_clauses when is_list(else_clauses) -> Enum.flat_map(else_clauses, &scan_arrow_clause/1)
        _ -> []
      end

    other_kw_reasons =
      kw
      |> Keyword.drop([:do, :else])
      |> Enum.flat_map(fn {_k, v} -> scan(v) end)

    do_reasons ++ else_reasons ++ other_kw_reasons ++ Enum.flat_map(clauses, &scan_generator_or_filter/1)
  end

  defp scan_generator_or_filter({:<-, _, [pattern, expr]}) do
    base = scan(expr) ++ scan(pattern)
    if binds_reserved?(pattern), do: base ++ [@reserved_rebind_msg], else: base
  end

  defp scan_generator_or_filter(other), do: scan(other)

  # Pipe RHS is always a call — apply the same allowlist checks as a normal
  # `.`-call or bare local call, but with the piped-in LHS counted as one
  # extra (implicit) argument for arity purposes (`length(explicit_args)+1`).
  defp scan_pipe_rhs({{:., _, [mod, fun]}, _, args}) when is_atom(fun) and is_list(args) do
    handle_call(mod, fun, args, 1)
  end

  defp scan_pipe_rhs({name, _, args}) when is_atom(name) and is_list(args) do
    handle_local(name, args, 1)
  end

  defp scan_pipe_rhs(other), do: scan(other) ++ ["dynamic pipe target is not allowed"]

  defp handle_local(name, args, bonus) do
    arity = length(args) + bonus
    arg_reasons = Enum.flat_map(args, &scan/1)

    cond do
      Map.has_key?(@dangerous_locals, name) ->
        # VECTOR 11 — explicit pin (would fall to closed-by-default anyway,
        # but named so a reviewer sees each reflective side-channel).
        arg_reasons ++ [Map.fetch!(@dangerous_locals, name)]

      MapSet.member?(@kernel_allowed, {name, arity}) ->
        arg_reasons

      true ->
        arg_reasons ++ ["#{name}/#{arity} is not allowed"]
    end
  end

  defp handle_call(mod, fun, args, bonus) when is_atom(fun) do
    arity = length(args) + bonus
    arg_reasons = Enum.flat_map(args, &scan/1)

    case mod do
      {:__aliases__, _, parts} ->
        modname = alias_name(parts)
        arg_reasons ++ check_module_call(modname, fun, arity)

      {:world, _, ctx} when not is_list(ctx) ->
        # Facade carve-out (REQ 4) — any call on the literal `world` param
        # is allowed; `Commonplace.MUD.World.Facade` is the audited surface.
        arg_reasons

      atom when is_atom(atom) ->
        # A module that has already been RESOLVED to an atom, not an
        # `{:__aliases__, ...}` node. This is how the parser emits the
        # `Kernel.to_string/1` injected by string interpolation
        # (`"a #{x}"`), and how any `:"Elixir.Foo"` literal appears.
        # Route Elixir-module atoms (`:"Elixir.X"`) back through the SAME
        # allowlist — so interpolation's Kernel.to_string passes while
        # `:"Elixir.System".cmd` is rejected exactly like `System.cmd`.
        # A NON-Elixir atom (`:os`, `:erlang`, …) has no allowlisted
        # surface and is rejected.
        case elixir_module_name(atom) do
          nil -> arg_reasons ++ [":#{atom}.#{fun}/#{arity} is not allowed"]
          modname -> arg_reasons ++ check_module_call(modname, fun, arity)
        end

      other ->
        arg_reasons ++ scan(other) ++ ["dynamic dispatch on a non-literal module/receiver is not allowed"]
    end
  end

  # `Kernel` (the atom `:"Elixir.Kernel"`) → "Kernel"; `:"Elixir.Enum"` →
  # "Enum"; a bare Erlang atom like `:os` → nil (not an Elixir module, no
  # allowlisted surface).
  defp elixir_module_name(atom) do
    case Atom.to_string(atom) do
      "Elixir." <> rest -> rest
      _ -> nil
    end
  end

  # VECTOR 11 — atom / module-name builders, pinned explicitly on ANY
  # module. `to_atom`/`to_existing_atom` grow the atom table from
  # player-influenced strings AND are the stepping stone to naming a
  # hostile module/function dynamically; `Module.concat` builds a module
  # atom from strings. (Closed-by-default already rejects each — String,
  # List, Module etc. don't list these — but they are named here.)
  defp check_module_call(_modname, fun, _arity) when fun in [:to_atom, :to_existing_atom] do
    ["#{fun} (atom construction) is not allowed on any module"]
  end

  defp check_module_call("Module", fun, arity) do
    ["Module.#{fun}/#{arity} (module-name construction / reflection) is not allowed"]
  end

  defp check_module_call("Kernel", fun, arity) do
    if MapSet.member?(@kernel_allowed, {fun, arity}) do
      []
    else
      ["Kernel.#{fun}/#{arity} is not allowed"]
    end
  end

  defp check_module_call(modname, fun, arity) do
    case Map.fetch(@allowed_modules, modname) do
      {:ok, allowed} ->
        if MapSet.member?(allowed, {fun, arity}) do
          []
        else
          ["#{modname}.#{fun}/#{arity} is not allowed"]
        end

      :error ->
        ["#{modname}.#{fun}/#{arity} is not allowed"]
    end
  end

  # `&Module.fun/arity` — walk INTO the capture; no explicit args to scan,
  # arity comes from the literal integer.
  defp scan_capture({:/, _, [{{:., _, [mod, fun]}, _, []}, arity]}) when is_integer(arity) do
    handle_call(mod, fun, [], arity)
  end

  # `&some_local/arity` — bare local/Kernel capture.
  defp scan_capture({:/, _, [{name, _, ctx}, arity]})
       when is_atom(name) and not is_list(ctx) and is_integer(arity) do
    if MapSet.member?(@kernel_allowed, {name, arity}) do
      []
    else
      ["capture &#{name}/#{arity} is not allowed"]
    end
  end

  # Partial capture, e.g. `&(&1 * 2)` — recurse normally; `&1`/`&2`
  # placeholders fall through to this same `scan_capture` as bare integers.
  defp scan_capture(other), do: scan(other)

  # `binds_reserved?/1` — does this PATTERN (assignment LHS, fn/case param,
  # for/with generator LHS) introduce a new binding named `world` or `args`?
  # `^var` is a pin (matches against the EXISTING value, does not rebind),
  # so it must not trip this check.
  defp binds_reserved?({:^, _, [_var]}), do: false
  defp binds_reserved?({name, _, ctx}) when name in [:world, :args] and not is_list(ctx), do: true
  defp binds_reserved?({_, _, args}) when is_list(args), do: Enum.any?(args, &binds_reserved?/1)
  defp binds_reserved?(list) when is_list(list), do: Enum.any?(list, &binds_reserved?/1)
  defp binds_reserved?({a, b}), do: binds_reserved?(a) or binds_reserved?(b)
  defp binds_reserved?(_), do: false
end
