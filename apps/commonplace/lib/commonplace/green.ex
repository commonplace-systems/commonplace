defmodule Commonplace.Green do
  @moduledoc """
  CX-vfau (part b): the acquire-verb half of the Compute stdlib — a
  peer of `Commonplace.Black`, callable from the same execute-gated
  code docs.

  ## Black senses, green acts (black-channel brief §6)

  `Commonplace.Black`'s moduledoc states the split: black is
  read-only/signal-only (`select/3`, `json/2`, `xml/2`, `emit_red/2`);
  none of it acquires anything or gates concurrent writers. That is
  green's job. This module is the thin author-facing facade over
  `Commonplace.Green.BursarClient` — the same custody machinery
  Move/TickBot already dogfood, given the same "reachable from a
  compute doc" ergonomics Black has.

  ## What this module is (and is not)

  `acquire/3`, `release/3`, `renew/3`, `query/2` are thin delegations
  to `BursarClient` — same argument shapes, same return values
  (`{:ok, token_info}` / `{:denied, holder_info}` /
  `{:error, reason}` / `:available` / `{:held, info}`). `opts[:server]`
  overrides the target Bursar (default `Commonplace.Green.Bursar`),
  mirroring `Commonplace.Black`'s `opts[:store]` override.

  Deliberately NOT exposed here: `force_release` and `transfer`.
  Break-glass release and custody transfer are **operator** verbs —
  they act on a token some OTHER holder is holding, which is a step
  beyond "act as yourself" that author code has no business doing
  unsupervised. If a compute needs one of those, that is a signal to
  reach `BursarClient` directly from operator-trusted code, not to
  widen this facade.

  ## `holder` is required and explicit — no ambient default

  Every verb below takes `holder` as a required, explicit argument.
  There is no "current identity" implicitly threaded in, because
  green custody is not identity-scoped the way a signed capability is
  (see "the green/white boundary" below) — the caller must say, in
  plain text, who is asking. The convention this module prescribes:

    * A **compute doc** (a `PatternCompute` / `ViewCompute` `compute_fn`
      or `code_uuid` body) uses its OWN code-doc uuid as `holder`. The
      code-doc uuid is stable across runs of the same compute, so
      re-acquiring on every recompute is the idempotent-same-holder
      path in `Bursar.acquire/4`, not a contended re-acquire.
    * A **session** (an interactive REPL, a MUD player connection, an
      agent run) uses its session identity as `holder`.

  Picking the wrong scope (e.g. a shared "system" holder string used
  by every compute) silently defeats exclusivity — two unrelated
  computes racing the same path would both see the idempotent-same-
  holder path and believe they hold the lock alone. This module
  cannot enforce the right choice; it is a convention this moduledoc
  states so author code has one to follow.

  ## The green/white boundary — a token is not a capability

  Green custody is **operational**, not **security-bearing**. Hands
  and signing (the white/Trust machinery — `SigningContext`,
  `Trust.authorized?`) are NOT involved anywhere in this module: a
  green token never feeds `Trust.authorized?`, and holding one implies
  no authorization to do anything you couldn't already do. It exists
  purely to keep two concurrent writers from stepping on the same
  path — closer to a `flock()` than to a signed grant. Treating a
  token as proof of permission would be a category error; state this
  plainly for anyone reaching for `holder` as an auth check.

  ## `with_token/4` — the one convenience worth adding

  Author code should rarely hand-sequence `acquire` → work → `release`
  — that pattern gets the `after`-clause release-on-exception wrong
  often enough that it is worth having exactly once, here, instead of
  in every call site. `with_token/4` acquires, runs `fun`, and releases
  in an `after` (so a raising `fun` still releases); on contention it
  returns `{:denied, holder_info}` WITHOUT running `fun` at all.

  ## No new trust surface (mirrors `Commonplace.Black`'s posture)

  The only path by which doc-authored code reaches this module is
  from inside an execute-gated compute (Gate B) — exactly like
  `Commonplace.Black`. This module adds no authorization check of its
  own; the gate that already decides whether a code doc may execute
  at all is the entire trust story. Combined with the green/white
  boundary above: reaching this module already means the gate trusted
  the code to run, and nothing this module hands back (a token) raises
  that trust level.

  ## Worked example — the reactive-exclusivity reference (brief §6)

  The brief's "when pattern matches, claim exclusivity before acting,
  and announce contention" composes from shipped parts with no new
  machinery: a `Commonplace.Black.PatternCompute` whose `compute_fn`
  wraps its write in `with_token/4`, emitting a black `emit_red/2`
  signal on denial instead of writing.

      claim_path = "claims/\#{target_uuid}"

      compute_fn = fn matches, _ctx ->
        holder = code_uuid  # stable across runs — see "holder" above

        case Commonplace.Green.with_token(claim_path, holder, [ttl: 30_000], fn ->
               render(matches)
             end) do
          {:ok, rendered} ->
            rendered

          {:denied, info} ->
            Commonplace.Black.emit_red(target_uuid, %{
              kind: :claim_denied,
              claim_path: claim_path,
              held_by: info.holder
            })

            :no_write
        end
      end

  `PatternCompute` always writes whatever its `compute_fn` returns —
  there is no built-in "skip this write" outcome — so a `compute_fn`
  wired this way must return valid target content on both branches
  (e.g. the freshly rendered content on success, the PREVIOUS content
  unchanged on denial). See `Commonplace.GreenTest`'s reference
  composition describe block for the version actually exercised
  against a live `PatternCompute`.
  """

  alias Commonplace.Green.BursarClient

  @doc """
  Acquire an exclusive token for `path` as `holder`. Delegates to
  `Commonplace.Green.BursarClient.acquire/4`.

  `opts[:server]` overrides the target Bursar (default
  `Commonplace.Green.Bursar`). Other opts (e.g. `:ttl`,
  `:authenticated_as`) pass through unchanged.

  Returns `{:ok, token_info}`, `{:denied, holder_info}`,
  `{:error, :bursar_unavailable}`, or `{:error, :holder_mismatch}`.
  """
  @spec acquire(String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:denied, map()} | {:error, term()}
  def acquire(path, holder, opts \\ []) when is_binary(path) and is_binary(holder) do
    {server, opts} = pop_server(opts)
    BursarClient.acquire(server, path, holder, opts)
  end

  @doc """
  Release a token held by `holder`. Delegates to
  `Commonplace.Green.BursarClient.release/4`.

  `opts[:server]` overrides the target Bursar.

  Returns `:ok`, `{:error, {:not_holder, current_holder}}`,
  `{:error, :not_held}`, or `{:error, :bursar_unavailable}`.
  """
  @spec release(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def release(path, holder, opts \\ []) when is_binary(path) and is_binary(holder) do
    {server, opts} = pop_server(opts)
    BursarClient.release(server, path, holder, opts)
  end

  @doc """
  Renew (keep-alive) a token held by `holder`. Delegates to
  `Commonplace.Green.BursarClient.renew/4`.

  `opts[:server]` overrides the target Bursar; `opts[:ttl]` updates the
  TTL (omit to keep the existing TTL).

  Returns `{:ok, token_info}`, `{:error, {:not_holder, current_holder}}`,
  `{:error, :not_held}`, or `{:error, :bursar_unavailable}`.
  """
  @spec renew(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def renew(path, holder, opts \\ []) when is_binary(path) and is_binary(holder) do
    {server, opts} = pop_server(opts)
    BursarClient.renew(server, path, holder, opts)
  end

  @doc """
  Query token status for `path`. Delegates to
  `Commonplace.Green.BursarClient.query/2`.

  `opts[:server]` overrides the target Bursar.

  Returns `{:held, holder_info}`, `:available`, or
  `{:error, :bursar_unavailable}`.
  """
  @spec query(String.t(), keyword()) :: {:held, map()} | :available | {:error, term()}
  def query(path, opts \\ []) when is_binary(path) do
    {server, _opts} = pop_server(opts)
    BursarClient.query(server, path)
  end

  @doc """
  Acquire `path` as `holder`, run `fun.()`, then release — guaranteed
  even if `fun` raises (release runs in `after`). On contention,
  returns `{:denied, holder_info}` WITHOUT calling `fun` at all.

  `opts` are passed to `acquire/3` (so `opts[:ttl]`, `opts[:server]`,
  `opts[:authenticated_as]` all apply); the SAME `opts[:server]` is
  reused for the matching `release/3` call so acquire and release
  target the same Bursar.

  Returns `{:ok, fun.()'s return value}`, `{:denied, holder_info}`, or
  `{:error, reason}` if `acquire/3` itself fails for a reason other
  than contention (e.g. `:bursar_unavailable`, `:holder_mismatch`) —
  `fun` does not run in that case either.
  """
  @spec with_token(String.t(), String.t(), keyword(), (-> term())) ::
          {:ok, term()} | {:denied, map()} | {:error, term()}
  def with_token(path, holder, opts \\ [], fun)
      when is_binary(path) and is_binary(holder) and is_function(fun, 0) do
    case acquire(path, holder, opts) do
      {:ok, _token_info} ->
        try do
          {:ok, fun.()}
        after
          release(path, holder, opts)
        end

      {:denied, _holder_info} = denied ->
        denied

      {:error, _reason} = err ->
        err
    end
  end

  defp pop_server(opts) do
    case Keyword.pop(opts, :server) do
      {nil, rest} -> {Commonplace.Green.Bursar, rest}
      {server, rest} -> {server, rest}
    end
  end
end
