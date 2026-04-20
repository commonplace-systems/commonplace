defmodule Commonplace.Crypto.SigningContext do
  @moduledoc """
  Per-call signing context for `CommitStore.create_commit/5` and
  `CommitStore.create_chained_commit/4` (CX-hoj).

  CommitStore historically signed commits by reading
  `signing_key:default` / `signing_pub:default` / `signing_identity`
  from the GLOBAL `SecretStore`. That was fine when only one writer
  was active (the human user via CLI / LiveView), but breaks the
  audit trail as soon as a second writer (e.g. an MCP agent session)
  loads its own ephemeral keypair into those same slots: any
  concurrent CLI commit would be signed with the AGENT's key, claiming
  in the audit log that the human's edit came from the agent — worse
  than unsigned.

  This struct lets callers thread an explicit signing identity
  through the commit-create path. CommitStore prefers the per-call
  context when one is supplied; otherwise it falls back to the global
  SecretStore lookup (preserving the legacy behavior for callers that
  haven't been updated).

  Pass `signing_context: :unsigned` in opts to deliberately skip
  signing even when a global signing key is configured — useful for
  agent commits during MCP MVP that explicitly should NOT inherit the
  human's identity (CX-rmk scoping decision).

  ## Fields

    * `:identity_uuid` — string actor identifier baked into the
      signer_id ("identity@fingerprint"). Use the actor's presence /
      identity UUID. "anonymous" is reserved for legacy unidentified
      writers.
    * `:private_key` — raw Ed25519 private-key bytes (NOT base64-
      encoded; decode before constructing).
    * `:public_key` — raw Ed25519 public-key bytes used to derive the
      signer_id fingerprint.
  """

  @enforce_keys [:identity_uuid, :private_key, :public_key]
  defstruct [:identity_uuid, :private_key, :public_key]

  @type t :: %__MODULE__{
          identity_uuid: String.t(),
          private_key: binary(),
          public_key: binary()
        }
end
