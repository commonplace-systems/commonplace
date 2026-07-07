defmodule Commonplace.MUD.SessionView do
  @moduledoc """
  CX-i9j3 (UI Inc-1) — one per-session view-doc whose committed history
  IS the replayable MUD transcript.

  Each MUD session owns exactly one `SessionView`: a Yelixer XML doc
  (Y.js-compatible CRDT) shaped like

      <view session="S">
        <scrollback>                          <!-- APPEND-ONLY -->
          <turn n="1" ts="T" kind="command"><cmd>spin orrery</cmd><out>You spin the orrery...</out></turn>
          <turn n="2" ts="T" kind="ambient"><line>Grunk says: hello</line><line>Grunk waves.</line></turn>
        </scrollback>
        <room></room>                          <!-- REPLACE-subtree; Inc-1 leaves it an EMPTY stub -->
      </view>

  Rendered on demand to XHTML via `to_html/1`. `<room>` is scaffolded
  here as an empty stub — a later increment will make it a
  replace-whole-subtree region driven by the player's current location;
  Inc-1's job is only to prove the scrollback/commit/render loop.

  ## THE FOUR INVARIANTS

  These MUST hold, and every one of them is exercised by
  `session_view_test.exs`.

  ### 1. DELTA-not-full encode

  Every append (`append_command_turn/3`, `append_ambient_turn/2`)
  commits ONLY the incremental Yjs update —
  `Yelixer.Encoding.encode_diff(doc_after, sv_before)` — captured
  against the state vector as it stood *immediately before* the
  mutation. It NEVER calls `Yelixer.Encoding.encode_update/1` (a full
  re-encode of the whole doc) for an append. Full-encode-per-turn is an
  O(N) payload on turn N, so a transcript of N turns would cost O(N²)
  total bytes committed — measured elsewhere in this codebase at
  34-40x store blowup by 200 turns. Delta-encoding keeps each commit's
  payload ~flat regardless of how long the scrollback has grown, which
  is exactly what makes "commit history IS the transcript" viable
  instead of a quadratic trap. `session_view_test.exs` asserts this
  directly: the byte size of turn 50's commit stays within ~2x of turn
  1's.

  ### 2. Region isolation = delta isolation

  `<scrollback>` and `<room>` are SEPARATE child elements — independent
  CRDT subtrees (`Yelixer.Types.XMLElement` gives each element its own
  named children-sequence, so ops under one child never share a parent
  key with ops under the other). An append under `<scrollback>` mints
  Items parented to the scrollback subtree only; `<room>` is untouched,
  so its state vector contribution is unchanged and a scrollback
  append's delta carries no `<room>`-parented ops. This is what will
  let a later increment replace `<room>` wholesale (a `<room>` swap)
  without re-touching (or re-committing) any scrollback history, and
  vice versa: growing the scrollback never bloats a room-replace delta.

  ### 3. Node-signed

  Every commit — genesis via `Commonplace.Store.CommitStore.create_commit/6`
  and every append via
  `Commonplace.Store.CommitStoreClient.create_chained_commit/5` — passes
  `signing_context: node_ctx` sourced from
  `Commonplace.Crypto.NodeIdentity.signing_context/0`. Under
  `:enforce` local-write-gate mode, an unsigned write is denied outright;
  view-doc writes are infrastructure (the session's own transcript, not
  a player-authored artifact), so they're signed with the node's own
  identity rather than any particular player's.

  ### 4. Append-only scrollback

  Each turn is inserted at `index = child_count(scrollback)` — i.e. at
  the current END of the scrollback sequence — never at an earlier
  index, and existing `<turn>` elements are never mutated or deleted.
  Yelixer tombstones deletes rather than physically removing them, but
  this module never calls `delete_child/4` on the scrollback at all:
  the append path is insert-only, full stop.

  ## API

    - `new/3` — create the view doc + GENESIS commit (full doc content,
      encode_update — the one place a full encode is correct, because
      there's no prior state to diff against).
    - `append_command_turn/3` — append a `kind="command"` turn (cmd +
      out text), delta-commit, chained.
    - `append_ambient_turn/2` — append a `kind="ambient"` turn (N
      `<line>` children), delta-commit, chained.
    - `to_html/1` — render the live `<view>` element as an XHTML string.
    - `load/2` — reconstruct a `SessionView` from the commit chain
      (replay fidelity: `to_html/1` of a loaded view matches the live
      view it was loaded from).

  ## Struct fields

  `uuid`/`doc`/`store`/`sv`/`n` per the design brief, plus the three
  internal XML type-name handles (`view_name`, `scrollback_name`,
  `room_name`) threaded through so callers never have to re-derive
  Yelixer's synthetic child-naming scheme
  (`"<parent>::child::<client>:<clock>"`, see
  `Yelixer.Types.XMLFragment`) themselves. `view_name` is a *stable*
  top-level type name (`"view"`) chosen at construction time and
  preserved verbatim across encode/decode (Item `parent` fields carry
  the literal name on the wire), so `load/2` can always re-derive
  `scrollback_name`/`room_name` by re-querying `view_name`'s children
  after replay — no session-specific state needs to survive a reload
  beyond the uuid.
  """

  alias Yelixer.{Doc, Encoding, BlockStore}
  alias Yelixer.Types.{XMLElement, XMLText}
  alias Commonplace.Store.{CommitStore, CommitStoreClient}
  alias Commonplace.Crypto.NodeIdentity
  alias Commonplace.Tree.DocBuilder

  @view_name "view"

  defstruct [:uuid, :doc, :store, :sv, :n, :view_name, :scrollback_name, :room_name]

  @type t :: %__MODULE__{
          uuid: String.t(),
          doc: Doc.t(),
          store: term(),
          sv: term(),
          n: pos_integer(),
          view_name: String.t(),
          scrollback_name: String.t(),
          room_name: String.t()
        }

  @doc """
  Create a new session view doc: `<view session="S"><scrollback/><room/></view>`.

  The doc's `client_id` is derived deterministically from `session_id`
  (`:erlang.phash2/2`) so re-creating a view for the same session id
  lands on a stable client slot. Writes the GENESIS commit — a full
  `Yelixer.Encoding.encode_update/1` of the freshly-built doc (there is
  no prior state to diff against, so this is the one legitimate
  full-encode in this module) — node-signed via
  `Commonplace.Store.CommitStore.create_commit/6`.

  `opts`:
    - `:signing_context` — override the node signing context (defaults
      to `Commonplace.Crypto.NodeIdentity.signing_context/0`).
  """
  @spec new(String.t(), term(), keyword()) :: t()
  def new(session_id, store, opts \\ []) do
    client_id = :erlang.phash2(session_id, 0xFFFF_FFFF)
    doc = Doc.new(client_id: client_id)

    doc = XMLElement.new_element(doc, @view_name, "view")
    doc = XMLElement.set_attribute(doc, @view_name, "session", to_string(session_id))

    doc = XMLElement.insert_child(doc, @view_name, 0, {:element, "scrollback"})
    doc = XMLElement.insert_child(doc, @view_name, 1, {:element, "room"})

    {scrollback_name, room_name} = region_names(doc)

    uuid = UUID.uuid4()
    node_ctx = signing_context!(opts)
    update = Encoding.encode_update(doc)

    commit = CommitStore.create_commit(store, uuid, update, nil, %{}, signing_context: node_ctx)
    ensure_committed!(commit, :genesis)

    %__MODULE__{
      uuid: uuid,
      doc: doc,
      store: store,
      sv: BlockStore.state_vector(doc.store),
      n: 1,
      view_name: @view_name,
      scrollback_name: scrollback_name,
      room_name: room_name
    }
  end

  @doc """
  Append a `kind="command"` turn — `<turn n=.. ts=.. kind="command"><cmd>cmd_text</cmd><out>out_text</out></turn>` —
  at the end of `<scrollback>`. Commits ONLY the incremental delta
  (invariant 1), chained + node-signed (invariant 3). Returns the
  updated `%SessionView{}` with `n` advanced and `sv` refreshed to the
  post-commit state vector.
  """
  @spec append_command_turn(t(), String.t(), String.t()) :: t()
  def append_command_turn(%__MODULE__{} = view, cmd_text, out_text)
      when is_binary(cmd_text) and is_binary(out_text) do
    sv_before = BlockStore.state_vector(view.doc.store)

    {doc, turn_name} = append_turn_shell(view.doc, view.scrollback_name, view.n, "command")
    {doc, _} = insert_text_element(doc, turn_name, 0, "cmd", cmd_text)
    {doc, _} = insert_text_element(doc, turn_name, 1, "out", out_text)

    commit_delta!(view, doc, sv_before)
  end

  @doc """
  Append a `kind="ambient"` turn — `<turn n=.. ts=.. kind="ambient"><line>...</line>...</turn>` —
  one `<line>` child per string in `lines` (in order), at the end of
  `<scrollback>`. `lines` must be a non-empty list. Commits ONLY the
  incremental delta (invariant 1), chained + node-signed (invariant 3).
  Returns the updated `%SessionView{}` with `n` advanced and `sv`
  refreshed.
  """
  @spec append_ambient_turn(t(), [String.t()]) :: t()
  def append_ambient_turn(%__MODULE__{} = view, lines) when is_list(lines) and lines != [] do
    sv_before = BlockStore.state_vector(view.doc.store)

    {doc, turn_name} = append_turn_shell(view.doc, view.scrollback_name, view.n, "ambient")

    doc =
      lines
      |> Enum.with_index()
      |> Enum.reduce(doc, fn {line_text, index}, doc ->
        {doc, _} = insert_text_element(doc, turn_name, index, "line", line_text)
        doc
      end)

    commit_delta!(view, doc, sv_before)
  end

  @doc "Render the entire `<view>` element as an XHTML string."
  @spec to_html(t()) :: String.t()
  def to_html(%__MODULE__{doc: doc, view_name: view_name}) do
    XMLElement.to_string(doc, view_name)
  end

  @doc """
  Reconstruct a `SessionView` from `uuid`'s commit chain via
  `Commonplace.Tree.DocBuilder.reconstruct_doc/2`. Recovers `n` as
  `scrollback child_count + 1` and `sv` from the replayed doc's state
  vector. Returns `{:ok, view}` or `{:error, reason}`.
  """
  @spec load(String.t(), term()) :: {:ok, t()} | {:error, term()}
  def load(uuid, store) do
    case DocBuilder.reconstruct_doc(store, uuid) do
      {:ok, doc} ->
        doc = reregister_root_tag(doc)
        {scrollback_name, room_name} = region_names(doc)
        n = XMLElement.child_count(doc, scrollback_name) + 1

        {:ok,
         %__MODULE__{
           uuid: uuid,
           doc: doc,
           store: store,
           sv: BlockStore.state_vector(doc.store),
           n: n,
           view_name: @view_name,
           scrollback_name: scrollback_name,
           room_name: room_name
         }}

      :none ->
        {:error, :not_found}

      {:error, _} = err ->
        err
    end
  end

  # --- Private helpers ---

  # SUBSTRATE SURPRISE (see moduledoc): a top-level named XMLElement's
  # own tag registration (`doc.types[type_name] = {:xml_element, tag}`)
  # is set locally by `XMLElement.new_element/3` and is NEVER encoded
  # onto the wire — only Items are. `Yelixer.Encoding.apply_update/2`'s
  # `infer_type_ref/2` only recovers a type_ref for items whose parent
  # is `{:id, _}` (map/array-of-types values) or for XML children via
  # `maybe_register_xml_child_type/3` (keys ending in `"::children"`).
  # A root registered under a *named*, non-synthetic key (our `"view"`)
  # falls through both paths: the first item integrated with
  # `parent: {:named, "view"}` (e.g. the `session` attribute) makes
  # `Doc.get_or_create_type(doc, "view", :unknown)` stick — and since
  # `get_or_create_type` never overwrites an existing key,
  # `tag_name(doc, "view")` comes back `nil` forever after a replay,
  # silently corrupting `to_string/2`'s `<tag>` open/close tags. Fixed
  # names known statically (ours always is `"view"`, tag `"view"`) must
  # be force-re-registered after `reconstruct_doc/2` — done here, since
  # replay can never recover it on its own.
  defp reregister_root_tag(doc) do
    %{doc | types: Map.put(doc.types, @view_name, {:xml_element, "view"})}
  end

  # Re-derive the scrollback/room child type-names by position: index 0
  # is always <scrollback>, index 1 is always <room> (fixed by `new/3`'s
  # insertion order and never reordered afterwards).
  defp region_names(doc) do
    [{:element, "scrollback", scrollback_name}, {:element, "room", room_name}] =
      XMLElement.children(doc, @view_name)

    {scrollback_name, room_name}
  end

  defp append_turn_shell(doc, scrollback_name, n, kind) do
    index = XMLElement.child_count(doc, scrollback_name)
    doc = XMLElement.insert_child(doc, scrollback_name, index, {:element, "turn"})
    turn_name = last_child_name(doc, scrollback_name)

    ts = DateTime.utc_now() |> DateTime.to_iso8601()

    doc =
      doc
      |> XMLElement.set_attribute(turn_name, "n", to_string(n))
      |> XMLElement.set_attribute(turn_name, "ts", ts)
      |> XMLElement.set_attribute(turn_name, "kind", kind)

    {doc, turn_name}
  end

  # Insert `<tag>text</tag>` as child `index` of `parent_name`. Returns
  # `{doc, element_type_name}`.
  defp insert_text_element(doc, parent_name, index, tag, text) do
    doc = XMLElement.insert_child(doc, parent_name, index, {:element, tag})
    {:element, ^tag, elem_name} = Enum.at(XMLElement.children(doc, parent_name), index)

    doc = XMLElement.insert_child(doc, elem_name, 0, :text)
    [{:text, text_name}] = XMLElement.children(doc, elem_name)

    doc = XMLText.insert(doc, text_name, 0, text)
    {doc, elem_name}
  end

  defp last_child_name(doc, parent_name) do
    {:element, _tag, name} = XMLElement.children(doc, parent_name) |> List.last()
    name
  end

  defp signing_context!(opts) do
    case Keyword.get(opts, :signing_context) do
      nil ->
        {:ok, node_ctx} = NodeIdentity.signing_context()
        node_ctx

      ctx ->
        ctx
    end
  end

  defp commit_delta!(%__MODULE__{} = view, doc, sv_before) do
    delta = Encoding.encode_diff(doc, sv_before)
    node_ctx = signing_context!([])

    commit =
      CommitStoreClient.create_chained_commit(view.store, view.uuid, delta, %{},
        signing_context: node_ctx
      )

    ensure_committed!(commit, :append)

    %{view | doc: doc, n: view.n + 1, sv: BlockStore.state_vector(doc.store)}
  end

  defp ensure_committed!(commit, stage) do
    if match?({:error, _}, commit) do
      raise "Commonplace.MUD.SessionView #{stage} commit failed: #{inspect(commit)}"
    else
      :ok
    end
  end
end
