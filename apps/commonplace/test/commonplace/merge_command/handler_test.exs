defmodule Commonplace.MergeCommand.HandlerTest do
  @moduledoc """
  CX-8qzi: magenta merge command handler.

  Singleton GenServer that subscribes to magenta commands with verb
  "merge" (via `Magenta.subscribe_to_verb/1` — sentinel dispatch so
  Phoenix.PubSub's lack of wildcard subscribe doesn't force a per-path
  subscriber tree). When a command arrives:

  - Topic: `magenta:commands/{path}/merge`
  - Incoming type: `"merge"` (request)
  - Payload: `%{"l_id" => <hex>, "other_ref" => <hex>, "strategy" => "translate"|"merge_snapshot"}`
  - Dispatches to `MergePolicy.merge/4`
  - Publishes literal `"merge_completed"` or `"merge_failed"` magenta
    messages back on the same per-path topic so subscribers (callers,
    red-log onramps) see the outcome anchored at the path that was
    addressed.

  Per plan-bot msg 2307 (jes answer) + 2313/2315:
  - A = dynamic per-path topics (preserved at the topic address level)
  - B = literal magenta types (NOT generic Events.run envelope)
  - C = per-document red log at {path} (handled by onramp wiring, a
    follow-up layer on this handler)
  - Topology β: singleton handler + Magenta verb sentinel, no per-path
    supervision tree (no per-path state worth isolating)
  """
  use ExUnit.Case, async: false

  alias Commonplace.Dataflow.Magenta
  alias Commonplace.Store.{Commit, CommitStore}
  alias Yelixer.{Doc, Encoding}
  alias Yelixer.Types.Text

  setup do
    dir = Path.join(System.tmp_dir!(), "mcmd_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    name = :"mcmd_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: name})
    on_exit(fn -> File.rm_rf!(dir) end)

    handler_name = :"mcmd_handler_#{:rand.uniform(1_000_000)}"

    start_supervised!(
      {Commonplace.MergeCommand.Handler, store: name, name: handler_name}
    )

    %{store: name, handler: handler_name}
  end

  # Reuse MergePolicyTest fixture shape: snapshot C → L chained regular
  # → R sibling regular. L.namespace = {1,2}, R.namespace = {1,3}.
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

    {l_commit, r_commit}
  end

  describe "merge command → merge_completed" do
    test "publishes merge_completed on the same path topic after successful merge",
         %{store: store} do
      uuid = "mcmd-happy"
      {l, r} = build_l_r(store, uuid)

      path = "docs/#{uuid}"
      topic = "commands/#{path}/merge"

      Magenta.subscribe(topic)

      request =
        Magenta.message("merge", "test", %{
          "l_id" => l.id,
          "other_ref" => r.id,
          "strategy" => "translate"
        })

      Magenta.send(topic, request)

      assert_receive {:magenta, ^topic, %Magenta{type: "merge_completed"} = reply}, 2000
      assert is_binary(reply.payload["commit_id"])
      assert reply.payload["path"] == path
    end

    test "merge_completed payload contains the new commit id that is findable in the store",
         %{store: store} do
      uuid = "mcmd-commit-id"
      {l, r} = build_l_r(store, uuid)

      path = "a/#{uuid}"
      topic = "commands/#{path}/merge"

      Magenta.subscribe(topic)

      request =
        Magenta.message("merge", "test", %{
          "l_id" => l.id,
          "other_ref" => r.id,
          "strategy" => "translate"
        })

      Magenta.send(topic, request)

      assert_receive {:magenta, ^topic, %Magenta{type: "merge_completed"} = reply}, 2000

      commit_id = reply.payload["commit_id"]
      assert {:ok, stored} = CommitStore.get_commit(store, commit_id)
      assert stored.metadata[:kind] == :merge
    end
  end

  describe "merge command → merge_failed" do
    test "publishes merge_failed when l_id doesn't resolve to a commit", %{store: _store} do
      path = "bad/l"
      topic = "commands/#{path}/merge"

      Magenta.subscribe(topic)

      request =
        Magenta.message("merge", "test", %{
          "l_id" => String.duplicate("0", 64),
          "other_ref" => String.duplicate("f", 64),
          "strategy" => "translate"
        })

      Magenta.send(topic, request)

      assert_receive {:magenta, ^topic, %Magenta{type: "merge_failed"} = reply}, 2000
      assert reply.payload["path"] == path
      assert is_binary(reply.payload["reason"])
    end
  end

  describe "sentinel verb dispatch (β topology)" do
    test "handler receives commands on multiple per-path topics ending in /merge",
         %{store: store} do
      uuid_a = "mcmd-multi-a"
      uuid_b = "mcmd-multi-b"
      {l_a, r_a} = build_l_r(store, uuid_a)
      {l_b, r_b} = build_l_r(store, uuid_b)

      topic_a = "commands/path-a/#{uuid_a}/merge"
      topic_b = "commands/other/path-b/#{uuid_b}/merge"

      Magenta.subscribe(topic_a)
      Magenta.subscribe(topic_b)

      req_a =
        Magenta.message("merge", "test", %{
          "l_id" => l_a.id,
          "other_ref" => r_a.id,
          "strategy" => "translate"
        })

      req_b =
        Magenta.message("merge", "test", %{
          "l_id" => l_b.id,
          "other_ref" => r_b.id,
          "strategy" => "translate"
        })

      Magenta.send(topic_a, req_a)
      Magenta.send(topic_b, req_b)

      assert_receive {:magenta, ^topic_a, %Magenta{type: "merge_completed"}}, 2000
      assert_receive {:magenta, ^topic_b, %Magenta{type: "merge_completed"}}, 2000
    end

    test "handler ignores magenta messages of other types", %{store: _store} do
      path = "noise"
      topic = "commands/#{path}/merge"

      Magenta.subscribe(topic)

      unrelated =
        Magenta.message("some_other_verb", "test", %{"key" => "value"})

      Magenta.send(topic, unrelated)

      refute_receive {:magenta, _, %Magenta{type: "merge_completed"}}, 200
      refute_receive {:magenta, _, %Magenta{type: "merge_failed"}}, 200
    end
  end
end
