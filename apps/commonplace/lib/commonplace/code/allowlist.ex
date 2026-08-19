defmodule Commonplace.Code.Allowlist do
  @moduledoc """
  CX-bg1v / CX-fogy (c) — the CORE, DOMAIN-AGNOSTIC closed-by-default AST
  allowlist: a scan over an author-submitted code BODY where every AST node/call
  must be explicitly recognized as permitted or the whole body is rejected.

  This is the language-level RCE wall. It was extracted verbatim from the
  safe-verb allowlist that previously lived in the game domain (CX-fogy plan
  #7548) so the structural bans no longer live in — nor can be weakened by — a
  domain module. This module references NO domain module: a caller injects ONLY a
  `Commonplace.Code.Allowlist.Profile` (pure DATA): its own least-authority facade
  surface + the wrapper shape its bodies are stored in. The `kernel`/`stdlib`
  allow-tables, the dynamic-dispatch / macro-surface / atom-construction
  rejections, and the closed-by-default fallback are FIXED here; the profile can
  only ADD a narrowly-scoped domain allow-set, never re-permit
  `eval`/`apply`/`spawn`/`System`/`File`/… .

  Unknown stdlib surface — anything this module hasn't been taught about — fails
  closed. This is the response to CX-bg1v (a user-authored MUD verb reached
  `System.cmd/2` and achieved RCE): a denylist can only ever enumerate the
  exploits someone already thought of; a closed-by-default allowlist doesn't
  have that gap.

  ## What's allowed (see module attributes below for the exact tables)

    * `Enum`/`Map`/`List`/`String`/`Integer`/`Float` — a curated,
      conservatively-picked {function, arity} allowlist per module.
      `String.to_atom/1` and `String.to_existing_atom/1` are deliberately
      EXCLUDED even though the rest of `String` is allowed — atom construction
      from author-influenced strings is an atom-table exhaustion vector and a
      stepping stone to constructing a hostile module/function reference
      dynamically.
    * Bare/`Kernel.`-qualified arithmetic, comparison, boolean, list/binary-
      concat, membership/range, `is_*` type guards, and a short list of harmless
      one-offs — see `@kernel_allowed`. Kernel is the trap: it also holds
      `apply`, `spawn`, `send`, `self`, `binary_to_atom`, etc. — none of those
      are on the list, so they fall through to the closed-by-default rejection.
    * Control flow: `fn`, `case`, `cond`, `if`/`unless`, `for`, `with`, `|>`,
      blocks, map/tuple/list/binary literals, a small set of harmless data
      sigils (`~c`, `~s`, `~w`). None of these can themselves name arbitrary
      code — they're pure structure.
    * The DOMAIN facade carve-out (INJECTED via the profile): a body reaches its
      least-authority surface through the QUALIFIED form
      `<profile.domain_module>.<fun>(<profile.receiver_var>, ...)` — a REMOTE
      call with the literal alias, the receiver var as the LITERAL first argument
      (`facade_receiver?/2`), and `{fun, arity}` on `profile.domain_allowed`.
      CX-fhz4: the dot form `recv.foo(...)` (struct dot-call WITH args) is NOT
      admitted. `recv.field` (no-parens field READ) is still allowed. The
      `profile.reserved_vars` (incl. the receiver) are protected from rebinding —
      the carve's safety depends on the receiver still being the original handle
      value where it is passed as the first argument.

  ## Structural rejections (REQ 2/3 — the "highest care" section)

  A `.`-call AST node has three shapes and they are NOT interchangeable:

    * `Enum.map(...)` — remote call with a LITERAL `{:__aliases__, ...}` module —
      checked against the per-module {fun, arity} table.
    * `m.key` (no parens, no args — `no_parens: true` meta flag) — a pure
      field/struct read, allowed unconditionally.
    * `var.fun(args)` / `var.fun()` — DYNAMIC dispatch on a non-literal-alias
      receiver. Rejected outright (INCLUDING the domain-receiver dot form; the
      working form is the qualified `<domain_module>.fun(recv, ...)`). This
      closes `mod = String.to_atom(...); mod.cmd(...)` and `w = System;
      w.cmd(...)`.

  `fun.(a, b)` — invoking a value held in a variable as a function
  (`{:., _, [callee]}` with a ONE-element dot arg list) — is also rejected; it's
  `apply` wearing different syntax. (So is an author's own `f.()` — a deliberate
  conservative call; restructure through `Enum`/`Map` combinators.)

  ## Captures walk INTO their target (REQ 5)

  `&System.cmd/2` embeds a full MFA reference without "calling" anything — `&`'s
  argument is walked exactly like a 0-arg call to the referenced `{m, f, a}`.
  Partial captures like `&(&1 * 2)` recurse; the `&1`/`&2` placeholders are
  variable reads.

  ## Macro-expansion soundness (VECTOR 10 — load-bearing dependency)

  This checker walks the PRE-EXPANSION AST. That is SOUND only because no
  author/foreign macro can run at expansion time: `alias`/`import`/`require`/
  `use`/`quote`/`unquote`/`defmacro`/`defmodule`/`defimpl`/`defprotocol` are each
  rejected. So "walk what was typed" == "walk what will execute." If any are ever
  re-admitted, this pre-expansion walk becomes UNSOUND and a `Macro.expand`-and-
  re-walk belt must be added first. (Protocols `inspect`/`to_string`/… are safe
  here only because `defimpl`/`defprotocol` are rejected.)

  ## GAP-1/GAP-2 (plan #7573 completeness review)

  Two construct-level escapes are closed: a bitstring type-spec can embed an
  executable expression (`<<x::size(evil())>>`), so `scan_bitstring_typespec/2`
  walks the type-spec (allowlisting only type atoms, literal sizes, `-`/`*`
  combinators, and `size`/`unit` with re-scanned args); and the compile-time
  reflection pseudo-vars (`__ENV__`, `__CALLER__`, `__MODULE__`, `__DIR__`,
  `__STACKTRACE__`, `super`) parse as variable-read-shaped nodes and are rejected
  before the var-read clause.

  ## Division of labor / honesty residual

  This module closes REACH — what code can NAME and invoke. It does NOT close
  resource exhaustion (loops, huge terms) — that's the caller's resource-bounds
  layer's job (wall-clock timeout + heap kill), orthogonal and still required
  alongside. Atom-table exhaustion IS closed here. An allowlist over a
  Turing-complete host cannot
  PROVE the audited pure surface side-effect-free — this is defense-in-depth over
  a rich language ("demo-grade safe for untrusted authors"), not a formal
  sandbox; OS-level isolation remains the phase-4 horizon.
  """

  alias Commonplace.Code.Allowlist.Profile

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
                    {:..//, 3},
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

  # VECTOR 11 — reflective / capability side-channels that WEAR a safe-looking
  # bare-local face. Closed-by-default already rejects every one (none is on any
  # allow table), but pinned here with explicit reasons so a reviewer sees each
  # named and nobody silently re-admits one by widening the Kernel set. Keyed by
  # name, rejected at ANY arity.
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

  @reserved_rebind_msg "reassignment of a reserved binding is not allowed"

  @doc """
  Scan `source` (a raw entry-function BODY text) under `profile`. Returns `:ok`,
  `{:error, {:disallowed, [String.t()]}}` (one message per distinct violation,
  deduplicated), or `{:error, {:syntax_error, String.t()}}` if the body doesn't
  parse as Elixir.
  """
  @spec check(String.t(), Profile.t()) ::
          :ok | {:error, {:disallowed, [String.t()]}} | {:error, {:syntax_error, String.t()}}
  def check(source, %Profile{} = profile) when is_binary(source) do
    case Code.string_to_quoted(source) do
      {:ok, ast} ->
        case scan_body_ast(ast, profile) do
          [] -> :ok
          reasons -> {:error, {:disallowed, reasons}}
        end

      {:error, {_meta, message, token}} ->
        {:error, {:syntax_error, "#{inspect(message)}#{inspect(token)}"}}
    end
  end

  @doc """
  The RUN-BOUNDARY re-verification. Where `check/2` scans a raw BODY, this takes
  the STORED, WRAPPED source (what the domain's wrapper produced + persisted) and
  re-derives trust from the bytes instead of trusting a filename. It:

    1. parses the text;
    2. verifies the AST is EXACTLY the substrate wrapper shape — a single
       top-level `defmodule <profile.wrapper_placeholder> do def
       <profile.wrapper_fun>(<profile.wrapper_params…>) do <body> end end`,
       nothing more — so a hand-edited / stale / foreign-replayed doc can't
       smuggle in unreviewed module-level code around a clean body;
    3. extracts `<body>` and runs it through the same `scan_body_ast/2` walk
       `check/2` uses, held to the identical allowlist bar.

  Returns `:ok` or `{:error, {:unsafe_verb, reason}}`, where `reason` is
  `{:syntax_error, message}`, `:not_substrate_wrapped`, or
  `{:disallowed, [String.t()]}`.
  """
  @spec check_wrapped(String.t(), Profile.t()) :: :ok | {:error, {:unsafe_verb, term()}}
  def check_wrapped(source, %Profile{} = profile) when is_binary(source) do
    case Code.string_to_quoted(source) do
      {:ok, ast} ->
        case extract_wrapped_body(ast, profile) do
          {:ok, body_ast} ->
            case scan_body_ast(body_ast, profile) do
              [] -> :ok
              reasons -> {:error, {:unsafe_verb, {:disallowed, reasons}}}
            end

          :error ->
            {:error, {:unsafe_verb, :not_substrate_wrapped}}
        end

      {:error, {_meta, message, token}} ->
        {:error, {:unsafe_verb, {:syntax_error, "#{inspect(message)}#{inspect(token)}"}}}
    end
  end

  # The EXACT shape the domain wrapper emits:
  #
  #     defmodule <wrapper_placeholder> do
  #       def <wrapper_fun>(<wrapper_params...>) do
  #         <body>
  #       end
  #     end
  #
  # i.e. a single top-level `defmodule` whose entire body is a single
  # `def <fun>(<params>) do ... end` — nothing else at module level.
  defp extract_wrapped_body(
         {:defmodule, _, [{:__aliases__, _, mod_parts}, [do: module_body]]},
         %Profile{} = profile
       ) do
    if alias_name(mod_parts) == profile.wrapper_placeholder do
      extract_run_body(module_body, profile)
    else
      :error
    end
  end

  defp extract_wrapped_body(_other, _profile), do: :error

  defp extract_run_body({:def, _, [{fun, _, params}, [do: body]]}, %Profile{} = profile)
       when is_list(params) do
    if fun == profile.wrapper_fun and params_named?(params, profile.wrapper_params) do
      {:ok, body}
    else
      :error
    end
  end

  defp extract_run_body(_other, _profile), do: :error

  # Every wrapper param must be a plain, un-rebound variable node whose name
  # matches the profile's `wrapper_params` in order (a `def run(world, args)`
  # head, never a call or destructuring pattern).
  defp params_named?(params, names) when length(params) == length(names) do
    params |> Enum.zip(names) |> Enum.all?(fn {param, name} -> var_named?(param, name) end)
  end

  defp params_named?(_params, _names), do: false

  defp var_named?({name, _, ctx}, name) when not is_list(ctx), do: true
  defp var_named?(_node, _name), do: false

  # ---- macro-surface entry points (VECTOR 10) — rejected outright -----
  # These are the ONLY ways a foreign/aliased name or an author-defined macro can
  # enter the body; the pre-expansion walk is sound ONLY because all of them are
  # refused here. Matched on the CALL form (`is_list(args)`) so a variable that
  # happens to share the name is untouched.
  defp scan({:alias, _, args}, _p) when is_list(args),
    do: ["alias is not allowed (would introduce a foreign/aliased module name)"]

  defp scan({:import, _, args}, _p) when is_list(args),
    do: ["import is not allowed (would bring foreign functions into bare-call scope)"]

  defp scan({:require, _, args}, _p) when is_list(args),
    do: ["require is not allowed (would arm a foreign macro for expansion)"]

  defp scan({:use, _, args}, _p) when is_list(args),
    do: ["use is not allowed (would inject a module's __using__ macro code)"]

  defp scan({:quote, _, args}, _p) when is_list(args),
    do: ["quote is not allowed (author-constructed AST)"]

  defp scan({:unquote, _, args}, _p) when is_list(args),
    do: ["unquote is not allowed (author-constructed AST)"]

  defp scan({def_form, _, args}, _p)
       when def_form in [:defmodule, :defmacro, :defmacrop, :defimpl, :defprotocol, :defdelegate] and
              is_list(args),
       do: [
         "#{def_form} is not allowed (a safe body is an entry-fn body, not a module/macro definition)"
       ]

  # ---- blocks / assignment ----------------------------------------

  defp scan({:__block__, _, args}, p) when is_list(args), do: Enum.flat_map(args, &scan(&1, p))

  defp scan({:=, _, [lhs, rhs]}, p) do
    base = scan(rhs, p) ++ scan(lhs, p)
    if binds_reserved?(lhs, p), do: base ++ [@reserved_rebind_msg], else: base
  end

  # ---- control flow --------------------------------------------------

  defp scan({:fn, _, clauses}, p) when is_list(clauses),
    do: Enum.flat_map(clauses, &scan_arrow_clause(&1, p))

  defp scan({:case, _, [subject, [do: clauses]]}, p) when is_list(clauses),
    do: scan(subject, p) ++ Enum.flat_map(clauses, &scan_arrow_clause(&1, p))

  defp scan({:cond, _, [[do: clauses]]}, p) when is_list(clauses),
    do: Enum.flat_map(clauses, &scan_cond_clause(&1, p))

  defp scan({branch, _, [cond_expr, kw]}, p) when branch in [:if, :unless] and is_list(kw) do
    scan(cond_expr, p) ++ scan(Keyword.get(kw, :do), p) ++ scan(Keyword.get(kw, :else), p)
  end

  defp scan({:for, _, args}, p) when is_list(args), do: scan_for(args, p)
  defp scan({:with, _, args}, p) when is_list(args), do: scan_with(args, p)

  defp scan({:|>, _, [lhs, rhs]}, p), do: scan(lhs, p) ++ scan_pipe_rhs(rhs, p)

  # ---- `.` operator: three forms, one structural trap -----------------

  # `fun.(a, b)` — invoking a held value as a function. Apply-in-disguise.
  defp scan({{:., _, [callee]}, _, args}, p) when is_list(args) do
    ["dynamic function invocation (`var.(...)`) is not allowed"] ++
      scan(callee, p) ++ Enum.flat_map(args, &scan(&1, p))
  end

  # `mod.fun(...)` / `mod.fun` / `mod.fun()` — remote call or field read.
  defp scan({{:., _, [mod, fun]}, meta2, args}, p) when is_atom(fun) and is_list(args) do
    if (args == [] and Keyword.get(meta2, :no_parens)) && var_node?(mod) do
      scan(mod, p)
    else
      handle_call(mod, fun, args, 0, p)
    end
  end

  # ---- captures --------------------------------------------------------

  defp scan({:&, _, [inner]}, p), do: scan_capture(inner, p)

  # ---- struct / map / binary literals -----------------------------------

  defp scan({:%, _, [_struct_mod, map]}, p) do
    ["struct construction is not allowed"] ++ scan(map, p)
  end

  defp scan({:%{}, _, [{:|, _, [base_map, kvs]}]}, p), do: scan(base_map, p) ++ scan_pairs(kvs, p)
  defp scan({:%{}, _, pairs}, p) when is_list(pairs), do: scan_pairs(pairs, p)

  defp scan({:<<>>, _, parts}, p) when is_list(parts),
    do: Enum.flat_map(parts, &scan_bitstring_part(&1, p))

  # ---- sigils (data-only allowlist) -------------------------------------

  defp scan({sigil, _, [str, _mods]}, p) when sigil in @allowed_sigils, do: scan(str, p)

  # ---- standalone module alias reference (e.g. `mod = System`) ---------

  defp scan({:__aliases__, _, parts}, _p) when is_list(parts) do
    ["reference to module #{alias_name(parts)} is not allowed outside an allowlisted call"]
  end

  # ---- cons cell `[h | t]` (list destructure/construct) — pure structure -
  # `[h | t]` parses to `{:|, _, [head, tail]}`. Ordinary list cons — no code
  # execution — so recurse into both sides. (Map update `%{m | ..}` has its own
  # clause; this is the bare-list cons.)
  defp scan({:|, _, [head, tail]}, p), do: scan(head, p) ++ scan(tail, p)

  # ---- N-element tuple literal ({:{}, _, elems}, i.e. 3+ elements) --------
  # Pure data. 2-tuples are the literal `{a, b}` form (handled below); tuples of
  # 3+ elements use this call-SHAPED AST (`:{}` in head position). Recurse into
  # the elements so an embedded call is still caught — the tuple names no code.
  defp scan({:{}, _, elems}, p) when is_list(elems), do: Enum.flat_map(elems, &scan(&1, p))

  # ---- variable read -----------------------------------------------------

  # GAP-2 (plan #7573): the compile-time reflection pseudo-vars parse as
  # `{name, _, nil}` — the SAME shape as a variable read — so the var-read clause
  # below would silently ALLOW them. Reject the reserved set explicitly (a cheap
  # belt) BEFORE the var-read.
  defp scan({name, _, ctx}, _p)
       when name in [:__ENV__, :__CALLER__, :__MODULE__, :__DIR__, :__STACKTRACE__, :super] and
              not is_list(ctx),
       do: ["reserved pseudo-variable #{name} is not allowed (compile-time reflection)"]

  defp scan({name, _, ctx}, _p) when is_atom(name) and not is_list(ctx), do: []

  # ---- generic local call fallback (closed by default) -------------------

  defp scan({name, _, args}, p) when is_atom(name) and is_list(args) do
    handle_local(name, args, 0, p)
  end

  # ---- literals / plain data ----------------------------------------------

  defp scan(node, _p) when is_number(node) or is_binary(node) or is_atom(node), do: []
  defp scan(node, p) when is_list(node), do: Enum.flat_map(node, &scan(&1, p))
  defp scan({a, b}, p), do: scan(a, p) ++ scan(b, p)

  # ---- closed by default: anything else is rejected -----------------------

  defp scan(_other, _p), do: ["unrecognized syntax construct is not allowed"]

  # === helpers =============================================================

  # Shared by `check/2` (raw body text) and `check_wrapped/2` (body AST extracted
  # from a verified wrapper) — the SAME allowlist walk, deduped.
  defp scan_body_ast(ast, profile), do: scan(ast, profile) |> Enum.uniq()

  defp alias_name(parts), do: parts |> Enum.map(&to_string/1) |> Enum.join(".")

  defp var_node?({name, _, ctx}) when is_atom(name) and not is_list(ctx), do: true
  defp var_node?(_), do: false

  # CX-fhz4 — is the FIRST argument of a `<domain_module>.*` call the literal
  # bound receiver param (not some other variable/value merely sharing the name
  # in a nested scope — a plain variable-read node)?
  defp facade_receiver?([{recv, _, ctx} | _], recv) when not is_list(ctx), do: true
  defp facade_receiver?(_args, _recv), do: false

  defp scan_pairs(pairs, p) when is_list(pairs) do
    Enum.flat_map(pairs, fn
      {k, v} -> scan(k, p) ++ scan(v, p)
      other -> scan(other, p)
    end)
  end

  # GAP-1 (plan #7573): a bitstring segment's type-spec can EMBED an executable
  # expression — `<<x::size(evil_call())>>` runs `evil_call()` at runtime before
  # any type error — but the old code scanned only `expr` and IGNORED the
  # type-spec, an allowlist ESCAPE. Now walk the type-spec too.
  defp scan_bitstring_part({:"::", _, [expr, type_spec]}, p),
    do: scan(expr, p) ++ scan_bitstring_typespec(type_spec, p)

  defp scan_bitstring_part(other, p), do: scan(other, p)

  # A type-spec may contain ONLY: type atoms (`integer` == `{:integer,_,nil}`,
  # `:utf8`, ...), literal size ints, `-`/`*` combinators, and `size(_)`/`unit(_)`
  # whose argument is re-scanned with the FULL allowlist (so `size(8)` / `size(n)`
  # [a var] pass, but `size(evil())` [a call] is rejected). Anything else →
  # closed-by-default reject. Closing the one construct-level RCE hole plan found.
  defp scan_bitstring_typespec({op, _, [a, b]}, p) when op in [:-, :*],
    do: scan_bitstring_typespec(a, p) ++ scan_bitstring_typespec(b, p)

  defp scan_bitstring_typespec({fun, _, [arg]}, p) when fun in [:size, :unit], do: scan(arg, p)

  defp scan_bitstring_typespec({name, _, ctx}, _p) when is_atom(name) and not is_list(ctx), do: []

  defp scan_bitstring_typespec(spec, _p) when is_integer(spec) or is_atom(spec), do: []

  defp scan_bitstring_typespec(_other, _p),
    do: [
      "disallowed bitstring type-spec (only type atoms, literal sizes, `-`/`*` combinators, and size/unit with allowlisted args)"
    ]

  # `when`-guarded pattern lists are wrapped as a single `{:when, _, args}`
  # element whose LAST element is the guard expression and whose preceding
  # elements are the real patterns. Unguarded clauses have no such wrapper.
  defp split_when([{:when, _, when_args}]) when is_list(when_args) do
    {patterns, [guard]} = Enum.split(when_args, length(when_args) - 1)
    {patterns, guard}
  end

  defp split_when(params), do: {params, nil}

  # Shared by `fn` clauses, `case` clauses, and `with`'s `:else` clauses.
  defp scan_arrow_clause({:->, _, [params, body]}, p) do
    {patterns, guard} = split_when(params)

    bind_reason =
      if Enum.any?(patterns, &binds_reserved?(&1, p)), do: [@reserved_rebind_msg], else: []

    guard_reasons = if guard, do: scan(guard, p), else: []

    bind_reason ++ guard_reasons ++ Enum.flat_map(patterns, &scan(&1, p)) ++ scan(body, p)
  end

  # `cond` clauses have no binding pattern — just a boolean guard expression.
  defp scan_cond_clause({:->, _, [[guard_expr], body]}, p),
    do: scan(guard_expr, p) ++ scan(body, p)

  defp scan_for(args, p) do
    {kw, clauses} = List.pop_at(args, -1)

    kw_reasons =
      case kw do
        kw when is_list(kw) -> Enum.flat_map(kw, fn {_k, v} -> scan(v, p) end)
        other -> scan(other, p)
      end

    kw_reasons ++ Enum.flat_map(clauses, &scan_generator_or_filter(&1, p))
  end

  defp scan_with(args, p) do
    {kw, clauses} = List.pop_at(args, -1)

    kw = if is_list(kw), do: kw, else: []

    do_reasons = scan(Keyword.get(kw, :do), p)

    else_reasons =
      case Keyword.get(kw, :else) do
        else_clauses when is_list(else_clauses) ->
          Enum.flat_map(else_clauses, &scan_arrow_clause(&1, p))

        _ ->
          []
      end

    other_kw_reasons =
      kw
      |> Keyword.drop([:do, :else])
      |> Enum.flat_map(fn {_k, v} -> scan(v, p) end)

    do_reasons ++
      else_reasons ++ other_kw_reasons ++ Enum.flat_map(clauses, &scan_generator_or_filter(&1, p))
  end

  defp scan_generator_or_filter({:<-, _, [pattern, expr]}, p) do
    base = scan(expr, p) ++ scan(pattern, p)
    if binds_reserved?(pattern, p), do: base ++ [@reserved_rebind_msg], else: base
  end

  defp scan_generator_or_filter(other, p), do: scan(other, p)

  # Pipe RHS is always a call — apply the same allowlist checks as a normal
  # `.`-call or bare local call, but with the piped-in LHS counted as one extra
  # (implicit) argument for arity purposes (`length(explicit_args)+1`).
  defp scan_pipe_rhs({{:., _, [mod, fun]}, _, args}, p) when is_atom(fun) and is_list(args) do
    handle_call(mod, fun, args, 1, p)
  end

  defp scan_pipe_rhs({name, _, args}, p) when is_atom(name) and is_list(args) do
    handle_local(name, args, 1, p)
  end

  defp scan_pipe_rhs(other, p), do: scan(other, p) ++ ["dynamic pipe target is not allowed"]

  defp handle_local(name, args, bonus, p) do
    arity = length(args) + bonus
    arg_reasons = Enum.flat_map(args, &scan(&1, p))

    cond do
      Map.has_key?(@dangerous_locals, name) ->
        # VECTOR 11 — explicit pin (would fall to closed-by-default anyway, but
        # named so a reviewer sees each reflective side-channel).
        arg_reasons ++ [Map.fetch!(@dangerous_locals, name)]

      MapSet.member?(@kernel_allowed, {name, arity}) ->
        arg_reasons

      true ->
        arg_reasons ++ ["#{name}/#{arity} is not allowed"]
    end
  end

  defp handle_call(mod, fun, args, bonus, %Profile{} = profile) when is_atom(fun) do
    arity = length(args) + bonus
    arg_reasons = Enum.flat_map(args, &scan(&1, profile))

    case mod do
      {:__aliases__, _, parts} ->
        modname = alias_name(parts)

        # CX-fhz4 — the qualified-call half of the DOMAIN facade carve-out
        # (REQ 4), injected via the profile. `recv.foo(...)` (struct dot-call
        # WITH args) is not valid Elixir dispatch (`recv` is a struct value, not
        # a module atom, so `apply/3` on it crashes at runtime); the calling
        # convention every author actually uses is the qualified form
        # `<domain_module>.foo(recv, ...)`. Admit it ONLY when the call's first
        # argument is the literal bound receiver param and `{fun, arity}` is on
        # the domain's allow-set (data). This doesn't widen WHAT can be reached
        # (the core bans are fixed) — it only names the domain's own surface.
        if modname == profile.domain_module and facade_receiver?(args, profile.receiver_var) and
             MapSet.member?(profile.domain_allowed, {fun, arity}) do
          arg_reasons
        else
          arg_reasons ++ check_module_call(modname, fun, arity)
        end

      atom when is_atom(atom) ->
        # A module already RESOLVED to an atom (not an `{:__aliases__, ...}`
        # node). This is how string interpolation's `Kernel.to_string/1` and any
        # `:"Elixir.Foo"` literal appear. Route Elixir-module atoms back through
        # the SAME allowlist; a NON-Elixir atom (`:os`, `:erlang`, …) has no
        # allowlisted surface and is rejected.
        case elixir_module_name(atom) do
          nil -> arg_reasons ++ [":#{atom}.#{fun}/#{arity} is not allowed"]
          modname -> arg_reasons ++ check_module_call(modname, fun, arity)
        end

      other ->
        arg_reasons ++
          scan(other, profile) ++
          ["dynamic dispatch on a non-literal module/receiver is not allowed"]
    end
  end

  # `Kernel` (the atom `:"Elixir.Kernel"`) → "Kernel"; `:"Elixir.Enum"` → "Enum";
  # a bare Erlang atom like `:os` → nil (not an Elixir module, no surface).
  defp elixir_module_name(atom) do
    case Atom.to_string(atom) do
      "Elixir." <> rest -> rest
      _ -> nil
    end
  end

  # VECTOR 11 — atom / module-name builders, pinned explicitly on ANY module.
  # `to_atom`/`to_existing_atom` grow the atom table from author-influenced
  # strings AND are the stepping stone to naming a hostile module/function
  # dynamically; `Module.concat` builds a module atom from strings. (Closed-by-
  # default already rejects each — String/List/Module etc. don't list these —
  # but they are named here.)
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

  # `&Module.fun/arity` — walk INTO the capture; no explicit args to scan, arity
  # comes from the literal integer.
  defp scan_capture({:/, _, [{{:., _, [mod, fun]}, _, []}, arity]}, p) when is_integer(arity) do
    handle_call(mod, fun, [], arity, p)
  end

  # `&some_local/arity` — bare local/Kernel capture.
  defp scan_capture({:/, _, [{name, _, ctx}, arity]}, _p)
       when is_atom(name) and not is_list(ctx) and is_integer(arity) do
    if MapSet.member?(@kernel_allowed, {name, arity}) do
      []
    else
      ["capture &#{name}/#{arity} is not allowed"]
    end
  end

  # Partial capture, e.g. `&(&1 * 2)` — recurse normally; `&1`/`&2` placeholders
  # fall through to this same `scan_capture` as bare integers.
  defp scan_capture(other, p), do: scan(other, p)

  # `binds_reserved?/2` — does this PATTERN (assignment LHS, fn/case param,
  # for/with generator LHS) introduce a new binding named in `profile.
  # reserved_vars`? `^var` is a pin (matches against the EXISTING value, does not
  # rebind), so it must not trip this check.
  defp binds_reserved?({:^, _, [_var]}, _p), do: false

  defp binds_reserved?({name, _, ctx}, %Profile{reserved_vars: reserved})
       when is_atom(name) and not is_list(ctx),
       do: name in reserved

  defp binds_reserved?({_, _, args}, p) when is_list(args),
    do: Enum.any?(args, &binds_reserved?(&1, p))

  defp binds_reserved?(list, p) when is_list(list), do: Enum.any?(list, &binds_reserved?(&1, p))
  defp binds_reserved?({a, b}, p), do: binds_reserved?(a, p) or binds_reserved?(b, p)
  defp binds_reserved?(_other, _p), do: false
end
