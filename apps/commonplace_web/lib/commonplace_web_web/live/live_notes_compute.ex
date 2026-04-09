defmodule CommonplaceWebWeb.LiveNotesCompute do
  @moduledoc """
  Compute function for the `/notes.md` → `/notes_view` reactive view
  demo (Views Pass B, CX-d4q).

  Wraps the source markdown in a minimal 10-element view vocabulary
  XML payload. The `Commonplace.ViewCompute` GenServer calls `compute/1`
  on every source commit; the result is written to the target view
  doc via `Commonplace.CommandRouter.write/3`.

  This is intentionally a standalone function (not a closure) so it
  can be referenced as `&LiveNotesCompute.compute/1` and passed across
  process or node boundaries via RPC without closure-serialization
  gotchas.
  """

  @doc """
  Wrap the given markdown content as a commonplace View XML document.
  Returns a string suitable for writing to the target view doc.
  """
  @spec compute(String.t()) :: String.t()
  def compute(markdown) when is_binary(markdown) do
    escaped =
      markdown
      |> String.replace("&", "&amp;")
      |> String.replace("<", "&lt;")
      |> String.replace(">", "&gt;")

    timestamp =
      DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    """
    <view schema="1" signer="view-compute@live-notes" computed-at="#{timestamp}">
      <entity kind="live_notes" name="Live Notes">
        <provenance signer="view-compute@live-notes" ts="#{timestamp}"/>
        <body>
          <text format="markdown">
    #{escaped}
          </text>
          <field name="computed_at" value="#{timestamp}"/>
          <field name="source" value="/wiki/notes.md"/>
          <field name="compute" value="CommonplaceWebWeb.LiveNotesCompute.compute/1"/>
        </body>
        <action name="edit" label="Edit source" description="Opens the source markdown document for editing."/>
        <action name="history" label="Toggle history" description="Show or hide commit history."/>
      </entity>
    </view>
    """
  end
end
