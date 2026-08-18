defmodule Commonplace.Trust.DenySites do
  @moduledoc """
  The enumeration of every place the system REFUSES a write or an
  action, and the rule that a new one cannot be added without deciding
  whether it is audited (CX-t3xv, brief §1).

  ## Why this is a module and not a comment

  The six-sites lesson: an enumeration written once, by hand, in a
  design doc is correct on the day it is written and wrong six months
  later, because nothing makes the next deny site notice it exists.
  **Deny → audit must be structural inheritance, not per-site memory.**

  So the enumeration lives here as data, and
  `Commonplace.Trust.DenySiteScanTest` reads the SOURCE TREE, extracts
  every denial-class telemetry event actually present in it, and fails
  unless each one is either

    * in `Commonplace.Trust.AuditLog.events/0` (audited), or
    * in `exempt/0` here, **with a stated reason**.

  Adding a deny site and forgetting the audit wiring turns that test
  red. That is the whole mechanism; everything below is its data.

  ## The syntactic-outlier lesson

  The scan cannot just look for the word "rejected". Real deny sites in
  this tree that do not say it:

    * `[:commonplace, :trust, :read, :would_refuse]` — the read gate's
      dry-run refusal. Says "would_refuse".
    * `[:commonplace, :trust, :revocation, :ignored]` — a revocation
      that did NOT take effect. Says "ignored", and it is a denial of a
      *revocation*, i.e. the absence of a refusal that should have
      happened.
    * the federation bearer-token 403 — emitted no telemetry at all
      before this ticket. A deny site with no event is invisible to any
      event-shaped scan, which is exactly why `denial_class?/1` is
      paired with `@known_denial_events`: names are a heuristic, the
      explicit list is the backstop, and a site with no event at all is
      caught by `unwired/0` instead.

  ## The registry

  `audited/0`, `exempt/0` and `unwired/0` partition the census. Every
  entry carries a reason, because "why is this not audited" is the only
  question a reader of an exempt list ever has.
  """

  alias Commonplace.Trust.AuditLog

  @typedoc "A deny site: where it lives, what it emits, why it is classified as it is."
  @type site :: %{
          event: [atom()] | nil,
          where: String.t(),
          gate: String.t(),
          reason: String.t()
        }

  @doc """
  Denial-class telemetry events that MUST be audited. Mirrors
  `AuditLog.events/0` — the test asserts the two agree, so this list
  cannot drift from the handler's subscription.
  """
  @spec audited() :: [site()]
  def audited do
    [
      %{
        event: [:commonplace, :commit, :rejected, :local_trust],
        where: "Commonplace.Store.CommitStore.handle_local_write_denial/3",
        gate: "local write gate (:local_write_gate)",
        reason:
          "the local write gate refuses a commit under :enforce (and logs a would-deny under :dry_run)"
      },
      %{
        event: [:commonplace, :commit, :rejected, :trust],
        where: "Commonplace.Store.CommitStore.handle_validated_import/4",
        gate: "Gate A (import verify)",
        reason: "a peer's commit fails signature/cert verification on import; always enforced"
      },
      %{
        event: [:commonplace, :commit, :rejected, :code_doc_delta_merge],
        where: "Commonplace.Store.CommitStore.handle_validated_import/4",
        gate: "Gate A (code-doc delta merge)",
        reason:
          "CX-obfb defense-in-depth: a delta-merge onto a code doc is a HARD reject, never resolves by waiting"
      },
      %{
        event: [:commonplace, :code, :rejected, :trust],
        where: "Commonplace.Code.SourceDoc.check_execution/2",
        gate: "Gate B (execute authorization)",
        reason: "ambient code execution refused — the highest-privilege refusal in the system"
      },
      %{
        event: [:commonplace, :code, :rejected, :unsafe_verb],
        where: "Commonplace.Code.SourceDoc",
        gate: "safe-verb allowlist (closed-by-default)",
        reason: "a citizen-authored verb left the Facade allowlist"
      },
      %{
        event: [:commonplace, :process, :rejected, :trust],
        where: "Commonplace.Process.Orchestrator",
        gate: "Gate B (:sandbox_exec)",
        reason: "the only gate on :sandbox_exec; a declaration that lost trust is not started"
      },
      %{
        event: [:commonplace, :trust, :revocation, :ignored],
        where: "Commonplace.Trust.VerifyChain",
        gate: "revocation",
        reason:
          "a revocation did NOT take effect — the absence of a refusal that should have happened"
      },
      %{
        event: [:commonplace, :trust, :read, :would_refuse],
        where: "Commonplace.Trust.Read.gate/3",
        gate: "local read gate (:local_read_gate)",
        reason: "a read the gate would refuse; fires in :dry_run, the staging posture"
      },
      %{
        event: [:commonplace, :federation, :rejected, :auth],
        where: "CommonplaceWebWeb.Plugs.FederationAuth",
        gate: "federation bearer token (403)",
        reason:
          "CX-t3xv wired this: the 403 surface previously emitted NOTHING, so a peer " <>
            "hammering the federation endpoint with a bad token left no trace anywhere"
      },
      %{
        event: [:commonplace, :mud, :engine_module, :md5_refused],
        where: "Commonplace.MUD.EngineModule.md5_alarm/4 (via last_good_verified/1)",
        gate: "verify-at-serve on the last-good engine-module cache",
        reason:
          "a cached engine module whose CODE was redefined since it was remembered " <>
            "(BEAM-global name collision, mechanism proven by md5 at 0bf50a30) is " <>
            "refused and the compiled-in floor served — substituted code never runs"
      }
    ]
  end

  @doc """
  Denial-shaped telemetry events that are deliberately NOT trust audit
  records, each with the reason it does not belong in a security audit
  trail.

  An exempt entry is a DECISION, not an oversight — that is the
  difference this list exists to make legible.

  This list is deliberately a SUPERSET of what `denial_class?/1`
  currently flags. Two entries below (`trigger_suppressed`,
  `rate_limit.fail_open`) are deny-adjacent sites the classifier does
  not presently catch; they are pre-answered so that widening the
  classifier later surfaces genuinely new questions rather than
  re-litigating settled ones.
  """
  @spec exempt() :: [site()]
  def exempt do
    [
      %{
        event: [:commonplace, :commit, :rejected, :namespace_mismatch],
        where: "Commonplace.Store.CommitStore",
        gate: "namespace validation",
        reason:
          "structural validity, not authorization: the commit is malformed for its namespace. " <>
            "Refused identically regardless of who wrote it and regardless of enforce mode, " <>
            "so it carries no principal and answers no security question."
      },
      %{
        event: [:commonplace, :commit, :rejected, :id_mismatch],
        where: "Commonplace.Store.CommitStore",
        gate: "content-address integrity",
        reason:
          "the commit's declared id does not match its content hash — a corruption/transport " <>
            "check, not a policy decision. No principal, no mode, nothing for an operator to " <>
            "authorize differently."
      },
      %{
        event: [:commonplace, :commit, :rejected, :unknown_reference],
        where: "Commonplace.Store.CommitStore",
        gate: "namespace out-of-order reference",
        reason:
          "a DEFERRAL, not a denial: the commit is held and re-submitted when its reference " <>
            "lands. Auditing it as a refusal would report denials that never happened."
      },
      %{
        event: [:commonplace, :document, :remote_commit_rejected],
        where: "Commonplace.Document.Server",
        gate: "document server apply",
        reason:
          "downstream of Gate A — the authorization decision was already made and already " <>
            "audited at the store. Auditing here would DOUBLE-COUNT the same denial and break " <>
            "count parity."
      },
      %{
        event: [:yelixer, :pending, :rejected],
        where: "Yelixer.Encoding",
        gate: "CRDT pending-struct bound",
        reason:
          "a CRDT integration bound inside the Y.js port; no principal, no policy, and a " <>
            "different application entirely."
      },
      %{
        event: [:commonplace, :bots, :dispatcher, :trigger_suppressed],
        where: "Commonplace.Bots.Dispatcher",
        gate: "bot trigger rate limit",
        reason: "runtime budgeting for agent citizens, not an authorization refusal."
      },
      %{
        event: [:commonplace, :mud, :rate_limit, :fail_open],
        where: "Commonplace.MUD",
        gate: "MUD rate limit",
        reason: "a rate limiter that FAILED OPEN — it allowed, it did not refuse."
      }
    ]
  end

  @doc """
  Deny sites known to emit NO telemetry at all, i.e. invisible to any
  event-shaped scan.

  This list is the honest denominator on the scan's coverage: an
  event-based census can only see sites that emit events, and reporting
  "all deny sites audited" while silently meaning "all deny sites that
  emit events" is the silent-underreport pattern. Empty is the goal;
  non-empty is a stated gap, not a hidden one.
  """
  @spec unwired() :: [site()]
  def unwired do
    [
      %{
        event: nil,
        where: "Commonplace.Bd.WriteGuard.check_update/5, check_create/4",
        gate: "ticket-DAG write guard (protected/frozen/cycle/shape)",
        reason:
          "returns {:error, binary} to its caller and emits nothing. These are SCHEMA/POLICY " <>
            "refusals on ticket fields rather than trust decisions about a principal, and " <>
            "wiring them is deliberately out of this ticket's scope (brief §7: 'no new denial " <>
            "reasons or policy changes ride this ticket'). Listed so the next reader sees the " <>
            "gap instead of inferring coverage the scan does not have."
      }
    ]
  end

  @doc """
  Syntactic classifier: does this telemetry event name LOOK like a
  refusal?

  Deliberately over-inclusive. A false positive costs one exempt entry
  with a reason; a false negative is an unaudited deny site, which is
  this ticket.
  """
  @spec denial_class?([atom()]) :: boolean()
  def denial_class?(event) when is_list(event) do
    Enum.any?(event, fn seg ->
      s = Atom.to_string(seg)

      s in ~w(rejected denied refused refuse would_refuse unauthorized forbidden ignored suppressed) or
        String.contains?(s, "rejected") or String.contains?(s, "denied") or
        String.contains?(s, "refuse")
    end)
  end

  @doc "Every event this module accounts for, audited or exempt."
  @spec accounted_events() :: MapSet.t()
  def accounted_events do
    (Enum.map(audited(), & &1.event) ++ Enum.map(exempt(), & &1.event))
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  @doc """
  The audited list and the handler's actual subscription must be the
  same set. A registry that says a site is audited while the handler
  does not subscribe to it is a check that cannot fail.
  """
  @spec audited_matches_handler?() :: boolean()
  def audited_matches_handler? do
    MapSet.new(Enum.map(audited(), & &1.event)) == MapSet.new(AuditLog.events())
  end
end
