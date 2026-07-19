defmodule Commonplace.Bots.Allowlist do
  @moduledoc """
  Camillo slice C3a — the ALLOWLISTED TOOL REGISTRY (the authority boundary).

  Resolves the set of tool names a given bot entity is permitted to use.
  This is the **default-closed** charter gate: an entity gets ONLY the
  tools its charter grants, and the charter is **grantor-signed** — the
  entity cannot write it for itself.

  ## Why a signed charter (the crux)

  A native-agent bot is a *writer of its own directory* (that is how the
  `remember` tool works — a C1-signed append by the entity's OWN key). So
  the allowlist can NOT simply be "whatever `bot.json` says": an LLM agent
  could edit its own `bot.json` to widen its `"tools"` list and thereby
  escalate its own privileges. The rule that closes that hole:

  > **You cannot write your own charter.**

  At load, `resolve/4` verifies that the `bot.json` doc carrying the
  allowlist has its **LATEST COMMIT signed by an authorized GRANTOR** — in
  v1, the NODE identity (`Commonplace.Crypto.NodeIdentity.identity/0`),
  NEVER the entity's own key. On ANY deviation — entity-signed, unsigned,
  or signed by some other non-grantor principal — resolution **fails
  closed to `[]`** (zero tools) and emits a
  `[:commonplace, :bots, :allowlist, :charter_rejected]` telemetry event
  with the reason (`:self_signed` / `:untrusted_grantor` / `:unsigned`).

  ## The resolution steps

    1. `tools = entity.bot_config["tools"]`. Not a list of strings →
       `[]` (default-closed: no charter).
    2. Find the `bot.json` doc uuid via `entity.children["bot.json"]`.
       Absent → `[]` (no charter doc to verify).
    3. Read `bot.json`'s LATEST COMMIT signer via
       `CommitStoreClient.latest_commit/2` → `commit.signer_id`.
    4. Parse the signer's identity_uuid via
       `Commonplace.Crypto.Signing.parse_signer_id/1`.
    5. GRANTOR CHECK (fail-closed): valid ONLY IF the signer's
       identity_uuid is in the grantor set (the node, plus any configured
       operator grantors) **AND** is NOT the entity's own identity_uuid
       (the belt-and-suspenders "never your own key" rule — enforced even
       though node ≠ entity by construction). Valid → return `tools`.
       Otherwise → `[]` + telemetry.

  ## Extensible grantor set

  The grantor set is the node identity plus an app-env list
  `:bots_allowlist_grantors` (default `[]`) of extra operator
  identity_uuids under the `:commonplace_bots` app. This keeps v1 lightly
  extensible for an operator-issued charter, while the entity's OWN
  identity_uuid is ALWAYS rejected regardless of what that list contains.
  In practice v1 = node only.

  ## Not from spawn args (C1 registrar discipline)

  The allowlist is NEVER sourced from spawn args / dispatcher opts /
  `bot.json` knobs handed in at runtime. It comes ONLY from the
  grantor-verified `bot.json` config doc. This mirrors the C1 rule that a
  caller who can shape a Worker's `opts` must not be able to steer WHO
  attests trust — here, a planted `allowlist:` / `tools:` opt cannot grant
  a single tool.

  ## v1 shadow of a full grant artifact

  This is the v1 **shadow** of a full cert-scoped grant artifact (future,
  the `CX-wr12` family): a single signer comparison against a grantor set,
  "you cannot write your own charter", fail-closed. A later revision can
  replace the one-signer comparison with a scoped, revocable grant cert
  without changing this module's default-closed posture.
  """

  alias Commonplace.Crypto.{NodeIdentity, Signing}
  alias Commonplace.Store.CommitStoreClient

  @charter_rejected [:commonplace, :bots, :allowlist, :charter_rejected]

  @doc """
  Resolve the grantor-verified tool allowlist for `entity`.

  Returns a list of permitted tool-name strings, or `[]` when there is no
  valid charter (default-closed). `entity_identity_uuid` is the entity's
  OWN resolved identity_uuid (the principal that must NEVER be accepted as
  its own grantor); a non-binary value (e.g. an unresolved signing
  context) yields `[]`.

  `store` is the commit-store server/handle used to read `bot.json`'s
  latest commit — the same value `Commonplace.Bots.Worker` threads
  everywhere else (default `CommitStoreClient`).
  """
  @spec resolve(Commonplace.Bots.Entity.t(), String.t() | nil, term(), keyword()) ::
          [String.t()]
  def resolve(entity, entity_identity_uuid, store \\ CommitStoreClient, _opts \\ [])

  def resolve(_entity, entity_identity_uuid, _store, _opts)
      when not is_binary(entity_identity_uuid),
      do: []

  def resolve(entity, entity_identity_uuid, store, _opts) do
    with {:tools, tools} when is_list(tools) <- {:tools, tools_field(entity)},
         true <- Enum.all?(tools, &is_binary/1),
         {:doc, botjson_uuid} when is_binary(botjson_uuid) <-
           {:doc, Map.get(children(entity), "bot.json")} do
      case verify_grantor(store, botjson_uuid, entity_identity_uuid) do
        :ok ->
          tools

        {:rejected, reason} ->
          reject(entity, reason)
      end
    else
      # No charter at all (no tools list / not strings / no bot.json doc).
      # Default-closed, but this is the *absence* of a charter, not a
      # security violation, so no charter_rejected event is emitted.
      _ -> []
    end
  end

  defp tools_field(entity) do
    case entity.bot_config do
      %{} = cfg -> Map.get(cfg, "tools")
      _ -> nil
    end
  end

  defp children(entity) do
    case entity.children do
      %{} = c -> c
      _ -> %{}
    end
  end

  # The grantor check: the bot.json's LATEST commit must be signed by a
  # trusted grantor identity_uuid, and NEVER by the entity's own key.
  defp verify_grantor(store, botjson_uuid, entity_identity_uuid) do
    case CommitStoreClient.latest_commit(store, botjson_uuid) do
      {:ok, commit} ->
        classify_signer(commit.signer_id, entity_identity_uuid)

      _ ->
        # No latest commit for the charter doc — treat as unsigned.
        {:rejected, :unsigned}
    end
  end

  defp classify_signer(signer_id, entity_identity_uuid) when is_binary(signer_id) do
    case Signing.parse_signer_id(signer_id) do
      {:ok, signer_uuid, _fp} ->
        cond do
          # "Never your own key" — the belt-and-suspenders rule. Checked
          # FIRST so a self-signed charter is reported distinctly, even in
          # the impossible case that the entity's key were also a grantor.
          signer_uuid == entity_identity_uuid ->
            {:rejected, :self_signed}

          MapSet.member?(grantors(entity_identity_uuid), signer_uuid) ->
            :ok

          true ->
            {:rejected, :untrusted_grantor}
        end

      {:error, _} ->
        {:rejected, :unsigned}
    end
  end

  # signer_id nil (unsigned commit) or any non-binary shape.
  defp classify_signer(_signer_id, _entity_identity_uuid), do: {:rejected, :unsigned}

  # The authorized grantor set: the node identity plus any configured
  # operator grantors — MINUS the entity's own identity_uuid, which is
  # ALWAYS excluded regardless of configuration.
  defp grantors(entity_identity_uuid) do
    node =
      case NodeIdentity.identity() do
        {:ok, id} when is_binary(id) -> [id]
        _ -> []
      end

    extra =
      case Application.get_env(:commonplace_bots, :bots_allowlist_grantors, []) do
        list when is_list(list) -> Enum.filter(list, &is_binary/1)
        _ -> []
      end

    (node ++ extra)
    |> Enum.reject(&(&1 == entity_identity_uuid))
    |> MapSet.new()
  end

  defp reject(entity, reason) do
    :telemetry.execute(
      @charter_rejected,
      %{system_time: System.system_time()},
      %{bot: entity_name(entity), reason: reason}
    )

    []
  end

  defp entity_name(%{name: name}), do: name
  defp entity_name(_), do: nil
end
