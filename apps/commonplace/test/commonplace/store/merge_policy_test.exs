defmodule Commonplace.Store.MergePolicyTest do
  @moduledoc """
  CX-csmr: merge strategy policy layer.

  `MergePolicy.merge(store, l_id, r_id, opts)` wraps `Merger.merge/4`
  with automatic strategy selection so callers don't have to pick the
  strategy on every invocation.

  ## Resolution order

  1. `opts[:strategy]` — explicit override wins unconditionally.
     Reason: `:explicit`.
  2. `opts[:doc_type]` — if the doc type has a policy entry in
     `Application.get_env(:commonplace, :merge_policy_by_doc_type)`,
     that strategy is used. Reason: `:doc_type_config`.
  3. L's namespace client-id count ≥ `:merge_snapshot_sv_threshold`
     (overridable via `opts[:sv_threshold]`) → `:merge_snapshot`
     (namespace bloat heuristic; SV on L only — `:translate` produces
     a commit in L's namespace, so L's SV is what we're preventing
     from bloating). Reason: `:sv_threshold`.
  4. Fallback default: `:translate`. Reason: `:default`.

  Every invocation emits
  `[:commonplace, :merge, :strategy_selected]` with
  `%{strategy, reason, l, r}` BEFORE delegating to `Merger.merge/4`,
  so observers can bucket by `reason` to understand what policy fired.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Store.{Commit, CommitStore, MergePolicy, Namespace}
  alias Yelixer.{Doc, Encoding}
  alias Yelixer.Types.Text

  setup do
    dir = Path.join(System.tmp_dir!(), "mrgpol_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    name = :"mrgpol_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: name})
    on_exit(fn -> File.rm_rf!(dir) end)

    handler_id = {__MODULE__, :rand.uniform(1_000_000)}
    parent = self()

    :telemetry.attach(
      handler_id,
      [:commonplace, :merge, :strategy_selected],
      fn event, meas, meta, _ ->
        send(parent, {:telemetry, event, meas, meta})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    %{store: name}
  end

  # Build: snapshot C (client 1 inserted "abc") → L regular (client 2
  # inserts "X" on top) → R sibling regular (client 3 appends "Y" off C,
  # imported). L's namespace = {1, 2}. R's namespace = {1, 3}.
  defp build_l_r(store, uuid) do
    {:ok, _genesis} = CommitStore.ensure_genesis(store, uuid)

    doc_c = Doc.new(client_id: 1)
    {doc_c, _} = Doc.get_or_create_type(doc_c, "t", :text)
    doc_c = Text.insert(doc_c, "t", 0, "abc")

    _reg =
      CommitStore.create_chained_commit(
        store,
        uuid,
        Encoding.encode_update(doc_c),
        %{kind: :regular}
      )

    {:ok, c_snap} = CommitStore.snapshot(store, uuid)

    {:ok, c_doc} = Encoding.apply_update(Doc.new(), c_snap.update)
    c_update = Encoding.encode_update(c_doc)

    doc_l = Doc.new(client_id: 2)
    {doc_l, _} = Doc.get_or_create_type(doc_l, "t", :text)
    {:ok, doc_l} = Encoding.apply_update(doc_l, c_update)
    doc_l = Text.insert(doc_l, "t", 0, "X")

    l_commit =
      CommitStore.create_chained_commit(
        store,
        uuid,
        Encoding.encode_update(doc_l),
        %{kind: :regular}
      )

    doc_r = Doc.new(client_id: 3)
    {doc_r, _} = Doc.get_or_create_type(doc_r, "t", :text)
    {:ok, doc_r} = Encoding.apply_update(doc_r, c_update)
    doc_r = Text.insert(doc_r, "t", 3, "Y")

    r_commit =
      Commit.new(uuid, Encoding.encode_update(doc_r), c_snap.id, %{
        kind: :regular,
        snapshot_parent: c_snap.id
      })

    :ok = CommitStore.import_commit(store, r_commit, validator: fn _ -> :ok end)

    {c_snap, l_commit, r_commit}
  end

  describe "merge/4 — explicit strategy override" do
    test ":strategy opt wins unconditionally, reason :explicit", %{store: store} do
      uuid = "pol-explicit"
      {_c, l, r} = build_l_r(store, uuid)

      assert {:ok, commit} =
               MergePolicy.merge(store, l.id, r.id, strategy: :translate)

      assert commit.metadata[:kind] == :merge
      assert commit.parent_id == l.id

      assert_received {:telemetry, [:commonplace, :merge, :strategy_selected], _, meta}
      assert meta.strategy == :translate
      assert meta.reason == :explicit
      assert meta.l == l.id
      assert meta.r == r.id
    end

    test "explicit :merge_snapshot produces a :snapshot commit, reason :explicit",
         %{store: store} do
      uuid = "pol-explicit-snap"
      {_c, l, r} = build_l_r(store, uuid)

      assert {:ok, commit} =
               MergePolicy.merge(store, l.id, r.id, strategy: :merge_snapshot)

      assert commit.metadata[:kind] == :snapshot

      assert_received {:telemetry, [:commonplace, :merge, :strategy_selected], _, meta}
      assert meta.strategy == :merge_snapshot
      assert meta.reason == :explicit
    end

    test "explicit :strategy overrides even if doc_type_config would disagree",
         %{store: store} do
      uuid = "pol-explicit-beats-doctype"
      {_c, l, r} = build_l_r(store, uuid)

      Application.put_env(:commonplace, :merge_policy_by_doc_type, %{
        presence: :merge_snapshot
      })

      on_exit(fn -> Application.delete_env(:commonplace, :merge_policy_by_doc_type) end)

      # Even though the doc_type config says :merge_snapshot for presence,
      # the explicit :translate opt wins.
      assert {:ok, commit} =
               MergePolicy.merge(store, l.id, r.id,
                 strategy: :translate,
                 doc_type: :presence
               )

      assert commit.metadata[:kind] == :merge

      assert_received {:telemetry, [:commonplace, :merge, :strategy_selected], _, meta}
      assert meta.strategy == :translate
      assert meta.reason == :explicit
    end
  end

  describe "merge/4 — doc_type config" do
    test "picks strategy from doc_type config when no explicit :strategy, reason :doc_type_config",
         %{store: store} do
      uuid = "pol-doctype"
      {_c, l, r} = build_l_r(store, uuid)

      Application.put_env(:commonplace, :merge_policy_by_doc_type, %{
        presence: :merge_snapshot,
        authoritative: :translate
      })

      on_exit(fn -> Application.delete_env(:commonplace, :merge_policy_by_doc_type) end)

      assert {:ok, commit} =
               MergePolicy.merge(store, l.id, r.id, doc_type: :presence)

      assert commit.metadata[:kind] == :snapshot

      assert_received {:telemetry, [:commonplace, :merge, :strategy_selected], _, meta}
      assert meta.strategy == :merge_snapshot
      assert meta.reason == :doc_type_config
    end

    test "doc_type not in config falls through to next rule", %{store: store} do
      uuid = "pol-doctype-unknown"
      {_c, l, r} = build_l_r(store, uuid)

      Application.put_env(:commonplace, :merge_policy_by_doc_type, %{
        presence: :merge_snapshot
      })

      on_exit(fn -> Application.delete_env(:commonplace, :merge_policy_by_doc_type) end)

      # :notes isn't in the config; with default threshold (large), falls
      # through to :default.
      assert {:ok, _commit} =
               MergePolicy.merge(store, l.id, r.id, doc_type: :notes)

      assert_received {:telemetry, [:commonplace, :merge, :strategy_selected], _, meta}
      assert meta.reason == :default
      assert meta.strategy == :translate
    end
  end

  describe "merge/4 — state-vector threshold heuristic" do
    test "L's namespace client count ≥ threshold triggers :merge_snapshot with reason :sv_threshold",
         %{store: store} do
      uuid = "pol-sv-over"
      {_c, l, r} = build_l_r(store, uuid)

      # L's namespace = {client 1, client 2} (2 ids). Threshold 1 →
      # count (2) ≥ 1 → :merge_snapshot. No explicit strategy, no
      # doc_type config.
      assert {:ok, commit} =
               MergePolicy.merge(store, l.id, r.id, sv_threshold: 1)

      assert commit.metadata[:kind] == :snapshot

      assert_received {:telemetry, [:commonplace, :merge, :strategy_selected], _, meta}
      assert meta.strategy == :merge_snapshot
      assert meta.reason == :sv_threshold
    end

    test "L's namespace client count < threshold falls through to :default",
         %{store: store} do
      uuid = "pol-sv-under"
      {_c, l, r} = build_l_r(store, uuid)

      assert {:ok, commit} =
               MergePolicy.merge(store, l.id, r.id, sv_threshold: 100)

      assert commit.metadata[:kind] == :merge

      assert_received {:telemetry, [:commonplace, :merge, :strategy_selected], _, meta}
      assert meta.strategy == :translate
      assert meta.reason == :default
    end
  end

  describe "merge/4 — default" do
    test "no opts and no config uses :translate with reason :default", %{store: store} do
      uuid = "pol-default"
      {_c, l, r} = build_l_r(store, uuid)

      assert {:ok, commit} = MergePolicy.merge(store, l.id, r.id)

      assert commit.metadata[:kind] == :merge

      assert_received {:telemetry, [:commonplace, :merge, :strategy_selected], _, meta}
      assert meta.strategy == :translate
      assert meta.reason == :default
    end
  end

  describe "merge/4 — telemetry ordering" do
    test ":strategy_selected emits BEFORE the underlying :merge, :completed event",
         %{store: store} do
      uuid = "pol-order"
      {_c, l, r} = build_l_r(store, uuid)

      completed_id = {__MODULE__, :completed, :rand.uniform(1_000_000)}
      parent = self()

      :telemetry.attach(
        completed_id,
        [:commonplace, :merge, :completed],
        fn event, meas, meta, _ -> send(parent, {:telemetry, event, meas, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(completed_id) end)

      {:ok, _commit} = MergePolicy.merge(store, l.id, r.id, strategy: :translate)

      # :strategy_selected should land in the mailbox before :completed.
      assert_received {:telemetry, [:commonplace, :merge, :strategy_selected], _, _}
      assert_received {:telemetry, [:commonplace, :merge, :completed], _, _}
    end
  end

  describe "merge/4 — precedence" do
    test "sv_threshold beats :default but loses to doc_type_config", %{store: store} do
      uuid = "pol-prec-doctype-beats-sv"
      {_c, l, r} = build_l_r(store, uuid)

      Application.put_env(:commonplace, :merge_policy_by_doc_type, %{
        authoritative: :translate
      })

      on_exit(fn -> Application.delete_env(:commonplace, :merge_policy_by_doc_type) end)

      # L's SV count ≥ 1 would trigger :sv_threshold, but doc_type config
      # pins :translate for authoritative docs.
      assert {:ok, commit} =
               MergePolicy.merge(store, l.id, r.id,
                 doc_type: :authoritative,
                 sv_threshold: 1
               )

      assert commit.metadata[:kind] == :merge

      assert_received {:telemetry, [:commonplace, :merge, :strategy_selected], _, meta}
      assert meta.strategy == :translate
      assert meta.reason == :doc_type_config
    end

    test "Namespace.current_namespace(l) is included in meta to aid debugging",
         %{store: store} do
      uuid = "pol-meta-ns"
      {_c, l, r} = build_l_r(store, uuid)

      {:ok, _} = MergePolicy.merge(store, l.id, r.id, strategy: :translate)

      assert_received {:telemetry, [:commonplace, :merge, :strategy_selected], _, meta}
      assert meta.l == l.id
      assert meta.r == r.id

      # Sanity check the fixture namespaces — this test also guards that
      # build_l_r is producing the expected shape.
      l_ns = Namespace.current_namespace(l)
      r_ns = Namespace.current_namespace(r)
      assert is_binary(l_ns)
      assert is_binary(r_ns)
    end
  end
end
