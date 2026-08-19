defmodule Commonplace.Invariants.Registry do
  @moduledoc """
  The declared set of `%Commonplace.Invariants.Invariant{}` objects,
  per the 2026-08-05 resting-state invariants design
  (`docs/plans/2026-08-05-resting-state-invariants-design.md`, §4.1:
  "Invariant registry: declared objects... Registry is a doc,
  naturally"). This is step 1 of the build shape (§4) — the four base
  invariants named there ("parses; acyclic(needs); ref-typed fields;
  closed-ticket-matches-pin"), declared as data rather than hardcoded
  into a runner.

  ## Step 1 scope: bd only, alarm-only

  Every invariant registered here has `domain: :bd` and
  `responses: [:alarm]`. Step 1 wires no enforcement — the choke-bound
  engine (§4 build-shape item 2), block-promotion (§2 item 2), and
  deterministic repair (§2 item 3) are none of them built yet. A
  registry entry declaring `:block_promotion` or
  `:deterministic_repair` today would be a claim the engine cannot
  honour; `Commonplace.Invariants.Engine.run/2`'s
  `unimplemented_responses` exists to make exactly that kind of gap
  visible if a future entry ever adds one before the wiring lands, but
  step 1 does not exercise that path — nothing declared here needs it.

  ## What's delegated vs what's new

  All four `check`/`enumerate` funs delegate to the existing, already
  battle-tested pure checks in `Commonplace.Bd.Invariants`
  (`parses/3`, `ref_typed/3`, `closed_matches_pin/3`, `acyclic/2`, and
  the newly-public `ticket_ids/2`). This module does not reimplement
  any check logic — it only gives the existing functions a declared
  shape the generic `Engine` can run uniformly. See
  `Commonplace.Bd.Invariants`'s moduledoc for the substance of each
  check (in particular the CX-o3ar corruption class and the
  provenance-not-position pin design).
  """

  alias Commonplace.Bd.Invariants, as: BdInvariants
  alias Commonplace.Invariants.Invariant

  @doc """
  Every registered invariant, built through `Invariant.new!/1` (so a
  malformed entry fails loudly at first use, not at whatever moment
  someone happens to fetch it) and passed through `validate!/1` (so a
  duplicate name is loud too).
  """
  @spec all() :: [Invariant.t()]
  def all() do
    [
      Invariant.new!(
        name: :bd_parses,
        scope: %{domain: :bd, granularity: :per_subject},
        enumerate: fn %{root_uuid: root_uuid, store: store} ->
          BdInvariants.ticket_ids(root_uuid, store)
        end,
        check: fn %{root_uuid: root_uuid, store: store}, subject ->
          BdInvariants.parses(root_uuid, subject, store)
        end,
        responses: [:alarm],
        deferral: :immediate,
        owner: "commonplace",
        doc: """
        The base invariant: does a ticket's `__issue.json` decode into
        an `%Issue{}` at all? Every other bd invariant presupposes a
        parseable issue; this is the one that can fire when that
        presupposition itself is false. Catches the CX-o3ar corruption
        class (concurrent whole-blob rewrites of the same Yjs Text
        leaf concatenating into unparseable JSON). Decidable from the
        arriving state alone — either it parses or it doesn't — so
        :immediate.
        """
      ),
      Invariant.new!(
        name: :bd_ref_typed,
        scope: %{domain: :bd, granularity: :per_subject},
        enumerate: fn %{root_uuid: root_uuid, store: store} ->
          BdInvariants.ticket_ids(root_uuid, store)
        end,
        check: fn %{root_uuid: root_uuid, store: store}, subject ->
          BdInvariants.ref_typed(root_uuid, subject, store)
        end,
        responses: [:alarm],
        deferral: :immediate,
        owner: "commonplace",
        doc: """
        Re-judges a ticket's CURRENT `needs`/`done_witness` shape
        against the same rules `WriteGuard.check/5` enforces on a
        write — a resting-state audit exists precisely to catch
        writes that landed by some path other than the gated one (a
        merge, a direct store write, a future bug in a new caller).
        Decidable from the arriving state alone: :immediate.
        """
      ),
      Invariant.new!(
        name: :bd_closed_matches_pin,
        scope: %{domain: :bd, granularity: :per_subject},
        enumerate: fn %{root_uuid: root_uuid, store: store} ->
          BdInvariants.ticket_ids(root_uuid, store)
        end,
        check: fn %{root_uuid: root_uuid, store: store}, subject ->
          BdInvariants.closed_matches_pin(root_uuid, subject, store)
        end,
        responses: [:alarm],
        deferral: :context_dependent,
        owner: "commonplace",
        doc: """
        Compares a closed ticket's CURRENT frozen-subset fields
        (status/done_when/done_witness) against the values recorded
        in its terminal-state pin, read by walking commit history for
        the latest gate-stamped close (see `Commonplace.Bd.Invariants`
        moduledoc's "provenance, not position"). This is the ONLY
        `:context_dependent` entry in this registry, and that
        classification is a DESIGN JUDGMENT, not a measurement: the
        comparand is read from ancestry, not from the arriving state
        itself. If the relevant history is not present when this
        check runs (e.g. a shallow or partial view of the commit
        chain), `latest_stamped_pin/2` finds no stamp and the check
        returns `:ok` — a FALSE GREEN, not a genuine absence of a
        pin, because "no pin found" and "no pin exists" are
        indistinguishable from inside the check. That is precisely
        the design's context-dependent class (§4 build-shape item 1:
        "context-dependent... needs the source present and readable")
        as opposed to the other three entries here, each of which is
        fully decided by the one ticket's current, already-resolved
        state.
        """
      ),
      Invariant.new!(
        name: :bd_acyclic,
        scope: %{domain: :bd, granularity: :whole},
        enumerate: nil,
        check: fn %{root_uuid: root_uuid, store: store} ->
          BdInvariants.acyclic(root_uuid, store)
        end,
        responses: [:alarm],
        deferral: :immediate,
        owner: "commonplace",
        doc: """
        Directed-cycle check (DFS / back-edge test) over the whole
        corpus's local `needs` digraph. Whole-corpus, not per-ticket —
        a cycle is a property of the graph, not of any one node in
        it. Deliberately not `Frontier.stranded_components/2`, whose
        undirected component walk misses a cycle sharing a component
        with any ready ticket (see §3 of the design doc and
        `Commonplace.Bd.Invariants.acyclic/2`'s moduledoc). Decidable
        from the arriving state alone: :immediate.
        """
      )
    ]
    |> validate!()
  end

  @doc """
  Raises `ArgumentError` (naming the duplicate) if `invariants` contains
  two entries with the same `:name`. `all/0` runs every registered
  invariant through this, so a duplicate is loud the first time
  anything asks for the registry — not a silent shadow where only one
  of the two ever runs.
  """
  @spec validate!([Invariant.t()]) :: [Invariant.t()]
  def validate!(invariants) do
    invariants
    |> Enum.map(& &1.name)
    |> Enum.frequencies()
    |> Enum.filter(fn {_name, count} -> count > 1 end)
    |> case do
      [] ->
        invariants

      duplicates ->
        names = duplicates |> Enum.map(&elem(&1, 0)) |> Enum.sort()

        raise ArgumentError,
              "Commonplace.Invariants.Registry: duplicate invariant name(s) #{inspect(names)} " <>
                "— every invariant name must be unique within a registry"
    end
  end

  @doc """
  Fetches one invariant by name. Raises `ArgumentError` (listing every
  known name) if `name` isn't registered — a typo'd name should say
  what IS available, not just fail.
  """
  @spec fetch!(atom()) :: Invariant.t()
  def fetch!(name) do
    case Enum.find(all(), &(&1.name == name)) do
      nil ->
        known = all() |> Enum.map(& &1.name) |> Enum.sort()

        raise ArgumentError,
              "Commonplace.Invariants.Registry: no invariant named #{inspect(name)} — " <>
                "known invariants: #{inspect(known)}"

      invariant ->
        invariant
    end
  end

  @doc "Every registered invariant whose `scope.domain` matches `domain`."
  @spec for_domain(atom()) :: [Invariant.t()]
  def for_domain(domain) do
    Enum.filter(all(), &(&1.scope.domain == domain))
  end
end
