defmodule CommonplaceWebWeb.ViewRenderer do
  @moduledoc """
  Renders a commonplace View document as HTML (Phoenix-safe iodata).

  Entry point is `render_view/2`, which takes the raw XML string from a
  view document plus the current wiki path and returns a `{:safe, iodata}`
  tuple suitable for embedding in a LiveView template via `<%= ... %>`.

  Per `docs/views.md`, this renderer covers the 10-element vocabulary:
  `<view>`, `<entity>`, `<body>`, `<text>`, `<field>`, `<list>`,
  `<action>`, `<include>`, `<provenance>`, `<raw>`.

  First-pass limits (CX-817):
  - Actions render as inert buttons (dispatch is phase 2).
  - Transclusion (`<include>`) renders whatever content is inlined in
    the element — no upstream resolver.
  - `<raw>` elements display a warning badge + their literal content
    escaped. Honoring raw content is explicitly deferred until a trust
    mechanism exists.
  - Markdown inside `<text format="markdown">` goes through a small
    line-based mini-renderer (headings, lists, paragraphs, inline
    `[[wiki-links]]`, bold/italic/code), matching the existing WikiLive
    rendering style.
  - Staleness attributes (`stale`, `stale-relative-to`) are parsed but
    not yet surfaced in the UI.
  """

  import Phoenix.HTML, only: [raw: 1]

  alias Commonplace.Document.ViewXml
  alias Commonplace.Document.ViewXml.Node

  @doc """
  Render a view XML string into Phoenix-safe HTML iodata.

  Returns `{:safe, iodata}` on success. On parse failure, returns a
  visible error block so the wiki viewer shows a useful diagnostic
  rather than a blank page.
  """
  @spec render_view(String.t(), String.t()) :: Phoenix.HTML.safe()
  def render_view(content, current_path) when is_binary(content) do
    case ViewXml.parse(content) do
      {:ok, %Node{tag: :view} = view} ->
        raw(render_node(view, current_path))

      {:ok, %Node{tag: other}} ->
        raw([
          ~s(<div class="alert alert-warning">Expected a &lt;view&gt; root element, got &lt;),
          Atom.to_string(other),
          "&gt;.</div>"
        ])

      {:error, reason} ->
        raw([
          ~s(<div class="alert alert-error"><p class="font-bold">View parse error</p><pre class="text-xs mt-2">),
          escape(inspect(reason)),
          "</pre></div>"
        ])
    end
  end

  # --- Node dispatch ---

  defp render_node(%Node{tag: :view} = n, path) do
    children = render_children(n, path)
    stale_badge = if n.attrs["stale"] == "true", do: stale_indicator(n), else: ""

    [
      ~s(<div class="cp-view space-y-4">),
      stale_badge,
      children,
      "</div>"
    ]
  end

  defp render_node(%Node{tag: :entity} = n, path) do
    kind = n.attrs["kind"] || "entity"
    name = n.attrs["name"]

    [
      ~s(<section class="cp-entity border border-base-300 rounded-lg p-4 bg-base-100 space-y-2">),
      ~s(<header class="flex items-center gap-2 text-xs uppercase tracking-wide text-base-content/60">),
      ~s(<span class="badge badge-sm badge-primary">),
      escape(kind),
      "</span>",
      if(name, do: [~s(<span class="font-semibold text-base-content/80">), escape(name), "</span>"], else: ""),
      "</header>",
      render_children(n, path),
      "</section>"
    ]
  end

  defp render_node(%Node{tag: :body} = n, path) do
    [
      ~s(<div class="cp-body space-y-3">),
      render_children(n, path),
      "</div>"
    ]
  end

  defp render_node(%Node{tag: :text} = n, path) do
    format = n.attrs["format"] || "plain"
    text = ViewXml.text_content(n)

    case format do
      "markdown" ->
        [
          ~s(<div class="cp-text prose max-w-none">),
          render_markdown(text, path),
          "</div>"
        ]

      "code" ->
        lang = n.attrs["language"] || ""

        [
          ~s(<pre class="cp-text-code bg-base-300 rounded p-3 text-sm overflow-x-auto"><code class=") ,
          escape("language-" <> lang),
          ~s(">),
          escape(text),
          "</code></pre>"
        ]

      _ ->
        [
          ~s(<p class="cp-text whitespace-pre-wrap">),
          escape(text),
          "</p>"
        ]
    end
  end

  defp render_node(%Node{tag: :field} = n, _path) do
    name = n.attrs["name"] || ""
    value = n.attrs["value"] || ViewXml.text_content(n)

    [
      ~s(<div class="cp-field flex items-baseline gap-2 text-sm">),
      ~s(<dt class="font-medium text-base-content/60 min-w-20">),
      escape(name),
      ":</dt>",
      ~s(<dd class="text-base-content">),
      escape(value),
      "</dd></div>"
    ]
  end

  defp render_node(%Node{tag: :list} = n, path) do
    children =
      n.children
      |> Enum.map(fn
        %Node{} = child ->
          [
            ~s(<li class="cp-list-item">),
            render_node(child, path),
            "</li>"
          ]

        text when is_binary(text) ->
          [~s(<li class="cp-list-item">), escape(text), "</li>"]
      end)

    [
      ~s(<ul class="cp-list space-y-2 list-none pl-0">),
      children,
      "</ul>"
    ]
  end

  defp render_node(%Node{tag: :action} = n, _path) do
    name = n.attrs["name"] || "action"
    label = n.attrs["label"] || name
    description = n.attrs["description"]
    args = n.attrs["args"]

    [
      ~s(<div class="cp-action inline-flex flex-col gap-1 mr-2">),
      # Inert button — dispatch wiring is phase 2.
      ~s(<button type="button" class="btn btn-sm btn-outline btn-disabled" title="View actions are not yet wired up — phase 2">),
      escape(label),
      "</button>",
      if(description,
        do: [~s(<span class="text-xs text-base-content/50">), escape(description), "</span>"],
        else: ""
      ),
      if(args,
        do: [~s(<span class="text-xs font-mono text-base-content/40">args: ), escape(args), "</span>"],
        else: ""
      ),
      "</div>"
    ]
  end

  defp render_node(%Node{tag: :include} = n, path) do
    from = n.attrs["from"] || "?"
    commit = n.attrs["commit"]

    [
      ~s(<aside class="cp-include border-l-4 border-primary/40 pl-4 py-2 bg-base-200/40 rounded-r">),
      ~s(<div class="text-xs text-base-content/50 mb-2 font-mono">⎆ transcluded from ),
      escape(from),
      if(commit, do: [" @ ", escape(commit)], else: ""),
      "</div>",
      render_children(n, path),
      "</aside>"
    ]
  end

  defp render_node(%Node{tag: :provenance} = n, _path) do
    signer = n.attrs["signer"]
    ts = n.attrs["ts"]
    commit = n.attrs["commit"]

    parts =
      [
        if(signer, do: [~s(by <span class="font-medium">), escape(signer), "</span>"], else: nil),
        if(ts, do: [" on ", escape(ts)], else: nil),
        if(commit, do: [" (", escape(commit), ")"], else: nil)
      ]
      |> Enum.reject(&is_nil/1)

    [
      ~s(<div class="cp-provenance text-xs text-base-content/50 italic">),
      parts,
      "</div>"
    ]
  end

  defp render_node(%Node{tag: :raw} = n, _path) do
    target = n.attrs["target"] || "unknown"

    [
      ~s(<div class="cp-raw alert alert-warning my-2">),
      ~s{<div class="text-xs font-bold">⚠ &lt;raw target="},
      escape(target),
      ~s{"&gt; content is not rendered (trust model not yet implemented)</div>},
      ~s(<pre class="text-xs mt-1 overflow-x-auto">),
      escape(ViewXml.text_content(n)),
      "</pre>",
      "</div>"
    ]
  end

  defp render_node(%Node{tag: :unknown} = n, path) do
    # Unknown elements: render their children and swallow the unknown wrapper.
    # Forward-compatible with future vocabulary additions.
    render_children(n, path)
  end

  defp render_node(%Node{} = n, path) do
    # Catchall — shouldn't be reached given :unknown fallback, but defensive.
    render_children(n, path)
  end

  defp render_children(%Node{children: children}, path) do
    Enum.map(children, fn
      %Node{} = child -> render_node(child, path)
      text when is_binary(text) -> escape(text)
    end)
  end

  # --- Staleness indicator ---

  defp stale_indicator(%Node{attrs: attrs}) do
    rel = attrs["stale-relative-to"]

    [
      ~s(<div class="alert alert-info text-sm"><span class="font-bold">recomputing…</span>),
      if(rel, do: [" triggered by ", escape(rel)], else: ""),
      "</div>"
    ]
  end

  # --- Minimal markdown (mirrors WikiLive's render_wiki_content style) ---

  defp render_markdown(text, current_path) do
    text
    |> String.split("\n")
    |> Enum.map(&render_md_line(&1, current_path))
  end

  defp render_md_line(line, current_path) do
    cond do
      String.starts_with?(line, "### ") ->
        [
          ~s(<h3 class="text-lg font-semibold mt-4 mb-2">),
          render_md_inline(String.trim_leading(line, "### "), current_path),
          "</h3>"
        ]

      String.starts_with?(line, "## ") ->
        [
          ~s(<h2 class="text-xl font-semibold mt-5 mb-2">),
          render_md_inline(String.trim_leading(line, "## "), current_path),
          "</h2>"
        ]

      String.starts_with?(line, "# ") ->
        [
          ~s(<h1 class="text-2xl font-bold mt-6 mb-3">),
          render_md_inline(String.trim_leading(line, "# "), current_path),
          "</h1>"
        ]

      String.starts_with?(line, "- ") or String.starts_with?(line, "* ") ->
        [
          ~s(<li class="ml-4 list-disc">),
          render_md_inline(String.slice(line, 2..-1//1), current_path),
          "</li>"
        ]

      line == "" ->
        "<br>"

      true ->
        [
          "<p>",
          render_md_inline(line, current_path),
          "</p>"
        ]
    end
  end

  defp render_md_inline(text, current_path) do
    # Escape first, then layer in wiki-links + bold/italic/code.
    escaped = escape(text)

    wiki_linked =
      Regex.replace(~r/\[\[([^\]]+)\]\]/, escaped, fn _, inner ->
        {page, display} =
          case String.split(inner, "|", parts: 2) do
            [page, display] -> {String.trim(page), String.trim(display)}
            [page] -> {String.trim(page), String.trim(page)}
          end

        href = build_wiki_path(current_path, sanitize_page_name(page))

        ~s(<a href=") <> escape(href) <> ~s(" class="text-primary hover:underline font-medium">) <>
          escape(display) <> "</a>"
      end)

    wiki_linked
    |> String.replace(~r/\*\*(.+?)\*\*/, "<strong>\\1</strong>")
    |> String.replace(~r/\*(.+?)\*/, "<em>\\1</em>")
    |> String.replace(~r/`(.+?)`/, ~s(<code class="bg-base-300 px-1 rounded text-sm">\\1</code>))
  end

  defp build_wiki_path("", name), do: "/wiki/" <> name
  defp build_wiki_path(path, name), do: "/wiki/" <> path <> "/" <> name

  defp sanitize_page_name(name) do
    name
    |> String.trim()
    |> String.replace(~r/[^\w\s\-.]/, "")
    |> String.replace(~r/\s+/, "-")
    |> String.downcase()
  end

  defp escape(text) when is_binary(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end

  defp escape(other), do: escape(to_string(other))
end
