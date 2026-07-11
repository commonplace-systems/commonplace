defmodule Commonplace.Code.Allowlist.Profile do
  @moduledoc """
  CX-fogy (c) core-move — the DOMAIN VOCABULARY a `Commonplace.Code.Allowlist`
  scan consults, injected as pure DATA (not a code callback).

  `Commonplace.Code.Allowlist` owns the STRUCTURAL, language-level RCE bans
  (kernel/stdlib allow-tables, dynamic-dispatch/macro-surface/atom-construction
  rejections, the closed-by-default fallback). Those are FIXED in core — no
  caller can weaken them. What a caller (a domain like the MUD) is allowed to
  supply is only this profile: an ADDITIVE, narrowly-scoped least-authority
  surface (a facade allow-set + the wrapper shape its verbs are stored in). A
  domain can therefore NAME its own capability surface, but can never re-permit
  `eval`/`apply`/`spawn`/… — those live in the core bans, out of reach of this
  data.

  ## Fields

    * `:domain_module` — the fully-qualified module name (a STRING, e.g.
      `"Commonplace.MUD.World.Facade"`) whose functions are the domain's
      least-authority surface. A remote call `<domain_module>.<fun>(<recv>, …)`
      is admitted iff `<recv>` is the literal `:receiver_var` param AND
      `{fun, arity}` is in `:domain_allowed`. NOTHING else about this module is
      special — it's matched by its literal alias, same as any allow-table.
    * `:domain_allowed` — `MapSet` of `{fun, arity}` admitted on `:domain_module`
      (the ONLY domain-specific admit; the constructor `new/…` is deliberately
      NOT included by any well-formed profile).
    * `:receiver_var` — the atom the domain call's first argument MUST literally
      be (e.g. `:world`) for the carve to apply — the least-authority handle the
      wrapper binds. Protected from rebinding (see `:reserved_vars`).
    * `:reserved_vars` — atoms that may not be re-bound anywhere in the body
      (`world = System`, a destructuring pattern shadowing the handle, …). The
      carve's safety depends on `:receiver_var` still holding the original handle
      where it is passed as the first argument, so every rebinding site is
      rejected.
    * `:wrapper_placeholder` — the module name (a STRING, e.g.
      `"Commonplace.MUD.SafeVerbBody"`, compared against the dotted alias) the
      stored, wrapped source uses at its single top-level `defmodule` (see
      `check_wrapped/2`). A stored doc whose wrapper names a different module is
      rejected as not-substrate-wrapped.
    * `:wrapper_fun` / `:wrapper_params` — the wrapped entry function's name
      (e.g. `:run`) and its parameter names (e.g. `[:world, :args]`). The stored
      wrapper must be exactly `def <wrapper_fun>(<wrapper_params…>) do <body> end`
      and nothing else at module level.
  """

  @enforce_keys [
    :domain_module,
    :domain_allowed,
    :receiver_var,
    :reserved_vars,
    :wrapper_placeholder,
    :wrapper_fun,
    :wrapper_params
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          domain_module: String.t(),
          domain_allowed: MapSet.t({atom(), non_neg_integer()}),
          receiver_var: atom(),
          reserved_vars: [atom()],
          wrapper_placeholder: String.t(),
          wrapper_fun: atom(),
          wrapper_params: [atom()]
        }
end
