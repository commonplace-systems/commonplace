defmodule Commonplace.Chat.ChatViewComputeSupervisorTest do
  @moduledoc """
  CX-7kl3 (sub-bead ii of CX-04d8 M3): tests for the chat-tier
  per-room ViewCompute supervisor. Mirrors `Chat.OnrampSupervisor`'s
  pattern: DynamicSupervisor + ETS room→pid index, lazy ensure_started,
  idempotent on concurrent first-call.

  Critical framing (refinement C): this is chat-OWNED lifecycle for
  chat-OWNED compute_fn — NOT substrate-tier ViewCompute productionization
  (CX-18s, jes-locked answer #2). Chat ships its own supervisor for the
  chat compute_fn the same way it ships its own onramp supervisor.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Chat.ChatViewComputeSupervisor
  alias Commonplace.Document.ContentType
  alias Commonplace.Store.{CommitStore, CommitStoreClient}
  alias Commonplace.Tree.DocBuilder

  setup do
    # Per-test scratch dir + CommitStore restart, mirrors
    # actions_resolve_args_test pattern. Ensures clean state for the
    # supervisor's lazy lifecycle assertions.
    prior_data_dir = Application.get_env(:commonplace, :data_dir)

    dir =
      Path.join(System.tmp_dir!(), "cp_chat_view_compute_sup_#{:rand.uniform(1_000_000_000)}")

    File.mkdir_p!(dir)
    Application.put_env(:commonplace, :data_dir, dir)

    sup = Commonplace.Store.CommitStoreSupervisor
    _ = Supervisor.terminate_child(sup, Commonplace.Store.CommitStore)
    _ = Supervisor.delete_child(sup, Commonplace.Store.CommitStore)

    {:ok, _pid} =
      Supervisor.start_child(sup, {Commonplace.Store.CommitStore, data_dir: dir})

    Commonplace.Tree.DocCache.clear()
    ChatViewComputeSupervisor.reset()

    on_exit(fn ->
      ChatViewComputeSupervisor.reset()
      _ = Supervisor.terminate_child(sup, Commonplace.Store.CommitStore)
      _ = Supervisor.delete_child(sup, Commonplace.Store.CommitStore)
      Application.put_env(:commonplace, :data_dir, prior_data_dir)

      _ =
        Supervisor.start_child(
          sup,
          {Commonplace.Store.CommitStore, data_dir: prior_data_dir}
        )

      Commonplace.Tree.DocCache.clear()
      File.rm_rf!(dir)
    end)

    :ok
  end

  defp mint_doc(uuid, doc) do
    update = Yelixer.Encoding.encode_update(doc)
    CommitStore.create_commit(Commonplace.Store.CommitStore, uuid, update, nil)
    uuid
  end

  defp mint_messages_doc do
    uuid = UUID.uuid4()
    mint_doc(uuid, Commonplace.Chat.Messages.new())
  end

  defp mint_view_doc do
    uuid = UUID.uuid4()

    doc = Yelixer.Doc.new()
    doc = ContentType.create(doc, :text, "_view.xml")
    mint_doc(uuid, doc)
  end

  defp read_view_content(uuid) do
    {:ok, doc} = DocBuilder.reconstruct_snapshot(CommitStoreClient, uuid)
    ContentType.get_content(doc) || ""
  end

  describe "ensure_started/3 — lazy lifecycle" do
    test "starts a ViewCompute child + tracks in ETS index" do
      messages_uuid = mint_messages_doc()
      view_uuid = mint_view_doc()

      assert {:ok, pid} =
               ChatViewComputeSupervisor.ensure_started("alpha", messages_uuid, view_uuid)

      assert is_pid(pid)
      assert Process.alive?(pid)

      assert :ets.lookup(:chat_view_compute_room_index, "alpha") == [{"alpha", pid}]
    end

    test "second call for same room returns same pid (idempotent)" do
      messages_uuid = mint_messages_doc()
      view_uuid = mint_view_doc()

      assert {:ok, pid1} =
               ChatViewComputeSupervisor.ensure_started("beta", messages_uuid, view_uuid)

      assert {:ok, pid2} =
               ChatViewComputeSupervisor.ensure_started("beta", messages_uuid, view_uuid)

      assert pid1 == pid2
    end

    test "different rooms get different ViewCompute children" do
      m1 = mint_messages_doc()
      v1 = mint_view_doc()
      m2 = mint_messages_doc()
      v2 = mint_view_doc()

      {:ok, pid1} = ChatViewComputeSupervisor.ensure_started("room1", m1, v1)
      {:ok, pid2} = ChatViewComputeSupervisor.ensure_started("room2", m2, v2)

      assert pid1 != pid2
      assert Process.alive?(pid1)
      assert Process.alive?(pid2)
    end
  end

  describe "compute loop — end-to-end (Anchor B)" do
    test "posting a message triggers recompute → _view.xml updates with rendered message" do
      messages_uuid = mint_messages_doc()
      view_uuid = mint_view_doc()

      {:ok, _pid} =
        ChatViewComputeSupervisor.ensure_started("hello", messages_uuid, view_uuid)

      # Initial compute on start should have produced an empty-list view.
      # Wait for it to land before posting.
      eventually(fn -> read_view_content(view_uuid) =~ ~s(name="hello") end)

      # Post a message via Chat.Actions — same path workspace claude uses.
      {:ok, %{message_id: m1}} =
        Commonplace.Chat.Actions.post_message(messages_uuid, "hi from anchor B",
          room: "hello",
          signer_id: "alice@aaaaaaaa",
          author_path: "alice.usr"
        )

      # ViewCompute subscribes to commits on messages_uuid; recompute
      # arrives async, give it a beat.
      eventually(fn -> read_view_content(view_uuid) =~ "hi from anchor B" end)

      content = read_view_content(view_uuid)
      assert content =~ ~s(id="#{m1}"),
             "rendered view-XML should carry the new message id"

      assert content =~ "alice.usr"
    end
  end

  describe "stop/1 + reset/0" do
    test "stop/1 terminates the ViewCompute child + clears index entry" do
      messages_uuid = mint_messages_doc()
      view_uuid = mint_view_doc()

      {:ok, pid} = ChatViewComputeSupervisor.ensure_started("z", messages_uuid, view_uuid)

      assert :ok = ChatViewComputeSupervisor.stop("z")
      refute Process.alive?(pid)
      assert :ets.lookup(:chat_view_compute_room_index, "z") == []
    end

    test "stop/1 is a no-op when no compute exists for the room" do
      assert :ok = ChatViewComputeSupervisor.stop("never-started")
    end
  end

  defp eventually(fun, attempts \\ 50) do
    Enum.reduce_while(1..attempts, false, fn _, _ ->
      if fun.() do
        {:halt, true}
      else
        Process.sleep(20)
        {:cont, false}
      end
    end)
    |> case do
      true -> :ok
      false -> flunk("eventually-condition never became true within #{attempts * 20}ms")
    end
  end
end
