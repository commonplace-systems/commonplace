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

  @eventually_poll_ms 20
  @eventually_attempts 1_000

  setup do
    # Per-test scratch dir + CommitStore restart. Restore to the
    # test-config default ("tmp/test_data") in on_exit — NOT a captured
    # prior_data_dir. Captured-prior is racy under parallel async:false
    # test execution (CI runs hotter than local): test A captures
    # prior=tmp/test_data + sets scratch1; test B's setup runs before
    # A's on_exit + captures prior=scratch1; B's on_exit then restores
    # to a deleted scratch dir, leaving production CommitStore dead for
    # subsequent tests. Restoring to the static config default avoids
    # the chain.
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
      Application.put_env(:commonplace, :data_dir, "tmp/test_data")

      {:ok, _pid} =
        Supervisor.start_child(
          sup,
          {Commonplace.Store.CommitStore, data_dir: "tmp/test_data"}
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

  # CX-9tj0 (M7 sub-bead iv): _compute body is Elixir source per the M7
  # ship; supervisor's :spec_uuid opt now feeds ViewCompute's :code_uuid
  # path which expects ComputeRunner.validate(compute/2 exported).
  @chat_compute_source ~S"""
  defmodule Commonplace.UserCode.Chat.Compute do
    alias Commonplace.Compute

    def compute(raw, ctx) do
      raw
      |> Compute.decode_json_array()
      |> Compute.materialize(chains: [
        {:edit_of, :latest_replaces},
        {:tombstone_of, :marks_deleted}
      ])
      |> Commonplace.Chat.ChatViewBuilder.build_view_xml(ctx.room_name)
    end
  end
  """

  defp mint_compute_spec do
    uuid = UUID.uuid4()
    doc = Yelixer.Doc.new()
    doc = ContentType.create(doc, :text, "_compute")
    doc = ContentType.insert_text(doc, 0, @chat_compute_source)
    mint_doc(uuid, doc)
  end

  defp ensure_started(room_name, messages_uuid, view_uuid) do
    spec_uuid = mint_compute_spec()

    ChatViewComputeSupervisor.ensure_started(room_name,
      source_uuid: messages_uuid,
      target_uuid: view_uuid,
      spec_uuid: spec_uuid
    )
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
               ensure_started("alpha", messages_uuid, view_uuid)

      assert is_pid(pid)
      assert Process.alive?(pid)

      assert :ets.lookup(:chat_view_compute_room_index, "alpha") == [{"alpha", pid}]
    end

    test "second call for same room returns same pid (idempotent)" do
      messages_uuid = mint_messages_doc()
      view_uuid = mint_view_doc()

      assert {:ok, pid1} =
               ensure_started("beta", messages_uuid, view_uuid)

      assert {:ok, pid2} =
               ensure_started("beta", messages_uuid, view_uuid)

      assert pid1 == pid2
    end

    test "different rooms get different ViewCompute children" do
      m1 = mint_messages_doc()
      v1 = mint_view_doc()
      m2 = mint_messages_doc()
      v2 = mint_view_doc()

      {:ok, pid1} = ensure_started("room1", m1, v1)
      {:ok, pid2} = ensure_started("room2", m2, v2)

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
        ensure_started("hello", messages_uuid, view_uuid)

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

      # CX-6kxv: ViewCompute's async compute is itself bounded at 10 s. Polling
      # every 20 ms preserves prompt readiness detection; 1,000 attempts give
      # source notification + read/compute/write twice that bound (20 s).
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

      {:ok, pid} = ensure_started("z", messages_uuid, view_uuid)

      assert :ok = ChatViewComputeSupervisor.stop("z")
      refute Process.alive?(pid)
      assert :ets.lookup(:chat_view_compute_room_index, "z") == []
    end

    test "stop/1 is a no-op when no compute exists for the room" do
      assert :ok = ChatViewComputeSupervisor.stop("never-started")
    end
  end

  defp eventually(fun, attempts \\ @eventually_attempts) do
    Enum.reduce_while(1..attempts, false, fn _, _ ->
      if fun.() do
        {:halt, true}
      else
        Process.sleep(@eventually_poll_ms)
        {:cont, false}
      end
    end)
    |> case do
      true ->
        :ok

      false ->
        flunk("eventually-condition never became true within #{attempts * @eventually_poll_ms}ms")
    end
  end
end
