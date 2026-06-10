defmodule Commonplace.Trust do
  @moduledoc """
  The trust boundary: `authorized?(commit, verb, scope)`.

  Both enforcement gates — import (`CommitStore.import_commit`, Gate A)
  and execute (`SourceDoc.compile`, Gate B) — call **only** this function,
  never an allowlist or capability store directly. The phase-1 body below
  is a flat allowlist; phase-3 swaps in a capability-chain walk without
  the gates changing. See docs/trust-and-attenuation.md (commonplace-plan)
  §2/§4/§7.

  ## Phase-1 semantics (flat allowlist)

  Config is two values, both **workspace-local** — never read from a
  synced document, because a federated peer can write any synced doc
  (including the `__identities__` key registry), so synced state cannot
  anchor trust:

    * `accept_unsigned` — the permissive/strict knob. Defaults to `true`
      (back-compat: existing workspaces are full of unsigned commits);
      flips to `false` once federation is live.
    * `trusted_identities` — pinned `identity_uuid => public_key` entries
      (base64 keys, single or list per identity). Pinned locally for the
      same reason: the identity docs' own `public_keys` field is
      peer-writable.

  Decision table (verb/scope are accepted now so phase-3 doesn't reshape
  the call sites, but the allowlist body ignores them):

  | commit                                   | permissive | strict |
  |------------------------------------------|------------|--------|
  | unsigned                                 | ok         | `:unsigned` |
  | trusted identity, valid signature        | ok         | ok |
  | trusted identity, INVALID signature      | `:invalid_signature` | same |
  | unknown identity                         | ok         | `{:untrusted_signer, uuid}` |
  | malformed signer_id                      | ok         | `:invalid_signer_id` |

  A bad signature from a *trusted* identity rejects in **both** modes: no
  legitimate flow signs with a key other than the pinned one (and the
  signature lives outside the content address, so `verify_id` cannot
  catch it) — it is forgery or corruption either way.

  ## Config resolution

  `config/0`: application env `:commonplace, :trust` (used by tests and
  embedders) → `<data_dir>/trust.json` → `default_config/0`. The JSON
  file lives beside the workspace's other local state (`root`,
  `node_id`) under `.commonplace/`, which is exactly the
  not-synced-not-peer-writable surface the anchor decision requires.
  """

  alias Commonplace.Crypto.Signing
  alias Commonplace.Store.Commit

  @type verb :: :write | :execute
  @type scope :: {:doc, String.t()}
  @type config :: %{
          accept_unsigned: boolean(),
          trusted_identities: %{String.t() => String.t() | [String.t()]}
        }

  @doc """
  Is this commit's signer authorized for `verb` at `scope`?

  Returns `:ok` or `{:error, reason}`. The 3-arity head resolves config
  via `config/0`; the 4-arity head takes it explicitly (pure, for tests
  and callers that batch-load config).
  """
  @spec authorized?(Commit.t(), verb(), scope()) :: :ok | {:error, term()}
  def authorized?(%Commit{} = commit, verb, scope) do
    authorized?(commit, verb, scope, config())
  end

  @spec authorized?(Commit.t(), verb(), scope(), config()) :: :ok | {:error, term()}
  def authorized?(%Commit{signature: nil}, _verb, _scope, cfg) do
    if cfg.accept_unsigned, do: :ok, else: {:error, :unsigned}
  end

  def authorized?(%Commit{} = commit, _verb, _scope, cfg) do
    case Signing.parse_signer_id(commit.signer_id || "") do
      {:ok, identity_uuid, _fingerprint} ->
        case Map.fetch(cfg.trusted_identities, identity_uuid) do
          {:ok, pinned} ->
            verify_against_pinned(commit, pinned)

          :error ->
            if cfg.accept_unsigned, do: :ok, else: {:error, {:untrusted_signer, identity_uuid}}
        end

      {:error, :invalid_signer_id} ->
        if cfg.accept_unsigned, do: :ok, else: {:error, :invalid_signer_id}
    end
  end

  # A trusted identity's signature must verify against one of its pinned
  # keys — in BOTH modes (see moduledoc decision table).
  defp verify_against_pinned(commit, pinned) do
    keys = List.wrap(pinned)

    verified =
      Enum.any?(keys, fn encoded ->
        case Signing.decode_key(encoded) do
          {:ok, key} -> Signing.verify_commit(commit, key) == :ok
          {:error, _} -> false
        end
      end)

    if verified, do: :ok, else: {:error, :invalid_signature}
  end

  @doc """
  Is every commit contributing to this doc's state authorized for
  `:execute`? The Gate B check (CX-tdkq.2 / R2).

  Walks the doc's commit chain newest-first and checks each commit with
  `authorized?(commit, :execute, {:doc, uuid})`, stopping at the trusted
  baseline:

    * a **snapshot** commit — checked, then the walk stops: a snapshot
      re-encodes the full visible state, so once it is trusted, earlier
      history is irrelevant;
    * the **genesis** commit — exempt and terminal: synthetic, unsigned
      by construction, and its update is empty (contributes nothing).

  Checking only the head would be unsound — write-time laundering: the
  edit flow re-encodes FULL doc state, so a trusted editor's head commit
  physically contains every earlier contributor's surviving bytes (see
  design doc §2 Gate B). Every contributor since the baseline must hold
  `:execute`.

  An empty chain returns `:ok` — there is nothing to execute, and the
  caller's read fails with `:not_found` on its own.

  The walk follows `parent_id` only (like `DocBuilder`'s replay). A
  merge commit's `merge_parents` side arrives as translated bytes inside
  the merge commit itself, which is checked — and merge commits are
  minted unsigned today, so strict mode conservatively denies converged
  code docs (code docs are not expected to be merge-converged; see the
  full-state invariant in the design doc).
  """
  @spec authorized_to_execute?(GenServer.server(), String.t(), config() | nil) ::
          :ok | {:error, term()}
  def authorized_to_execute?(store, doc_uuid, cfg \\ nil) do
    cfg = cfg || config()

    if cfg.accept_unsigned and cfg.trusted_identities == %{} do
      # Fully-permissive config: no commit can fail (unsigned passes,
      # unknown signers pass, and with no pinned keys there is no
      # forgery case) — skip the chain walk so the default config keeps
      # compile O(cache-hit) on hot paths.
      :ok
    else
      walk_contributors(store, doc_uuid, cfg)
    end
  end

  defp walk_contributors(store, doc_uuid, cfg) do
    Commonplace.Store.CommitStoreClient.commit_log(store, doc_uuid, limit: 10_000)
    |> Enum.reduce_while(:ok, fn commit, :ok ->
      cond do
        match?(%{metadata: %{kind: :genesis}}, commit) ->
          {:halt, :ok}

        true ->
          case authorized?(commit, :execute, {:doc, doc_uuid}, cfg) do
            :ok ->
              if match?(%{metadata: %{kind: :snapshot}}, commit) do
                {:halt, :ok}
              else
                {:cont, :ok}
              end

            {:error, reason} ->
              {:halt, {:error, {:untrusted_contributor, commit.id, reason}}}
          end
      end
    end)
  end

  @doc """
  Resolve the workspace trust config: application env `:commonplace,
  :trust` → `<data_dir>/trust.json` → `default_config/0`.
  """
  @spec config() :: config()
  def config do
    base =
      case Application.get_env(:commonplace, :trust) do
        %{} = cfg -> normalize(cfg)
        nil -> config_from_file() || default_config()
      end

    with_local_node_trust(base)
  end

  # Phase 2.5 (CX-tdkq.24): the local node always trusts its OWN
  # system-minted commits — its signing key is local-only and a peer
  # cannot forge it, so this is anchored in local config (the node
  # keypair file), exactly the §4 anchor model. Folding the node
  # identity→pubkey into the trusted set means a single-node strict
  # workspace accepts node-signed snapshots/merges with zero pinning.
  # Best-effort: if the node key can't be sourced, the set is unchanged
  # (the node's commits will then fail strict checks — visible, not
  # silent).
  defp with_local_node_trust(cfg) do
    with {:ok, identity} <- Commonplace.Crypto.NodeIdentity.identity(),
         {:ok, pub} <- Commonplace.Crypto.NodeIdentity.public_key() do
      trusted = Map.put_new(cfg.trusted_identities, identity, Signing.encode_key(pub))
      %{cfg | trusted_identities: trusted}
    else
      _ -> cfg
    end
  end

  @doc "The default (permissive, empty allowlist) trust config."
  @spec default_config() :: config()
  def default_config do
    %{accept_unsigned: true, trusted_identities: %{}}
  end

  defp config_from_file do
    data_dir = Application.get_env(:commonplace, :data_dir, "data")

    with {:ok, raw} <- File.read(Path.join(data_dir, "trust.json")),
         {:ok, json} <- Jason.decode(raw) do
      normalize(json)
    else
      _ -> nil
    end
  end

  # Accept atom- or string-keyed maps (app env vs JSON) and fill defaults.
  defp normalize(cfg) do
    %{
      accept_unsigned: fetch(cfg, :accept_unsigned, true),
      trusted_identities: fetch(cfg, :trusted_identities, %{})
    }
  end

  defp fetch(cfg, key, default) do
    Map.get(cfg, key, Map.get(cfg, Atom.to_string(key), default))
  end
end
