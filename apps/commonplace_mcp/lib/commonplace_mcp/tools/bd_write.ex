defmodule Commonplace.MCP.Tools.BdWrite do
  @moduledoc """
  Shared signing-context resolution for the Tier-2 WRITE bd tools
  (`bd_create`, `bd_add_needs`, `bd_update`, `bd_close`, `bd_claim`,
  `bd_release`).

  Not an MCP tool itself — a plain helper (like `BdRoute`/`BdRows`), so
  it is NOT registered in `Commonplace.MCP.Tools`.

  ## Why every write needs a signing_context

  The live serve runs under enforce-mode: an unsigned commit is denied.
  Every Tier-2 write routes through the serve via `BdRoute` and must
  carry a `signing_context` so the resulting commit is signed by a real
  key, mirroring how `invoke_view_action` / `loom_send` resolve it.

  ## v1 is NODE-signed (no per-agent MCP identity yet)

  There is no per-agent MCP key-minting today (CX-hk0s). So unless a
  session already carries a real `%Commonplace.Crypto.SigningContext{}`
  in its context (the future path), writes fall back to the NODE
  signing context (`Commonplace.Crypto.NodeIdentity.signing_context/0`).
  Under node-signing every MCP caller shares one principal.

  When CX-hk0s threads per-agent keys into the MCP session context,
  `signing_context/1` picks them up with NO change to any tool —
  attribution simply becomes per-agent.

  ## Claim caveat (bd_claim)

  Because v1 is node-signed, `bd_claim` attributes the claim to the
  NODE principal — ALL callers share one claimer, so claim exclusivity
  between different MCP agents is not yet meaningful. Real multi-agent
  claim exclusivity needs the per-agent keys from CX-hk0s.
  """

  alias Commonplace.MCP.Tools.BdRoute

  @doc """
  Resolve the `%Commonplace.Crypto.SigningContext{}` to sign a write.

    * If the session `context` already carries a real
      `%SigningContext{}` under `:signing_context`, use it (the
      per-agent CX-hk0s path).
    * Otherwise resolve the NODE signing context on the serve via
      `BdRoute` and unwrap the `{:ok, sc}`.
    * On failure, `{:error, :no_signing_context}`.
  """
  @spec signing_context(map()) ::
          Commonplace.Crypto.SigningContext.t() | {:error, :no_signing_context}
  def signing_context(context) when is_map(context) do
    case Map.get(context, :signing_context) do
      %Commonplace.Crypto.SigningContext{} = sc ->
        sc

      _ ->
        case BdRoute.call(Commonplace.Crypto.NodeIdentity, :signing_context, []) do
          {:ok, %Commonplace.Crypto.SigningContext{} = sc} -> sc
          _ -> {:error, :no_signing_context}
        end
    end
  end
end
