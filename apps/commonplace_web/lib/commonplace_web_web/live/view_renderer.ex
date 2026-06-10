defmodule CommonplaceWebWeb.ViewRenderer do
  @moduledoc """
  Renders a commonplace View document as HTML (Phoenix-safe iodata).

  Entry point is `render_view/2`, which takes the raw XML string from a
  view document plus the current wiki path and returns a `{:safe, iodata}`
  tuple suitable for embedding in a LiveView template via `<%= ... %>`.

  Per `docs/views.md`, this renderer covers the 10-element vocabulary:
  `<view>`, `<entity>`, `<body>`, `<text>`, `<field>`, `<list>`,
  `<action>`, `<include>`, `<provenance>`, `<raw>`. Unknown elements
  outside this vocabulary are not errors — the renderer drops the
  wrapper and renders their children, staying forward-compatible with
  future vocabulary additions.

  Action rendering (CX-vaw / CX-lok1) — an `<action>` renders one of
  two ways, keyed on its `args` attribute:
  - **no `args`** → a `phx-click="view_action"` button (the wiki
    edit / history / fork path);
  - **`args="name:type,…"`** → a `phx-submit="view_action"` form with
    one text input per declared arg (the chat MVP path: post_message /
    edit_message / delete_message). M3 supports `:string` args only;
    other types fall back to a text input.

  Either way the wiki LiveView catches the event and forwards through
  `CommonplaceWebWeb.ViewActions.dispatch/3`.

  Remaining first-pass limits:
  - Transclusion (`<include>`) is expanded once at the top of
    `render_view/2` via `Commonplace.Document.ViewTransclusion.expand/2`,
    which resolves the `from` docref against the workspace root schema
    and splices the target's content in as children. See that module's
    moduledoc for scope (one level of recursion at a time, depth-limited,
    cycle-detected).
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
        view = Commonplace.Document.ViewTransclusion.expand(view)
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
    kind = n.attrs["kind"]

    # CX-lok1 (M3 sub-bead iv): kind-aware CSS class so consumers
    # (chat stylesheet, future view kinds) can style per-kind without
    # the renderer baking domain knowledge in. Generic <entity> with
    # no kind keeps the legacy single-class shape.
    class =
      case kind do
        nil -> "cp-entity border border-base-300 rounded-lg p-4 bg-base-100 space-y-2"
        k -> ~s(cp-entity entity--#{escape(k)} border border-base-300 rounded-lg p-4 bg-base-100 space-y-2)
      end

    name = n.attrs["name"]
    label = kind || "entity"

    [
      ~s(<section class="),
      class,
      ~s(">),
      ~s(<header class="flex items-center gap-2 text-xs uppercase tracking-wide text-base-content/60">),
      ~s(<span class="badge badge-sm badge-primary">),
      escape(label),
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
    target = n.attrs["target"]

    # CX-lok1 (M3 sub-bead iv): branch on `args` attribute presence.
    # With args → phx-submit FORM with one input per arg (chat MVP path).
    # Without args → phx-click button (existing wiki path; edit/history/fork).
    case args do
      nil -> render_action_button(name, label, description, target)
      "" -> render_action_button(name, label, description, target)
      args_str -> render_action_form(name, label, description, target, args_str)
    end
  end

  defp render_node(%Node{tag: :include} = n, path) do
    # Content has already been expanded by
    # `Commonplace.Document.ViewTransclusion.expand/2` at the top of
    # `render_view/2` before this clause runs — any empty includes
    # either have their resolved children, an error-child explanation,
    # or a cycle/depth-limit marker child.
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

  # --- CX-lok1 (M3 sub-bead iv) action helpers ---

  # Phx-click button for actions with no args (today's edit/history/fork).
  defp render_action_button(name, label, description, target) do
    target_attr =
      if target, do: [~s( phx-value-target="), escape(target), ~s(")], else: ""

    title_attr =
      if description, do: [~s( title="), escape(description), ~s(")], else: ""

    [
      ~s(<div class="cp-action inline-flex flex-col gap-1 mr-2">),
      ~s(<button type="button" class="btn btn-sm btn-primary),
      ~s(" phx-click="view_action),
      ~s(" phx-value-action="),
      escape(name),
      ~s("),
      target_attr,
      title_attr,
      ">",
      escape(label),
      "</button>",
      if(description,
        do: [~s(<span class="text-xs text-base-content/50">), escape(description), "</span>"],
        else: ""
      ),
      "</div>"
    ]
  end

  # Phx-submit FORM for actions with args (chat MVP: post_message,
  # edit_message, delete_message). One <input> per declared arg. String
  # is the only supported type for M3 (refinement A); future types file
  # followups.
  defp render_action_form(name, label, description, target, args_str) do
    target_attr =
      if target, do: [~s( phx-value-target="), escape(target), ~s(")], else: ""

    inputs = parse_args(args_str) |> Enum.map(&render_arg_input/1)

    [
      ~s(<form class="cp-action flex items-center gap-2 my-2"),
      ~s( phx-submit="view_action),
      ~s(" phx-value-action="),
      escape(name),
      ~s("),
      target_attr,
      ">",
      inputs,
      ~s(<button type="submit" class="btn btn-sm btn-primary">),
      escape(label),
      "</button>",
      if(description,
        do: [~s(<span class="text-xs text-base-content/50">), escape(description), "</span>"],
        else: ""
      ),
      "</form>"
    ]
  end

  # Parse `args="text:string,message_id:string"` into a list of
  # %{name: ..., type: ...} maps. Tolerant of whitespace + missing type.
  defp parse_args(args_str) do
    args_str
    |> String.split(",", trim: true)
    |> Enum.map(fn segment ->
      case String.split(String.trim(segment), ":", parts: 2) do
        [name, type] -> %{name: String.trim(name), type: String.trim(type)}
        [name] -> %{name: String.trim(name), type: "string"}
      end
    end)
    |> Enum.reject(&(&1.name == ""))
  end

  defp render_arg_input(%{name: name}) do
    # Only :string is supported for M3 (refinement A); other types fall
    # back to text input. File followups when non-string args surface.
    [
      ~s(<input type="text" name="),
      escape(name),
      ~s(" placeholder="),
      escape(name),
      ~s(" required class="input input-sm input-bordered flex-1"/>)
    ]
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
