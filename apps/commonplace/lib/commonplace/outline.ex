defmodule Commonplace.Outline do
  @moduledoc """
  Outline mutations on the flat bag of XML items (CX-saix, outliner.md).

  One `xml`-typed `_outline` doc holds flat `<item id parent order
  collapsed>` elements whose text is an `xml_text` child. The TREE is
  never stored — it is reconstructed from the `parent` + `order`
  attributes (`Commonplace.Outline.Tree`). Reparent is therefore a pure
  LWW attribute write on a never-destroyed element: concurrent moves
  cannot duplicate a subtree, and concurrent text edits char-merge.

  All mutations go through the STRUCTURED XML API and commit as CRDT
  updates via `CommitStoreClient.create_chained_commit` (chat's
  `commit_entry` idiom) — never through `CommandRouter` string
  smart-merge, which would destroy the character-CRDT identity the
  model depends on (outliner.md §2).

  Every mutation accepts `opts[:signing_context]` — an agent
  restructuring an outline over MCP signs its mutations with its own
  per-agent key (CX-88mw), gated by Gate A `:write` like any commit.
  """

  alias Commonplace.Document.ContentType
  alias Commonplace.Outline.Order
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.{DocBuilder, Schema}
  alias Commonplace.WriterHand

  @outline_dir "outline"
  @outline_doc "_outline"

  # --- creation ---

  @doc """
  Create `/outline/{name}/_outline` under the workspace root schema.
  Returns `{:ok, outline_doc_uuid}` (idempotent for an existing name).
  """
  def create(name, root_uuid, store \\ CommitStoreClient, opts \\ []) do
    {:ok, dir_uuid} = ensure_dir(root_uuid, @outline_dir, store, opts)
    {:ok, room_uuid} = ensure_dir(dir_uuid, name, store, opts)

    room_doc = load_schema(room_uuid, store)

    case Schema.get_entry(room_doc, @outline_doc) do
      {:ok, entry} ->
        {:ok, entry.node_id}

      :error ->
        uuid = UUID.uuid4()
        doc = ContentType.create(Yelixer.Doc.new(), :xml, @outline_doc)
        CommitStoreClient.create_commit(store, uuid, Yelixer.Encoding.encode_update(doc), nil)

        view_uuid = UUID.uuid4()
        view_doc = ContentType.create(Yelixer.Doc.new(), :text, "_view.xml")
        view_doc = ContentType.insert_text(view_doc, 0, view_xml_template(name))
        CommitStoreClient.create_commit(store, view_uuid, Yelixer.Encoding.encode_update(view_doc), nil)

        room_doc = Schema.add_file(room_doc, @outline_doc, uuid)
        room_doc = Schema.add_file(room_doc, "_view.xml", view_uuid)
        commit_schema(store, room_uuid, room_doc, opts)
        {:ok, uuid}
    end
  end

  @doc "Read the outline room's `_view.xml` (the action-discovery surface)."
  def view_xml(name, root, store \\ CommitStoreClient) do
    with {:ok, dir_entry} <- Schema.get_entry(load_schema(root, store), @outline_dir),
         {:ok, room_entry} <- Schema.get_entry(load_schema(dir_entry.node_id, store), name),
         {:ok, view_entry} <- Schema.get_entry(load_schema(room_entry.node_id, store), "_view.xml"),
         {:ok, doc} <- DocBuilder.reconstruct_doc(store, view_entry.node_id) do
      {:ok, ContentType.get_content(doc) || ""}
    else
      _ -> {:error, :not_found}
    end
  end

  # The declared action surface (CX-2qjd): agents discover these over
  # MCP; ArgResolver resolves <arg from="../_outline"> to the doc uuid.
  # Same vocabulary as chat's render_actions.
  defp view_xml_template(name) do
    """
    <view title="outline: #{name}">
      <action name="add_item" label="Add item" args="text:string,parent:string,after:string">
        <arg name="outline_uuid" from="../_outline"/>
      </action>
      <action name="set_text" label="Edit text" args="id:string,text:string">
        <arg name="outline_uuid" from="../_outline"/>
      </action>
      <action name="indent_item" label="Indent" args="id:string">
        <arg name="outline_uuid" from="../_outline"/>
      </action>
      <action name="outdent_item" label="Outdent" args="id:string">
        <arg name="outline_uuid" from="../_outline"/>
      </action>
      <action name="reorder_item" label="Move" args="id:string,direction:string">
        <arg name="outline_uuid" from="../_outline"/>
      </action>
      <action name="toggle_collapse" label="Collapse/expand" args="id:string">
        <arg name="outline_uuid" from="../_outline"/>
      </action>
      <action name="delete_item" label="Delete" args="id:string">
        <arg name="outline_uuid" from="../_outline"/>
      </action>
    </view>
    """
  end

  @doc """
  Resolve `/outline/{name}/_outline` to its doc uuid by walking the
  workspace schema (the same live binding chat's room lookup uses).
  """
  def lookup(name, root_uuid, store \\ CommitStoreClient) do
    with {:ok, dir_entry} <- Schema.get_entry(load_schema(root_uuid, store), @outline_dir),
         {:ok, room_entry} <- Schema.get_entry(load_schema(dir_entry.node_id, store), name),
         {:ok, doc_entry} <- Schema.get_entry(load_schema(room_entry.node_id, store), @outline_doc) do
      {:ok, doc_entry.node_id}
    else
      :error -> {:error, :not_found}
    end
  end

  # --- mutations (store level: load → Internal op → commit) ---

  @doc """
  Add an item. `attrs`: `:text` (required), `:parent` (item id, default
  top-level), `:after` (sibling id to insert after; default last).
  Returns `{:ok, item_id}`.
  """
  def add_item(store, outline_uuid, attrs, opts \\ []) do
    text = Map.fetch!(attrs, :text)
    parent = Map.get(attrs, :parent, "")

    mutate(store, outline_uuid, opts, fn doc ->
      items = __MODULE__.Internal.materialize_items(doc)
      siblings = siblings_of(items, parent)

      order =
        case Map.get(attrs, :after) do
          nil ->
            Order.between(List.last(siblings) |> maybe(& &1.order), nil)

          after_id ->
            idx = Enum.find_index(siblings, &(&1.id == after_id)) ||
                    raise ArgumentError, "after: #{after_id} is not a sibling"

            left = Enum.at(siblings, idx)
            right = Enum.at(siblings, idx + 1)
            Order.between(left.order, maybe(right, & &1.order))
        end

      id = mint_id()
      {__MODULE__.Internal.insert_item(doc, id, parent, order, text), {:ok, id}}
    end)
  end

  @doc "Replace an item's text wholesale (granular edits go through Internal)."
  def set_text(store, outline_uuid, item_id, new_text, opts \\ []) do
    mutate(store, outline_uuid, opts, fn doc ->
      {__MODULE__.Internal.set_item_text(doc, item_id, new_text), :ok}
    end)
  end

  @doc "Reparent: a pure LWW attribute write; ordered last among new siblings."
  def reparent(store, outline_uuid, item_id, new_parent_id, opts \\ []) do
    mutate(store, outline_uuid, opts, fn doc ->
      items = __MODULE__.Internal.materialize_items(doc)
      last = siblings_of(items, new_parent_id) |> Enum.reject(&(&1.id == item_id)) |> List.last()
      order = Order.between(maybe(last, & &1.order), nil)

      doc = __MODULE__.Internal.set_item_attribute(doc, item_id, "parent", new_parent_id)
      {__MODULE__.Internal.set_item_attribute(doc, item_id, "order", order), :ok}
    end)
  end

  @doc "Indent: parent becomes the preceding sibling (outliner.md §3)."
  def indent(store, outline_uuid, item_id, opts \\ []) do
    with_item(store, outline_uuid, item_id, fn items, item ->
      siblings = siblings_of(items, item.parent)

      case Enum.find_index(siblings, &(&1.id == item_id)) do
        0 -> {:error, :no_preceding_sibling}
        idx -> {:reparent, Enum.at(siblings, idx - 1).id}
      end
    end, opts)
  end

  @doc "Outdent: parent becomes the grandparent, ordered just after the old parent."
  def outdent(store, outline_uuid, item_id, opts \\ []) do
    mutate(store, outline_uuid, opts, fn doc ->
      items = __MODULE__.Internal.materialize_items(doc)
      item = Enum.find(items, &(&1.id == item_id)) || raise ArgumentError, "no item #{item_id}"

      if item.parent == "" do
        {doc, {:error, :at_top_level}}
      else
        parent = Enum.find(items, &(&1.id == item.parent))
        grandparent_id = if parent, do: parent.parent, else: ""

        {left, right} =
          case parent do
            nil ->
              {nil, nil}

            parent ->
              sibs = siblings_of(items, grandparent_id)
              idx = Enum.find_index(sibs, &(&1.id == parent.id))
              {parent, idx && Enum.at(sibs, idx + 1)}
          end

        order = Order.between(maybe(left, & &1.order), maybe(right, & &1.order))
        doc = __MODULE__.Internal.set_item_attribute(doc, item_id, "parent", grandparent_id)
        {__MODULE__.Internal.set_item_attribute(doc, item_id, "order", order), :ok}
      end
    end)
  end

  @doc "Move an item one position up/down among its siblings."
  def reorder(store, outline_uuid, item_id, direction, opts \\ [])
      when direction in [:up, :down] do
    mutate(store, outline_uuid, opts, fn doc ->
      items = __MODULE__.Internal.materialize_items(doc)
      item = Enum.find(items, &(&1.id == item_id)) || raise ArgumentError, "no item #{item_id}"
      siblings = siblings_of(items, item.parent)
      idx = Enum.find_index(siblings, &(&1.id == item_id))

      target =
        case direction do
          :up when idx > 0 ->
            left = if idx >= 2, do: Enum.at(siblings, idx - 2)
            {maybe(left, & &1.order), Enum.at(siblings, idx - 1).order}

          :down when idx < length(siblings) - 1 ->
            right = Enum.at(siblings, idx + 2)
            {Enum.at(siblings, idx + 1).order, maybe(right, & &1.order)}

          _ ->
            nil
        end

      case target do
        nil ->
          {doc, {:error, :at_edge}}

        {l, r} ->
          {__MODULE__.Internal.set_item_attribute(doc, item_id, "order", Order.between(l, r)), :ok}
      end
    end)
  end

  @doc "Set the shared collapsed flag (MVP — per-viewer collapse is a follow-up)."
  def set_collapsed(store, outline_uuid, item_id, collapsed, opts \\ [])
      when is_boolean(collapsed) do
    mutate(store, outline_uuid, opts, fn doc ->
      {__MODULE__.Internal.set_item_attribute(doc, item_id, "collapsed", to_string(collapsed)), :ok}
    end)
  end

  @doc "Delete an item from the bag (its children orphan → display re-roots them)."
  def delete_item(store, outline_uuid, item_id, opts \\ []) do
    mutate(store, outline_uuid, opts, fn doc ->
      {__MODULE__.Internal.delete_item_by_id(doc, item_id), :ok}
    end)
  end

  @doc "Materialized items: `[%{id, parent, order, collapsed, text}]` (unsorted bag)."
  def items(store, outline_uuid) do
    {:ok, doc} = DocBuilder.reconstruct_doc(store, outline_uuid)
    __MODULE__.Internal.materialize_items(doc)
  end

  # --- shared plumbing ---

  # CX-41qg.3: stable per-doc hand (WriterHand.for_doc/1) — every
  # outline mutation reconstructs the FULL chain via
  # `DocBuilder.reconstruct_doc/3` and re-encodes a new commit, so
  # without a fixed client_id each call minted a fresh random one and
  # the outline doc's state vector grew one slot per edit forever.
  #
  # CX-nn4y (W4 rider): a caller that already carries its OWN stable
  # hand — a logged-in browser session, resolved once at login and
  # threaded down as `opts[:client_id]` — uses that hand instead of the
  # shared per-doc funnel hand. Two concurrent anonymous/funnel writers
  # sharing `for_doc/1` can mint colliding (client_id, clock) ops from
  # the same reconstructed base and the loser's write is silently
  # skipped as a duplicate on replay (the residual-collision hazard W4
  # session hands exist to close — see `WriterHand` moduledoc and
  # `Chat.Actions.load_messages_doc/3` for the same precedence order).
  # Hand-less callers (MCP, anonymous browser sessions) keep falling
  # through to `for_doc/1`.
  defp mutate(store, outline_uuid, opts, fun) do
    hand =
      case Keyword.get(opts, :client_id) do
        hand when is_integer(hand) -> hand
        nil -> WriterHand.for_doc(outline_uuid)
      end

    {:ok, doc} = DocBuilder.reconstruct_doc(store, outline_uuid, client_id: hand)
    {doc, result} = fun.(doc)

    case result do
      {:error, _} = err ->
        err

      ok ->
        commit_opts =
          case Keyword.get(opts, :signing_context) do
            nil -> []
            ctx -> [signing_context: ctx]
          end

        update = Yelixer.Encoding.encode_update(doc)

        # CX-qat5.3: propagate a local-write-gate rejection instead of
        # swallowing it — a denied commit means the mutation did NOT
        # persist, so callers (OutlineLive, MCP outline actions) must see
        # the error rather than a false `:ok`/`{:ok, id}`.
        case CommitStoreClient.create_chained_commit(store, outline_uuid, update, %{}, commit_opts) do
          {:error, _} = commit_err -> commit_err
          _commit -> ok
        end
    end
  end

  defp with_item(store, outline_uuid, item_id, decide, opts) do
    items = items(store, outline_uuid)
    item = Enum.find(items, &(&1.id == item_id)) || raise ArgumentError, "no item #{item_id}"

    case decide.(items, item) do
      {:error, _} = err -> err
      {:reparent, new_parent} -> reparent(store, outline_uuid, item_id, new_parent, opts)
    end
  end

  defp siblings_of(items, parent_id) do
    items
    |> Enum.filter(&(&1.parent == parent_id))
    |> Enum.sort(&(Order.compare({&1.order, &1.id}, {&2.order, &2.id}) != :gt))
  end

  defp maybe(nil, _fun), do: nil
  defp maybe(v, fun), do: fun.(v)

  defp mint_id, do: Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)

  defp load_schema(uuid, store) do
    case CommitStoreClient.latest_commit(store, uuid) do
      {:ok, commit} ->
        {:ok, doc} = Yelixer.Encoding.apply_update(Schema.new_schema(), commit.update)
        doc

      :none ->
        Schema.new_schema()
    end
  end

  defp commit_schema(store, uuid, doc, _opts) do
    CommitStoreClient.create_chained_commit(store, uuid, Yelixer.Encoding.encode_update(doc))
  end

  defp ensure_dir(parent_uuid, name, store, opts) do
    parent_doc = load_schema(parent_uuid, store)

    case Schema.get_entry(parent_doc, name) do
      {:ok, entry} ->
        {:ok, entry.node_id}

      :error ->
        uuid = UUID.uuid4()
        dir_doc = Schema.new_schema()
        CommitStoreClient.create_commit(store, uuid, Yelixer.Encoding.encode_update(dir_doc), nil)

        parent_doc = Schema.add_directory(parent_doc, name, uuid)
        commit_schema(store, parent_uuid, parent_doc, opts)
        {:ok, uuid}
    end
  end

  defmodule Internal do
    @moduledoc """
    Pure doc-level outline ops — the single mutation implementation the
    store-level API commits and the concurrency tests drive directly.
    """

    alias Yelixer.Types.XMLElement, as: El
    alias Yelixer.Types.XMLFragment, as: Frag
    alias Yelixer.Types.XMLText, as: Txt

    @content "content"

    @doc "Append a new `<item>` to the flat bag."
    def insert_item(doc, id, parent, order, text) do
      index = Frag.child_count(doc, @content)
      doc = Frag.insert_child(doc, @content, index, {:element, "item"})
      {:element, "item", name} = Frag.to_list(doc, @content) |> Enum.at(index)

      doc = El.set_attribute(doc, name, "id", id)
      doc = El.set_attribute(doc, name, "parent", parent)
      doc = El.set_attribute(doc, name, "order", order)

      doc = El.insert_child(doc, name, 0, :text)
      {:text, text_name} = El.children(doc, name) |> List.first()
      if text == "", do: doc, else: Txt.insert(doc, text_name, 0, text)
    end

    @doc "LWW attribute write on the item with the given id."
    def set_item_attribute(doc, id, key, value) do
      El.set_attribute(doc, item_name!(doc, id), key, value)
    end

    @doc "Replace the item's text wholesale."
    def set_item_text(doc, id, new_text) do
      text_name = text_name!(doc, id)
      current = Txt.to_string(doc, text_name)
      doc = if current == "", do: doc, else: Txt.delete(doc, text_name, 0, String.length(current))
      Txt.insert(doc, text_name, 0, new_text)
    end

    @doc "Append to the item's text (used by concurrency tests / granular edits)."
    def append_item_text(doc, id, suffix) do
      text_name = text_name!(doc, id)
      Txt.insert(doc, text_name, String.length(Txt.to_string(doc, text_name)), suffix)
    end

    @doc "Delete the item element (tombstoned in the CRDT)."
    def delete_item_by_id(doc, id) do
      index =
        Frag.to_list(doc, @content)
        |> Enum.find_index(fn
          {:element, "item", name} -> El.get_attribute(doc, name, "id") == id
          _ -> false
        end) || raise ArgumentError, "no item #{id}"

      Frag.delete_child(doc, @content, index)
    end

    @doc "Materialize the bag: `[%{id, parent, order, collapsed, text}]`."
    def materialize_items(doc) do
      Frag.to_list(doc, @content)
      |> Enum.flat_map(fn
        {:element, "item", name} ->
          text =
            El.children(doc, name)
            |> Enum.map(fn
              {:text, tn} -> Txt.to_string(doc, tn)
              _ -> ""
            end)
            |> Enum.join()

          [
            %{
              id: El.get_attribute(doc, name, "id"),
              parent: El.get_attribute(doc, name, "parent") || "",
              order: El.get_attribute(doc, name, "order"),
              collapsed: El.get_attribute(doc, name, "collapsed") == "true",
              text: text
            }
          ]

        _other ->
          []
      end)
    end

    defp item_name!(doc, id) do
      Frag.to_list(doc, @content)
      |> Enum.find_value(fn
        {:element, "item", name} -> if El.get_attribute(doc, name, "id") == id, do: name
        _ -> nil
      end) || raise ArgumentError, "no item #{id}"
    end

    defp text_name!(doc, id) do
      El.children(doc, item_name!(doc, id))
      |> Enum.find_value(fn
        {:text, tn} -> tn
        _ -> nil
      end) || raise ArgumentError, "item #{id} has no text node"
    end
  end
end
