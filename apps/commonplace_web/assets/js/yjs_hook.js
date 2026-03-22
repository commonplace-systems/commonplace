import * as Y from "yjs"

/**
 * LiveView hook for Yjs document rendering.
 *
 * Receives Yjs binary updates from the server via push_event,
 * maintains a local Y.Doc, and renders content into the hook element.
 *
 * Events from server:
 *   yjs_init  - {update: base64-encoded Yjs state}
 *   yjs_update - {update: base64-encoded Yjs update}
 *
 * The document content is read from the "content" key in the
 * root YMap (following the commonplace document envelope).
 */
const YjsHook = {
  mounted() {
    this.ydoc = null

    this.handleEvent("yjs_init", ({update}) => {
      // Create fresh doc and apply initial state
      this.ydoc = new Y.Doc()
      const binary = Uint8Array.from(atob(update), c => c.charCodeAt(0))
      Y.applyUpdate(this.ydoc, binary)
      this.render()

      // Observe future changes
      this.ydoc.on("update", () => {
        this.render()
      })
    })

    this.handleEvent("yjs_update", ({update}) => {
      if (!this.ydoc) return
      const binary = Uint8Array.from(atob(update), c => c.charCodeAt(0))
      Y.applyUpdate(this.ydoc, binary)
      // render triggered by the update observer above
    })
  },

  render() {
    if (!this.ydoc) {
      this.el.innerHTML = "<p class='text-gray-400'>No document loaded</p>"
      return
    }

    // Read content from the commonplace document envelope
    // The envelope has a "content" YMap/YText at the root level
    const content = this.getContent()
    const docType = this.getDocType()

    if (docType === "text") {
      // Plain text — render in a pre tag
      this.el.innerHTML = `<pre class="font-mono text-sm whitespace-pre-wrap">${this.escapeHtml(content)}</pre>`
    } else if (content && (content.includes("<") || docType === "html" || docType === "xml")) {
      // HTML/XML content — render as live DOM
      // Wrap in a container for safety
      this.el.innerHTML = `<div class="yjs-content">${content}</div>`
    } else if (typeof content === "object") {
      // Map content — render as formatted JSON
      this.el.innerHTML = `<pre class="font-mono text-sm whitespace-pre-wrap">${this.escapeHtml(JSON.stringify(content, null, 2))}</pre>`
    } else {
      this.el.innerHTML = `<pre class="font-mono text-sm whitespace-pre-wrap">${this.escapeHtml(String(content || ""))}</pre>`
    }
  },

  getContent() {
    // Try reading from the commonplace envelope structure
    // Root has "content" type which holds the actual data
    const rootKeys = Array.from(this.ydoc.share.keys())

    // Check for "content" YText (text documents)
    if (this.ydoc.share.has("content")) {
      const contentType = this.ydoc.share.get("content")
      if (contentType instanceof Y.Text) {
        return contentType.toString()
      } else if (contentType instanceof Y.Map) {
        return contentType.toJSON()
      }
    }

    // Fallback: try reading from the first YText we find
    for (const [key, type] of this.ydoc.share) {
      if (key === "_type" || key === "_name") continue
      if (type instanceof Y.Text) return type.toString()
      if (type instanceof Y.Map) return type.toJSON()
    }

    return "(empty document)"
  },

  getDocType() {
    if (this.ydoc.share.has("_type")) {
      const typeField = this.ydoc.share.get("_type")
      if (typeField instanceof Y.Text) return typeField.toString()
      if (typeField instanceof Y.Map) {
        const val = typeField.get("value")
        return val || "unknown"
      }
    }
    return "unknown"
  },

  escapeHtml(str) {
    const div = document.createElement("div")
    div.textContent = str
    return div.innerHTML
  },

  destroyed() {
    if (this.ydoc) {
      this.ydoc.destroy()
      this.ydoc = null
    }
  }
}

export default YjsHook
