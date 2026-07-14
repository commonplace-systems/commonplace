defmodule Commonplace.MUD.SafeVerb.Allowlist do
  @moduledoc """
  CX-bg1v / CX-fogy (c) — the MUD-domain safe-verb allowlist, now a THIN SHIM
  over the core, domain-agnostic `Commonplace.Code.Allowlist`.

  The structural, language-level RCE bans (the `kernel`/`stdlib` allow-tables,
  the dynamic-dispatch / macro-surface / atom-construction rejections, the
  closed-by-default fallback, `check_wrapped`'s wrapper-shape gate, and the
  GAP-1/GAP-2 completeness fixes) ALL live in `Commonplace.Code.Allowlist` — core-
  owned, so no MUD change can weaken them (CX-fogy plan #7548: the RCE wall must
  not structurally depend on a game-domain module). This module contributes ONLY
  the MUD's own DATA: the least-authority `Commonplace.MUD.World.Facade` action
  set (`@facade_allowed`) and the safe-verb wrapper shape, bundled into a
  `Commonplace.Code.Allowlist.Profile` and passed DOWN to the core validator. It
  can NAME the MUD's capability surface; it cannot re-permit `eval`/`apply`/… .

  `check/1` and `check_wrapped/1` keep their pre-(c) signatures (a raw `run/2`
  BODY, and the stored wrapped source, respectively) so every MUD caller —
  `SafeVerb.compile`, `Commonplace.Trust`'s write-fork classifier (via the core),
  the tests — is unchanged. See `Commonplace.Code.Allowlist` for the full
  admit/reject surface and the honesty residual (it closes REACH, not resource
  exhaustion — `Commonplace.MUD.SafeVerb.Bounds` remains required alongside).

  ## The facade action set (`@facade_allowed`) — a MUD SECURITY decision

  Each entry is an audited least-authority capability on
  `Commonplace.MUD.World.Facade`; adding one here is a security decision (keep in
  sync with that module's public surface). Explicit `{fun, arity}` — NOT the
  whole module — so the constructor `new/5` (author-controlled object_uuid +
  owner_grant → a facade bound to a victim object) is NOT reachable. Arities are
  the Facade functions' own arities (the `world` receiver is the first arg).
  """

  alias Commonplace.Code.Allowlist, as: Core
  alias Commonplace.Code.Allowlist.Profile

  # CX-fhz4 — the facade ACTION surface, admitted for
  # `Commonplace.MUD.World.Facade.<fun>(world, ...)` calls. NOT the constructor
  # `new/5`. (History of each entry preserved from the pre-(c) module.)
  @facade_allowed MapSet.new([
                    {:look, 1},
                    {:describe, 2},
                    {:get_attr, 2},
                    # CX-cj3t.9 (plan #6069) — the move SPLIT, replacing the
                    # retired ambiguous {:move,2}. move_self = presence-self (no
                    # room-write); move_object = both-rooms intersection.
                    {:move_self, 2},
                    {:move_object, 2},
                    {:set_attr, 3},
                    {:create_child, 2},
                    {:transfer, 3},
                    {:say, 2},
                    {:emit, 2},
                    # CX-aw4r — server-attributed action broadcast (plan #5955).
                    {:emit_action, 3},
                    # CX-hqk5 — freeform per-object state (plan #5968).
                    {:get_state, 2},
                    {:put_state, 3},
                    # CX-9plf — sanctioned RNG (no effect/authority).
                    {:random, 2},
                    {:pick, 2},
                    # CX-cj3t.1.1 — object lifecycle (plan #5991). spawn/consume/
                    # destroy_child are STRICT-INTERSECTION; give_to_actor is the
                    # ONE named exception (invoker's OWN inventory, server-fixed
                    # recipient). Bounded (per-container M=128, per-invocation N=8).
                    {:spawn, 2},
                    {:give_to_actor, 2},
                    # CX-coo8 — WORLD REWARD GRANT (plan #7895): node-signed mint into
                    # the invoker's inventory, gated by object_owner_authority(host)→node
                    # (anti-farm: only a node-owned/curated host fires) + stamped the
                    # recipient's players/-zone (anti-forge: node_owned?(reward)=false).
                    {:grant, 2},
                    {:consume, 1},
                    {:destroy_child, 2},
                    # CX-nyj9 — configure a FRESHLY-MINTED object (plan #6028/#6032).
                    {:configure_attr, 4},
                    {:configure_state, 4},
                    # CX-hbua — own-inventory introspection (gated-content primitive).
                    {:actor_carries?, 2},
                    # CX-cj3t.10 — directed private messaging (same-room + rate cap).
                    {:whisper, 3},
                    # CX-5u5j — own-inventory quest/gift verbs (plan #6171).
                    {:consume_from_inventory, 2},
                    {:give_from_inventory, 3},
                    # CX-a2gd — read the SERVER-SET invoker identity (plan #6189/#6193).
                    {:actor_name, 1},
                    {:actor_ref, 1},
                    # CX-<notify> — invoker-PRIVATE non-speech feedback.
                    {:notify, 2},
                    # CX-open_exit (plan design-doc 2026-07-13) — trust-gated
                    # exit-mutation: a DATA write to the source room's `exits` map
                    # (write ⟂ execute; no new cert). Gate A (source room-:write /
                    # curated host-gate), Gate B (dest self-or-public, anti-
                    # intrusion, judged on the invoker), Gate C (idempotent/add-only).
                    {:open_exit, 3}
                  ])

  @profile %Profile{
    domain_module: "Commonplace.MUD.World.Facade",
    domain_allowed: @facade_allowed,
    receiver_var: :world,
    reserved_vars: [:world, :args],
    wrapper_placeholder: Commonplace.MUD.SafeVerb.placeholder_module(),
    wrapper_fun: :run,
    wrapper_params: [:world, :args]
  }

  @doc "The MUD safe-verb `Commonplace.Code.Allowlist.Profile` (the facade + wrapper DATA)."
  @spec profile() :: Profile.t()
  def profile, do: @profile

  @doc """
  Scan `source` (the raw `run/2` BODY text) under the MUD profile. Same return
  contract as `Commonplace.Code.Allowlist.check/2`.
  """
  @spec check(String.t()) ::
          :ok | {:error, {:disallowed, [String.t()]}} | {:error, {:syntax_error, String.t()}}
  def check(source) when is_binary(source), do: Core.check(source, @profile)

  @doc """
  The RUN-BOUNDARY re-verification over the STORED, WRAPPED source under the MUD
  profile. Same return contract as `Commonplace.Code.Allowlist.check_wrapped/2`.
  """
  @spec check_wrapped(String.t()) :: :ok | {:error, {:unsafe_verb, term()}}
  def check_wrapped(source) when is_binary(source), do: Core.check_wrapped(source, @profile)
end
