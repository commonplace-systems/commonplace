defmodule Commonplace.Bots.Identity do
  @moduledoc """
  Per-bot signing identity for the chat-bot runtime (Camillo C1).

  Resolves a REAL per-agent Ed25519 `Commonplace.Crypto.SigningContext`
  for a chat bot, so its `post_message` / `remember` writes are genuinely
  signed by the bot's OWN key — not a placeholder `"bot:<name>"` string.
  It is the chat-surface sibling of `Commonplace.MUD.Bot.resolve_signing_opts`
  (the MUD-citizen surface); both lean on the SAME per-agent-key machinery,
  so there is no new crypto here — only reuse of the existing seam.

  ## The provisioning ceremony (repeatable, idempotent)

  `resolve_signing_context/4` performs a two-step ceremony:

    1. **Register the principal.**
       `Commonplace.Presence.Identity.register_agent/4` mints (idempotently)
       a `:bot` cold identity in `__identities__` under the bot's bare name,
       mints an Ed25519 keypair via `Commonplace.Crypto.AgentKeys.ensure/2`
       (custody in the node-local `SecretStore`, never synced), and binds
       the pubkey into the identity doc. It returns
       `{:ok, identity_uuid, public_key}`.

    2. **Load the bot's own signing context.**
       `Commonplace.Crypto.AgentKeys.signing_context/2` reads that custody
       back as a `%SigningContext{}` ready for the `:signing_context` commit
       opt.

  Both steps are **idempotent per bare name**: `register_agent` resolves an
  existing identity to the SAME stable `identity_uuid` (touching last_seen,
  never re-minting), and `AgentKeys.ensure` returns the SAME key on a second
  call. So calling `resolve_signing_context/4` repeatedly — every worker
  turn, across restarts — is safe and always yields the same principal. This
  is the "provisioning ceremony" the trust gate wants documented: a bot is
  provisioned once and re-resolves deterministically forever after.

  ## Who signs the registration (D9)

  The registration commits themselves must be signed by SOME principal.
  By default (the D9 headless branch) the NODE signs them via
  `Commonplace.Crypto.NodeIdentity.signing_context/0` — the node is
  auto-trusted, the sanctioned fallback when there is no human in the loop.
  A creator context (e.g. an operator or a test keypair) can instead be
  pinned via `opts[:registrar_signing_context]`, mirroring
  `Commonplace.MUD.Bot`'s `registrar_signing_opts/1`. When neither is
  available the registration commits go unsigned — the legacy behavior, and
  harmless on a permissive node.

  > #### Security contract: `registrar_signing_context` is provisioning-only {: .warning}
  >
  > `registrar_signing_context` — the principal that ATTESTS an identity's
  > registration — is a TEST / PROVISIONING-time injection point ONLY. It is
  > NEVER forwarded from runtime worker-spawn opts (dispatcher spawn args,
  > `bot.json`, verb params). `Commonplace.Bots.Worker` deliberately does not
  > pass its raw `opts` through: on the worker runtime path the registrar is
  > ALWAYS the node context. Only DIRECT callers of
  > `resolve_signing_context/4` (tests, provisioning scripts) may override the
  > registrar — so an attacker who can shape a Worker's opts cannot choose who
  > attests an identity's registration.

  ## One principal across surfaces

  Because both this chat surface AND the MUD-citizen surface
  (`Commonplace.MUD.Bot.resolve_signing_opts`) register under the same
  BARE bot name (`:bot` kind, same root), a bot's chat identity is UNIFIED
  with its MUD-citizen / mesh identity: one `identity_uuid`, one keypair,
  one signer_id — a single principal no matter which surface it acts
  through. Nothing here is special-cased to any particular bot; any bot
  entity gets a real principal.

  ## Graceful degradation

  Never raises. Any failure (registration failed, no custody, corrupt key)
  returns `{:error, reason}`. The caller (`Commonplace.Bots.Worker`) treats
  a non-`{:ok, _}` result as "no signing context" and the bot's writes go
  unsigned — an honest failure that will simply be denied under enforce,
  not a crash.
  """

  alias Commonplace.Crypto.{AgentKeys, NodeIdentity, SigningContext}
  alias Commonplace.Presence.Identity
  alias Commonplace.Store.{CommitStoreClient, SecretStore}

  @doc """
  Resolve the bot's own `%SigningContext{}` (see the provisioning ceremony
  in the moduledoc). Returns `{:ok, %SigningContext{}}` or `{:error, term()}`.

  Options:

    * `:secret_store` — SecretStore instance holding the bot's key custody
      (default: the global `Commonplace.Store.SecretStore`).
    * `:registrar_signing_context` — the `%SigningContext{}` that signs the
      registration commits. When absent, falls back to the node's context
      (D9 headless branch).
  """
  @spec resolve_signing_context(String.t(), String.t(), term(), keyword()) ::
          {:ok, SigningContext.t()} | {:error, term()}
  def resolve_signing_context(name, root_uuid, store \\ CommitStoreClient, opts \\ [])
      when is_binary(name) and is_binary(root_uuid) do
    secret_store = Keyword.get(opts, :secret_store, SecretStore)
    registrar = registrar_signing_context(opts)

    registrar_opts =
      [secret_store: secret_store] ++
        if registrar, do: [signing_context: registrar], else: []

    case Identity.register_agent(name, root_uuid, store, registrar_opts) do
      {:ok, identity_uuid, _pub} ->
        AgentKeys.signing_context(identity_uuid, secret_store)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The principal that signs the REGISTRATION commits (D9). A test /
  # operator context via `opts[:registrar_signing_context]` wins; else the
  # node's own signing identity (auto-trusted headless fallback); else nil
  # (unsigned registration — legacy, harmless on a permissive node).
  defp registrar_signing_context(opts) do
    case Keyword.get(opts, :registrar_signing_context) do
      nil ->
        case NodeIdentity.signing_context() do
          {:ok, ctx} -> ctx
          _ -> nil
        end

      ctx ->
        ctx
    end
  end
end
