defmodule Commonplace.Trust.ReadMeta do
  @moduledoc """
  CX-ivqz (read-scoping P2) — the canonical carried-fields resolver for
  DIRECT-by-uuid read surfaces (MCP `cat`, GitBridge). Reads a target
  doc's node-signed protected read-visibility fields (`visibility` +
  `owner`) straight from its committed state and hands them to
  `Commonplace.Trust.Read.authorized?/3` as the CARRIED inputs.

  This implements Read.authorized?'s **caller contract #2** — the
  `visibility`/`owner` passed to the verifier MUST be the TARGET's ACTUAL
  node-signed fields, read from the doc's own committed state, never a
  client-influenced value. P1 established that contract for `SessionView`
  view-docs (`SessionView.read_meta/2`); this generalizes it to the two
  shapes a by-uuid reader can hit:

    * **XML view-doc** — the P1 SessionView shape: a `<view>` root element
      whose `visibility`/`owner` ATTRIBUTES carry the fields. Reuses
      SessionView's accessor approach (the `"view"` root re-registration
      quirk + `parse_visibility` semantics).
    * **text JSON room doc** (`__room.json`) — a text doc whose content
      Jason-decodes to a map with `"visibility"`/`"owner"` keys. Same
      semantics as `Commonplace.MUD.Schemas.decode_visibility/1`.

  ## Reconstruction

  FULL-CHAIN via `Commonplace.Tree.DocBuilder.reconstruct_doc/2` — NOT
  `reconstruct_snapshot/2`. The protected fields live in the doc's genesis
  (they're node-signed at mint and never change), and for a view-doc the
  root XML attributes are only recoverable off the full replay (mirrors
  `SessionView.read_meta/2`).

  ## Default posture = public (the no-regression invariant)

  Anything that isn't a recognizably-gated carried shape — a missing doc,
  a reconstruction error, non-map JSON, binary garbage, an unknown doc
  shape — resolves to `%{visibility: :public, owner: nil}`. This NEVER
  crashes. Defaulting to public on an unparseable/absent field is SAFE
  because `visibility` is only ever TRUSTED as `:capability_gated` when
  the WRITE gate protected it at mint (W3); a reader cannot forge a doc
  into `:capability_gated`, and forging it toward `:public` only ever
  loses privacy for a doc that was already public. The regression risk
  runs the other way — a false `:capability_gated` would drop public
  content — so public-on-doubt is the correct, conservative default.
  """

  alias Commonplace.Document.ContentType
  alias Commonplace.Tree.DocBuilder
  alias Yelixer.Types.XMLElement

  # The SessionView XML root type/tag (P1). Kept as a local constant so
  # this module does not depend on SessionView internals.
  @view_type "view"

  @default %{visibility: :public, owner: nil}

  @doc """
  Resolve `uuid`'s carried read-visibility fields from its committed
  state. Returns `%{visibility: :public | :capability_gated, owner:
  String.t() | nil}`. Never raises; defaults to public on any
  missing/unparseable/unknown-shape doc (see the moduledoc).
  """
  @spec resolve(String.t(), module() | atom()) :: %{
          visibility: :public | :capability_gated,
          owner: String.t() | nil
        }
  def resolve(uuid, store) when is_binary(uuid) do
    case DocBuilder.reconstruct_doc(store, uuid) do
      {:ok, doc} -> from_doc(doc)
      # :none (no such doc) or {:error, _} (reconstruction failure) →
      # default public. Existence is not leaked here — the read gate hides
      # it, and a public default cannot over-expose a doc that isn't there.
      _absent_or_error -> @default
    end
  rescue
    # Binary garbage / an unexpected substrate shape must never turn a
    # read gate into a crash. Default posture = public.
    _ -> @default
  end

  # Shape detection: XML view-doc first (P1 pattern), then text JSON room
  # doc, else the safe default.
  defp from_doc(doc) do
    cond do
      view_doc?(doc) -> view_meta(doc)
      true -> text_json_meta(doc)
    end
  end

  # A view-doc carries a top-level XML element registered under the
  # `"view"` type. A text room doc's types are `"root"`/`"content"` — no
  # `"view"` key — so this discriminates cleanly.
  defp view_doc?(%{types: types}) when is_map(types), do: Map.has_key?(types, @view_type)
  defp view_doc?(_), do: false

  # Mirror SessionView.read_meta/2: force-re-register the root tag (the
  # replay quirk documented there — a named root's tag is never recovered
  # off the wire) then read the protected attributes.
  defp view_meta(doc) do
    doc = %{doc | types: Map.put(doc.types, @view_type, {:xml_element, "view"})}

    %{
      visibility: parse_visibility(XMLElement.get_attribute(doc, @view_type, "visibility")),
      owner: as_owner(XMLElement.get_attribute(doc, @view_type, "owner"))
    }
  end

  # A `__room.json` room doc is a text doc whose content Jason-decodes to a
  # map. Anything else (nil content, non-binary, non-JSON, non-map JSON) →
  # default public.
  defp text_json_meta(doc) do
    with content when is_binary(content) <- ContentType.get_content(doc),
         {:ok, m} when is_map(m) <- Jason.decode(content) do
      %{
        visibility: parse_visibility(Map.get(m, "visibility")),
        owner: as_owner(Map.get(m, "owner"))
      }
    else
      _ -> @default
    end
  end

  # Same semantics as SessionView.parse_visibility / Schemas.decode_visibility:
  # ONLY the literal "capability_gated" gates; absent/anything-else → public.
  defp parse_visibility("capability_gated"), do: :capability_gated
  defp parse_visibility(_absent_or_unknown), do: :public

  # owner must be an identity_uuid string or nil; coerce any non-binary
  # (a malformed JSON value) to nil so it can never spuriously match a
  # principal in the verifier's `owner ==` self-read check.
  defp as_owner(owner) when is_binary(owner), do: owner
  defp as_owner(_), do: nil
end
