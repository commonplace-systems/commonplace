defmodule Commonplace.Pulls.Template do
  @moduledoc """
  Renders the `<view>` document content for an intra-repo pull request.

  Shape is fixed by
  `docs/plans/2026-07-16-intra-repo-pull-request-design.md` §1 (the
  commonplace-plan design doc). This module is the single place that
  knows that shape, so later steps that re-render or region-replace
  parts of the PR doc (`pr_refresh_preview` §7.3, `pr_accept` /
  `pr_decline` / `pr_comment` §7.4) can reuse `preview_placeholder/0`
  and the section markers instead of re-deriving the XML by hand.

  Per §6.3 of the design doc: nothing here is trusted for
  enforcement. The `<pr>` element's `source`/`target`/`base`/`status`/
  `opened_by` attributes are informational render surface only — every
  verb that acts on a PR doc re-derives its authority from server-side
  state (signing context, `find_common_ancestor`, `Trust.authorized?`),
  never from these fields.
  """

  @preview_placeholder "no preview yet — run refresh"

  @doc "The placeholder preview-section body used until `pr_refresh_preview` runs (§7.3)."
  @spec preview_placeholder() :: String.t()
  def preview_placeholder, do: @preview_placeholder

  @doc """
  Render the initial `<view>` content for a newly opened PR (§7.2).

  `fields`:

    * `:source` — source doc uuid (the fork, B)
    * `:target` — target doc uuid (A)
    * `:base` — the common-ancestor commit id, hex-encoded, or `nil`
      when not yet known
    * `:status` — `:open` | `:merged` | `:declined`
    * `:opened_by` — server-resolved principal string (never a
      client-supplied param — see §6.3 / §6.4)
    * `:title` — optional human-readable heading; defaults to
      `"PR: <short source> -> <short target>"`
  """
  @spec render(map()) :: String.t()
  def render(%{source: source, target: target, status: status, opened_by: opened_by} = fields) do
    base = Map.get(fields, :base)
    title = Map.get(fields, :title) || "PR: #{short(source)} -> #{short(target)}"

    """
    <view>
      <h2>#{esc(title)}</h2>
      <pr source="#{esc(source)}" target="#{esc(target)}"#{base_attr(base)}
          status="#{esc(status)}" opened_by="#{esc(opened_by)}" />
      <section id="description"></section>
      <section id="preview">#{esc(@preview_placeholder)}</section>
      <section id="reviews"></section>
      <action name="pr_refresh_preview" label="Refresh preview"/>
      <action name="pr_accept" label="Accept &amp; merge" guard-write="#{esc(target)}"/>
      <action name="pr_decline" label="Decline"/>
      <action name="pr_comment" label="Comment" args="text:string"/>
    </view>
    """
  end

  defp base_attr(nil), do: ""
  defp base_attr(base), do: "\n      base=\"#{esc(base)}\""

  defp short(uuid) when is_binary(uuid), do: String.slice(uuid, 0, 8)
  defp short(_), do: "?"

  defp esc(nil), do: ""

  defp esc(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end
end
