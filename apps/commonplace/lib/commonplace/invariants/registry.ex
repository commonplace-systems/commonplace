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

  ## Domain is a declared dimension; responses are alarm-only so far

  Every invariant DECLARES its `scope.domain` — domain is a SCHEMA
  DIMENSION, not a contract boundary (plan #13391). The Dispatcher runs
  `all/0` grouped by `scope.domain`, so a new domain is a new MEMBER, not
  a new registry: binding this registry to one domain would be binding to
  the enumeration, the rot R1 was written against. The bd invariants were
  the first members (`domain: :bd`); `:commit` (Hazard 3 — the
  accepted-head antichain, `Commonplace.Store.CommitInvariants`) is the
  second, scoped to the docs that advanced this batch (see its entry).

  Every entry today still declares `responses: [:alarm]`. Enforcement is
  wired for none of them — the choke-bound
  engine (§4 build-shape item 2), block-promotion (§2 item 2), and
  deterministic repair (§2 item 3) are none of them built yet. A
  registry entry declaring `:block_promotion` or
  `:deterministic_repair` today would be a claim the engine cannot
  honour; `Commonplace.Invariants.Engine.run/2`'s
  `unimplemented_responses` exists to make exactly that kind of gap
  visible if a future entry ever adds one before the wiring lands, but
  step 1 does not exercise that path — nothing declared here needs it.

  ## What's delegated vs what's new

  The bd `check`/`enumerate` funs delegate to the existing, already
  battle-tested pure checks in `Commonplace.Bd.Invariants`
  (`parses/3`, `ref_typed/3`, `closed_matches_pin/3`, `acyclic/2`, and
  the newly-public `ticket_ids/2`); the `:commit` entry delegates to
  `Commonplace.Store.CommitInvariants.antichain/2`. This module
  reimplements no check logic — it only gives the existing functions a
  declared shape the generic `Engine` can run uniformly. See
  `Commonplace.Bd.Invariants`'s moduledoc for the substance of each bd
  check (in particular the CX-o3ar corruption class and the
  provenance-not-position pin design).
  """

  alias Commonplace.Bd.Invariants, as: BdInvariants
  alias Commonplace.Invariants.Invariant
  alias Commonplace.Store.{ChitAncestry, CommitInvariants, CommitStoreClient}

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
        itself. The history walk pages through its bounded store reads
        until it reaches genesis; if the relevant history is not
        present (for example, a shallow or partial chain whose oldest
        fetched commit still names a missing parent), the check returns
        `{:error, {:terminal_pin_history_incomplete, _}}` instead of
        turning an unread pin into a false green. That need for readable
        ancestry is precisely
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
      ),
      Invariant.new!(
        name: :commit_accepted_heads_antichain,
        scope: %{domain: :commit, granularity: :per_subject},
        enumerate: fn context ->
          # SCOPE-TO-ADVANCED (plan #13391 / #13407): only the docs whose
          # head advanced this batch, threaded in by the Dispatcher as
          # :advanced_subjects. ⚠️ Sound ONLY WHILE this invariant is
          # ALARM-ONLY (see the Dispatcher's context-threading comment): an
          # alarm touches no integrated state, so per-replica-divergent
          # advanced-sets cannot cause divergence. A future state-affecting
          # response (deterministic repair) MUST revisit this scoping. The
          # full-population :commit backstop (World B gap, plan #13407) is
          # owed separately, at audit cadence — this per-advance entry does
          # not cover non-advancing docs or the backfill boundary.
          Map.get(context, :advanced_subjects, [])
        end,
        check: fn %{store: store}, subject ->
          CommitInvariants.antichain(store, subject)
        end,
        responses: [:alarm],
        deferral: :immediate,
        owner: "commonplace",
        doc: """
        Hazard 3 (BUILD-1 increment 2b): a document's accepted-head set
        (the durable frontier — `Commonplace.Store.AcceptedHeads` /
        `accepted_heads_indexed/2`) must be an ANTICHAIN: no accepted head
        a DAG-ancestor of another accepted head of the same document. The
        head-update seam enforces this by construction (advancing prunes
        the heads it dominates); this invariant is the BACKSTOP that alarms
        if a future edit to the seam regresses the domination delta —
        registered so the rule outlives the function it currently lives in.
        ALARM-ONLY and never blocks: a local merge advancing `:latest` must
        never be refused (refusing convergence, R4). Ancestry follows
        `parent_id` AND `merge_parents` (a merge-folded head is dominated
        only through the merge edge). Decidable from resting state:
        :immediate.
        """
      ),
      Invariant.new!(
        name: :chit_ancestry,
        scope: %{domain: :chit, granularity: :per_subject},
        enumerate: fn %{store: store} ->
          CommitStoreClient.all_chit_cids(store)
        end,
        check: fn %{store: store}, cid ->
          case CommitStoreClient.get_chit(store, cid) do
            {:ok, chit} ->
              case ChitAncestry.check(store, chit) do
                :ok -> :ok
                {:error, {:ancestry_violation, failures}} -> {:violation, %{failures: failures}}
              end

            :none ->
              {:error, {:chit_missing, cid}}
          end
        end,
        responses: [:alarm],
        deferral: :immediate,
        owner: "commonplace",
        doc: """
        A chit's `parents` are narrative claims: for every doc pinned by
        both child and parent, the child's pinned commit must
        descend-or-equal the parent's (`Commonplace.Store.ChitAncestry`).
        HONESTY, plainly: today's entire chit population is
        locally-minted chits that ALREADY passed this exact check at the
        mint gate (`ChitMint.commit/5` refuses a false claim before
        storing), so this entry is RE-verification, not first
        enforcement. It becomes load-bearing only when chits arrive by
        sync/replication — and no such path exists yet. ⛔ And the
        `:alarm` response channel currently has ZERO readers (the
        invariant framework-gap): this entry is a NAMED CUSTOMER of that
        gap, NOT a working backstop — a violation found here today is
        recorded by the engine and heard by nobody. Decidable from
        resting state: :immediate.
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
