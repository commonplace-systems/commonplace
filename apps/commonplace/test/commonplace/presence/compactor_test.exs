defmodule Commonplace.Presence.CompactorTest do
  @moduledoc """
  Tests for the snapshot-append compaction primitive (CX-u7p).
  Targets the bloated-presence pathology described in
  `docs/superpowers/specs/2026-04-16-presence-compaction-design.md`.
  """

  use ExUnit.Case

  alias Commonplace.Document.ContentType
  alias Commonplace.Presence.Compactor
  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.DocBuilder
  alias Yelixer.{BlockStore, Doc, Encoding}

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_compactor_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    name = :"compactor_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: name})
    on_exit(fn -> File.rm_rf!(dir) end)
    %{store: name}
  end

  describe "compact/2" do
    test "returns {:error, :no_doc} when the doc has no commits", %{store: store} do
      assert {:error, :no_doc} = Compactor.compact("nonexistent-uuid", store)
    end

    test "writes a snapshot commit chained to the previous head", %{store: store} do
      uuid = UUID.uuid4()

      {bloated_doc, _} = build_bloated_presence_chain(store, uuid, 20)

      pre_head = latest_id(store, uuid)
      assert {:ok, snap_commit} = Compactor.compact(uuid, store)

      assert snap_commit.parent_id == pre_head
      assert snap_commit.metadata.kind == :snapshot
      assert latest_id(store, uuid) == snap_commit.id

      # Observable content preserved
      assert {:ok, rebuilt} = DocBuilder.reconstruct_doc(store, uuid)
      assert ContentType.get_content(rebuilt) == ContentType.get_content(bloated_doc)
    end

    test "drops state-vector size to 1 after compaction", %{store: store} do
      uuid = UUID.uuid4()

      {_, pre_size} = build_bloated_presence_chain(store, uuid, 30)
      # Sanity check: the chain genuinely accumulated many client_ids
      assert pre_size >= 30

      {:ok, _snap} = Compactor.compact(uuid, store)

      assert Compactor.state_vector_size(uuid, store) == 1
    end

    test "compacted doc reads back identical observable content", %{store: store} do
      uuid = UUID.uuid4()

      {bloated_doc, _} = build_bloated_presence_chain(store, uuid, 50)
      content_before = ContentType.get_content(bloated_doc)

      {:ok, _} = Compactor.compact(uuid, store)

      {:ok, rebuilt} = DocBuilder.reconstruct_doc(store, uuid)
      assert ContentType.get_content(rebuilt) == content_before
    end

    test "double compaction is safe (idempotent observable result)", %{store: store} do
      uuid = UUID.uuid4()

      {bloated_doc, _} = build_bloated_presence_chain(store, uuid, 10)
      content_before = ContentType.get_content(bloated_doc)

      {:ok, snap1} = Compactor.compact(uuid, store)
      {:ok, snap2} = Compactor.compact(uuid, store)

      # Two snapshot commits exist; both chain backward.
      refute snap1.id == snap2.id
      assert snap2.parent_id == snap1.id

      {:ok, rebuilt} = DocBuilder.reconstruct_doc(store, uuid)
      assert ContentType.get_content(rebuilt) == content_before
      assert Compactor.state_vector_size(uuid, store) == 1
    end

    # This is deliberately a wall-clock ratio, not a behavioral assertion.
    # Keep it as a blocking benchmark under `mix test --include scale`; the
    # ordinary suite excludes `:scale` because CPU contention changes the
    # measurement without changing compaction correctness. All content,
    # chaining, and state-vector assertions above remain ordinary-suite pins.
    @tag :scale
    test "post-compaction apply_update is significantly faster", %{store: store} do
      uuid = UUID.uuid4()

      # Use a larger N so the apply work is actually measurable.
      build_bloated_presence_chain(store, uuid, 200)

      pre_time = time_full_replay(store, uuid)

      {:ok, _} = Compactor.compact(uuid, store)

      post_time = time_apply_latest_only(store, uuid)

      # The post-compaction snapshot is one self-contained update with
      # one client in its state vector. Even on a small N=200 sample
      # it should be at least an order of magnitude faster than the
      # full N-step replay. We assert a soft 10x rather than the design
      # doc's 100x, since CI machines vary; the qualitative win is what
      # matters.
      assert post_time * 10 < pre_time,
             "expected snapshot apply (#{post_time}us) to be ≥10x faster than full replay (#{pre_time}us)"
    end
  end

  describe "state_vector_size/2" do
    test "returns 0 for unknown uuid", %{store: store} do
      assert Compactor.state_vector_size("nonexistent", store) == 0
    end

    test "matches the post-rebuild state vector size", %{store: store} do
      uuid = UUID.uuid4()
      build_bloated_presence_chain(store, uuid, 15)

      assert Compactor.state_vector_size(uuid, store) >= 15
    end
  end

  # Build a presence-style document chain that mirrors the heartbeat
  # writer-bug pattern: each tick re-encodes from a fresh-client doc,
  # so the state vector accumulates one new client per round. Returns
  # `{materialized_doc, pre_compaction_state_vector_size}`.
  defp build_bloated_presence_chain(store, uuid, rounds) do
    seed =
      Doc.new(client_id: 1)
      |> ContentType.create(:map, "presence")
      |> ContentType.set_key("name", "claude-code-2ca")
      |> ContentType.set_key("type", "bot")
      |> ContentType.set_key("status", "running")
      |> ContentType.set_key("heartbeat", "round-1")

    initial_update = Encoding.encode_update(seed)
    CommitStore.create_commit(store, uuid, initial_update, nil)

    final_doc =
      Enum.reduce(2..(rounds + 1), seed, fn round, _acc ->
        # Reload the doc via the snapshot-style reader (Doc.new() +
        # apply_update), exactly as Presence.heartbeat/2 does today.
        {:ok, latest_commit} = CommitStore.latest_commit(store, uuid)
        # New random-ish client_id per round, simulating the writer bug.
        fresh = Doc.new(client_id: round)
        {:ok, fresh} = Encoding.apply_update(fresh, latest_commit.update)
        fresh = ContentType.set_key(fresh, "heartbeat", "round-#{round}")
        update = Encoding.encode_update(fresh)
        CommitStore.create_chained_commit(store, uuid, update)
        fresh
      end)

    sv_size = map_size(BlockStore.state_vector(final_doc.store).clocks)
    {final_doc, sv_size}
  end

  defp latest_id(store, uuid) do
    {:ok, commit} = CommitStore.latest_commit(store, uuid)
    commit.id
  end

  defp time_full_replay(store, uuid) do
    {us, _} = :timer.tc(fn -> DocBuilder.reconstruct_doc(store, uuid) end)
    us
  end

  defp time_apply_latest_only(store, uuid) do
    {:ok, commit} = CommitStore.latest_commit(store, uuid)

    {us, _} =
      :timer.tc(fn ->
        Encoding.apply_update(Doc.new(), commit.update)
      end)

    us
  end
end
