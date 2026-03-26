import * as Y from "yjs"
import { EditorView, basicSetup } from "codemirror"
import { EditorState } from "@codemirror/state"
import { yCollab } from "y-codemirror.next"

/**
 * LiveView hook for Yjs document editing via CodeMirror.
 *
 * Receives Yjs binary updates from the server via push_event,
 * maintains a local Y.Doc bound to a CodeMirror editor.
 * Edits flow back to the server via pushEvent.
 *
 * Events from server:
 *   yjs_init   - {update: base64-encoded Yjs state}
 *   yjs_update - {update: base64-encoded Yjs update}
 *
 * Events to server:
 *   yjs_edit   - {update: base64-encoded Yjs update}
 */
const YjsHook = {
  mounted() {
    this.ydoc = null
    this.editor = null
    this.suppressOutbound = false

    this.handleEvent("yjs_init", ({update}) => {
      console.log("[YjsHook] yjs_init received, update length:", update ? update.length : "null/undefined")
      this.initDoc(update)
    })

    this.handleEvent("yjs_update", ({update}) => {
      if (!this.ydoc) return
      this.suppressOutbound = true
      const binary = this.decode(update)
      Y.applyUpdate(this.ydoc, binary)
      this.suppressOutbound = false
    })

    // Request initial data from server — ensures hook is ready before data arrives
    console.log("[YjsHook] mounted, requesting init data")
    this.pushEvent("yjs_request_init", {})
  },

  initDoc(update) {
    // Clean up previous
    if (this.editor) {
      this.editor.destroy()
      this.editor = null
    }
    if (this.ydoc) {
      this.ydoc.destroy()
      this.ydoc = null
    }

    // Create Y.Doc and apply initial state
    this.ydoc = new Y.Doc()
    const binary = this.decode(update)
    console.log("[YjsHook] decoded binary length:", binary.length)
    Y.applyUpdate(this.ydoc, binary)

    // Log all shared types in the doc
    console.log("[YjsHook] doc shared types:", [...this.ydoc.share.keys()])
    for (const [key, type] of this.ydoc.share) {
      console.log(`[YjsHook]   ${key}: ${type.constructor.name}, content: ${type instanceof Y.Text ? JSON.stringify(type.toString().substring(0, 100)) : "(not text)"}`)
    }

    // Find the text content in the document envelope
    const ytext = this.findTextContent()
    console.log("[YjsHook] findTextContent result:", ytext ? `YText(${ytext.toString().substring(0, 50)})` : "null")

    if (ytext) {
      this.initEditor(ytext)
    } else {
      // Fallback: render as read-only content display
      this.renderReadOnly()
    }

    // Listen for local changes to send back to server
    this.ydoc.on("update", (update, origin) => {
      if (this.suppressOutbound) return
      if (origin === "codemirror") return // avoid echo
      const encoded = this.encode(update)
      this.pushEvent("yjs_edit", {update: encoded})
    })
  },

  initEditor(ytext) {
    this.el.innerHTML = ""

    const state = EditorState.create({
      doc: ytext.toString(),
      extensions: [
        basicSetup,
        yCollab(ytext),
        EditorView.theme({
          "&": { height: "100%", fontSize: "14px" },
          ".cm-scroller": { overflow: "auto" },
          ".cm-content": { fontFamily: "monospace" }
        }),
        // Capture changes and send to server
        EditorView.updateListener.of((viewUpdate) => {
          if (viewUpdate.docChanged && !this.suppressOutbound) {
            // y-codemirror handles syncing edits into the Y.Text
            // We just need to send the Yjs update to the server
            const update = Y.encodeStateAsUpdate(this.ydoc)
            const encoded = this.encode(update)
            this.pushEvent("yjs_edit", {update: encoded})
          }
        })
      ]
    })

    this.editor = new EditorView({
      state,
      parent: this.el
    })
  },

  renderReadOnly() {
    // Non-text content: render as formatted display
    const content = this.extractContent()

    if (typeof content === "object") {
      this.el.innerHTML = `<pre class="font-mono text-sm p-4 bg-gray-100 rounded whitespace-pre-wrap">${this.escapeHtml(JSON.stringify(content, null, 2))}</pre>`
    } else {
      this.el.innerHTML = `<pre class="font-mono text-sm p-4 bg-gray-100 rounded whitespace-pre-wrap">${this.escapeHtml(String(content || "(empty)"))}</pre>`
    }
  },

  findTextContent() {
    // Look for "content" YText in the document envelope
    // Use getText() to ensure proper Y.Text typing (share.get may return AbstractType)
    if (this.ydoc.share.has("content")) {
      try {
        const content = this.ydoc.getText("content")
        if (content && content.toString() !== "") return content
        // Even empty text is valid — return it if the type exists
        if (content) return content
      } catch(e) {
        console.log("[YjsHook] content exists but is not YText:", e.message)
      }
    }

    // Fallback: find any shared type that contains text data
    for (const [key, type] of this.ydoc.share) {
      if (key.startsWith("_")) continue
      if (type instanceof Y.Text) return type
      // Try getting as text
      try {
        const t = this.ydoc.getText(key)
        if (t && t.length > 0) return t
      } catch(e) { /* not a text type */ }
    }

    return null
  },

  extractContent() {
    for (const [key, type] of this.ydoc.share) {
      if (key.startsWith("_")) continue
      if (type instanceof Y.Text) return type.toString()
      if (type instanceof Y.Map) return type.toJSON()
    }
    return null
  },

  decode(base64) {
    return Uint8Array.from(atob(base64), c => c.charCodeAt(0))
  },

  encode(uint8array) {
    return btoa(String.fromCharCode(...uint8array))
  },

  escapeHtml(str) {
    const div = document.createElement("div")
    div.textContent = str
    return div.innerHTML
  },

  destroyed() {
    if (this.editor) {
      this.editor.destroy()
      this.editor = null
    }
    if (this.ydoc) {
      this.ydoc.destroy()
      this.ydoc = null
    }
  }
}

export default YjsHook
