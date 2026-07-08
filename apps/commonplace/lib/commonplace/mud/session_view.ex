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
        <room>                                 <!-- REPLACE-subtree; live as of Inc-1 increment 2 -->
          <name>..</name><desc>..</desc><exits>..</exits><contents>..</contents><occupants>..</occupants>
        </room>
      </view>

  Rendered on demand to XHTML via `to_html/1`. `<room>` is a
  REPLACE-whole-subtree region: `replace_room/2` tombstones its current
  children and re-inserts a fresh five-section snapshot in ONE delta
  commit, independent of the append-only `<scrollback>`. Ambient lines
  can be coalesced M→1 through `Commonplace.MUD.SessionView.AmbientBuffer`
  (a pure, timer-free buffer) so a burst of ambient events lands as a
  single `append_ambient_turn/2` commit rather than one per line.

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
  append's delta carries no `<room>`-parented ops. This lets
  `replace_room/2` swap `<room>` wholesale without re-touching (or
  re-committing) any scrollback history, and vice versa: growing the
  scrollback never bloats a room-replace delta. `session_view_test.exs`
  asserts BOTH directions directly — a room-replace's delta stays flat
  as scrollback grows, and a scrollback append's delta stays flat when
  `<room>` is non-empty.

  ### 3. Node-signed

  Every commit this module AUTHORS — the `new/3` content commit (via
  `Commonplace.Store.CommitStoreClient.create_commit/6`) and every
  append/replace (via
  `Commonplace.Store.CommitStoreClient.create_chained_commit/5`) —
  passes `signing_context: node_ctx` sourced from
  `Commonplace.Crypto.NodeIdentity.signing_context/0`. Under
  `:enforce` local-write-gate mode, an unsigned write is denied outright;
  view-doc writes are infrastructure (the session's own transcript, not
  a player-authored artifact), so they're signed with the node's own
  identity rather than any particular player's.

  ONE precise exception: `create_commit(parent_id: nil)` for the very
  first write triggers the deterministic-genesis stamp (CX-m3x), which
  materializes an UNSIGNED synthetic root row (`parent_id: nil`,
  `signer_id: nil`) and chains our signed `new/3` content commit onto it.
  That stamp is a contentless, system-generated, deterministic marker (the
  same one every commonplace doc gets), NOT a SessionView write — it
  carries none of the transcript. So the audit property holds: every
  commit that carries transcript content is node-signed; only the empty
  synthetic root is unsigned. `session_view_test.exs` asserts exactly
  this — every chain commit with a non-nil `parent_id` parses to the node
  identity.

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
    - `replace_room/2` — REPLACE the `<room>` subtree with a fresh
      five-section snapshot in one delta commit (does NOT advance `n`).
    - `buffer_new/0` / `buffer_add/2` / `buffer_flush/2` — pure ambient
      coalescing buffer: M `buffer_add`s → one `buffer_flush` → one
      `append_ambient_turn/2` commit.
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
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Crypto.NodeIdentity
  alias Commonplace.Tree.DocBuilder

  defmodule AmbientBuffer do
    @moduledoc """
    A pure (timer-free) coalescing buffer for ambient lines. Callers
    accumulate lines with `add/2` (no commit) and materialize them into a
    single `Commonplace.MUD.SessionView.append_ambient_turn/2` commit via
    `Commonplace.MUD.SessionView.buffer_flush/2`. The SHAPE invariant: M
    added lines → ONE flush → ONE commit; NO per-line commit.
    """
    defstruct lines: []

    @type t :: %__MODULE__{lines: [String.t()]}

    @doc "An empty buffer."
    @spec new() :: t()
    def new, do: %__MODULE__{}

    @doc "Append `line` to the buffer (order-preserving). No commit."
    @spec add(t(), String.t()) :: t()
    def add(%__MODULE__{lines: lines} = buffer, line) when is_binary(line),
      do: %{buffer | lines: lines ++ [line]}
  end

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
  `Commonplace.Store.CommitStoreClient.create_commit/6`.

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

    # Route the genesis through CommitStoreClient (like the appends and the
    # rest of the codebase) so callers pass the SAME store handle for both —
    # notably CommitStoreClient itself, which a raw CommitStore.create_commit
    # would choke on (GenServer.call to the unregistered client module). Local
    # mode normalizes back to CommitStore; remote mode routes to the serve.
    commit = CommitStoreClient.create_commit(store, uuid, update, nil, %{}, signing_context: node_ctx)
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

  @section_order [:name, :desc, :exits, :contents, :occupants]

  @doc """
  REPLACE the entire `<room>` subtree's children with a fresh set of
  section elements — `<name>..</name><desc>..</desc><exits>..</exits><contents>..</contents><occupants>..</occupants>` —
  in ONE delta commit.

  `sections` is a map whose keys are drawn from
  `#{inspect(@section_order)}`. Values may be:

    * a **string** (`:name`/`:desc`, or any flat section) → a single text
      child, e.g. `<name>The Orrery Hall</name>`;
    * a **list** for the structured sections (design §1's nested schema):
      `:exits` = `[{dir, to_label}]` → `<exit dir=".." to=".."/>` children;
      `:contents` = `[item_name]` → `<item>..</item>` children;
      `:occupants` = `[who_name]` → `<who>..</who>` children.

  Any missing key is treated as an empty string. The current `<room>`
  children (if any) are tombstoned wholesale via
  `Yelixer.Types.XMLElement.delete_child/4` and the five section
  containers are re-inserted in `@section_order`.

  This module stores the text VERBATIM — HTML-escaping of the
  player-supplied `<item>`/`<who>`/`<name>`/`<desc>`/`<exit @to>` fields is
  the RENDER layer's job (`CommonplaceWebWeb.MudLive` walks these
  structurally and hands each field to `~H`, which auto-escapes), never a
  raw `to_html`.

  This is a REPLACE-subtree region, NOT a scrollback turn, so it does
  NOT advance the turn counter `n` (see `commit_delta_no_turn!/3`).

  Because `<room>` is an independent CRDT subtree (invariant 2), the
  committed delta touches ONLY `<room>`-parented ops: its size is a
  function of the section text, NOT of how long `<scrollback>` has
  grown. A room-replace therefore stays flat regardless of transcript
  length — the load-bearing region-isolation property. Chained +
  node-signed (invariant 3). Returns the updated `%SessionView{}`.
  """
  @spec replace_room(t(), map()) :: t()
  def replace_room(%__MODULE__{} = view, sections) when is_map(sections) do
    sv_before = BlockStore.state_vector(view.doc.store)

    doc = view.doc
    child_count = XMLElement.child_count(doc, view.room_name)

    # Clear the whole subtree. `delete_child/4` requires length > 0, so
    # guard the empty-room (fresh view) case.
    doc =
      if child_count > 0 do
        XMLElement.delete_child(doc, view.room_name, 0, child_count)
      else
        doc
      end

    doc =
      @section_order
      |> Enum.with_index()
      |> Enum.reduce(doc, fn {key, index}, doc ->
        build_section(doc, view.room_name, index, key, Map.get(sections, key, ""))
      end)

    commit_delta_no_turn!(view, doc, sv_before)
  end

  @doc """
  A new, empty ambient coalescing buffer.

  The buffer is a PURE MODEL abstraction (no timer): callers accumulate
  ambient lines with `buffer_add/2` and materialize them into exactly
  ONE `append_ambient_turn/2` commit via `buffer_flush/2`. The
  timer/when-to-flush policy is a later increment's concern — this is
  only the M-events → 1-commit coalescing shape.
  """
  @spec buffer_new() :: AmbientBuffer.t()
  def buffer_new, do: AmbientBuffer.new()

  @doc """
  Accumulate one ambient `line` into `buffer`. Does NOT commit — returns
  the updated buffer only.
  """
  @spec buffer_add(AmbientBuffer.t(), String.t()) :: AmbientBuffer.t()
  def buffer_add(%AmbientBuffer{} = buffer, line) when is_binary(line),
    do: AmbientBuffer.add(buffer, line)

  @doc """
  Flush `buffer` into `view`. If the buffer holds M ≥ 1 lines, appends
  them as ONE `append_ambient_turn/2` (a single commit carrying all M
  `<line>` children in order) and returns `{updated_view,
  empty_buffer}`. If the buffer is empty, commits NOTHING and returns
  `{view, buffer}` unchanged.
  """
  @spec buffer_flush(t(), AmbientBuffer.t()) :: {t(), AmbientBuffer.t()}
  def buffer_flush(%__MODULE__{} = view, %AmbientBuffer{lines: []} = buffer),
    do: {view, buffer}

  def buffer_flush(%__MODULE__{} = view, %AmbientBuffer{lines: lines}) do
    {append_ambient_turn(view, lines), AmbientBuffer.new()}
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

  # Insert an empty `<tag>` element as child `index` of `parent_name`.
  # Returns `{doc, element_type_name}`.
  defp insert_container(doc, parent_name, index, tag) do
    doc = XMLElement.insert_child(doc, parent_name, index, {:element, tag})
    {:element, ^tag, elem_name} = Enum.at(XMLElement.children(doc, parent_name), index)
    {doc, elem_name}
  end

  # Insert `<tag>text</tag>` as child `index` of `parent_name`. Returns
  # `{doc, element_type_name}`. An empty `text` yields a bare
  # `<tag></tag>` (no text child): `Yelixer.Types.XMLText.insert/4`
  # rejects zero-length inserts, and a `replace_room/2` section can
  # legitimately be an empty string (missing key).
  defp insert_text_element(doc, parent_name, index, tag, text) do
    {doc, elem_name} = insert_container(doc, parent_name, index, tag)

    doc =
      if text == "" do
        doc
      else
        doc = XMLElement.insert_child(doc, elem_name, 0, :text)
        [{:text, text_name}] = XMLElement.children(doc, elem_name)
        XMLText.insert(doc, text_name, 0, text)
      end

    {doc, elem_name}
  end

  # Build one `<room>` section container at `index` (design §1). List-valued
  # structured sections nest their children; a binary value (name/desc, or a
  # back-compat flat string) becomes a single text child.
  defp build_section(doc, room_name, index, :exits, exits) when is_list(exits) do
    {doc, exits_name} = insert_container(doc, room_name, index, "exits")

    exits
    |> Enum.with_index()
    |> Enum.reduce(doc, fn {{dir, to}, i}, doc ->
      doc = XMLElement.insert_child(doc, exits_name, i, {:element, "exit"})
      {:element, "exit", exit_name} = Enum.at(XMLElement.children(doc, exits_name), i)

      doc
      |> XMLElement.set_attribute(exit_name, "dir", to_string(dir))
      |> XMLElement.set_attribute(exit_name, "to", to_string(to))
    end)
  end

  defp build_section(doc, room_name, index, :contents, items) when is_list(items),
    do: build_text_list(doc, room_name, index, "contents", "item", items)

  defp build_section(doc, room_name, index, :occupants, whos) when is_list(whos),
    do: build_text_list(doc, room_name, index, "occupants", "who", whos)

  defp build_section(doc, room_name, index, key, value) do
    {doc, _} = insert_text_element(doc, room_name, index, Atom.to_string(key), to_string(value))
    doc
  end

  # A container `<container_tag>` holding one `<item_tag>text</item_tag>` per
  # element of `items`, in order.
  defp build_text_list(doc, room_name, index, container_tag, item_tag, items) do
    {doc, container_name} = insert_container(doc, room_name, index, container_tag)

    items
    |> Enum.with_index()
    |> Enum.reduce(doc, fn {text, i}, doc ->
      {doc, _} = insert_text_element(doc, container_name, i, item_tag, to_string(text))
      doc
    end)
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

  # Delta-commit a scrollback turn: advances the turn counter `n`.
  defp commit_delta!(%__MODULE__{} = view, doc, sv_before) do
    commit_and_refresh!(view, doc, sv_before, view.n + 1)
  end

  # Delta-commit a NON-turn mutation (e.g. a `<room>` replace): commits
  # the delta + refreshes `doc`/`sv` but does NOT advance the turn
  # counter `n`. A room-replace is not a scrollback turn, so it must not
  # renumber future turns.
  defp commit_delta_no_turn!(%__MODULE__{} = view, doc, sv_before) do
    commit_and_refresh!(view, doc, sv_before, view.n)
  end

  defp commit_and_refresh!(%__MODULE__{} = view, doc, sv_before, new_n) do
    delta = Encoding.encode_diff(doc, sv_before)
    node_ctx = signing_context!([])

    commit =
      CommitStoreClient.create_chained_commit(view.store, view.uuid, delta, %{},
        signing_context: node_ctx
      )

    ensure_committed!(commit, :append)

    %{view | doc: doc, n: new_n, sv: BlockStore.state_vector(doc.store)}
  end

  defp ensure_committed!(commit, stage) do
    if match?({:error, _}, commit) do
      raise "Commonplace.MUD.SessionView #{stage} commit failed: #{inspect(commit)}"
    else
      :ok
    end
  end
end
