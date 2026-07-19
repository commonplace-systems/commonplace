defmodule Commonplace.Bots.Worker.Tools.PostMessageTest do
  use ExUnit.Case, async: false

  alias Commonplace.Bots.Entity
  alias Commonplace.Bots.Worker.Tools.PostMessage
  alias Commonplace.Chat.Messages
  alias Commonplace.Crypto.{Signing, SigningContext}
  alias Commonplace.Store.{CommitStore, CommitStoreClient}
  alias Commonplace.Tree.DocBuilder

  # PostMessage routes through Actions.post_message → CommitStoreClient →
  # the global CommitStore, so we swap the global store onto a fresh tmp
  # data_dir (same fixture shape as WorkerTest) and restore on exit.
  setup do
    dir = Path.join(System.tmp_dir!(), "cp_bots_postmsg_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    Application.put_env(:commonplace, :data_dir, dir)

    sup = Commonplace.Store.CommitStoreSupervisor
    _ = Supervisor.terminate_child(sup, CommitStore)
    _ = Supervisor.delete_child(sup, CommitStore)
    {:ok, _pid} = Supervisor.start_child(sup, {CommitStore, data_dir: dir})
    Commonplace.Tree.DocCache.clear()

    on_exit(fn ->
      _ = Supervisor.terminate_child(sup, CommitStore)
      _ = Supervisor.delete_child(sup, CommitStore)
      Application.put_env(:commonplace, :data_dir, "tmp/test_data")
      {:ok, _pid} = Supervisor.start_child(sup, {CommitStore, data_dir: "tmp/test_data"})
      Commonplace.Tree.DocCache.clear()
      File.rm_rf!(dir)
    end)

    :ok
  end

  defp mint_messages_doc do
    uuid = UUID.uuid4()
    update = Yelixer.Encoding.encode_update(Messages.new())
    CommitStore.create_commit(CommitStore, uuid, update, nil)
    uuid
  end

  defp fresh_signing_context do
    {pub, priv} = Signing.generate_keypair()
    %SigningContext{identity_uuid: UUID.uuid4(), private_key: priv, public_key: pub}
  end

  defp state(messages_uuid, extra) do
    Map.merge(
      %{
        entity: %Entity{name: "alice"},
        room: "demo",
        opts: [messages_uuid: messages_uuid]
      },
      extra
    )
  end

  test "signs the post with the bot's own key; signer_id derives from the sc, not \"bot:name\"" do
    messages_uuid = mint_messages_doc()
    sc = fresh_signing_context()

    assert {:ok, _json} =
             PostMessage.call(state(messages_uuid, %{signing_context: sc}), %{
               "text" => "hello from alice"
             })

    expected_signer = Signing.signer_id(sc.identity_uuid, sc.public_key)

    {:ok, doc} = DocBuilder.reconstruct_snapshot(CommitStoreClient, messages_uuid)
    [entry] = Messages.list(doc)

    assert entry["text"] == "hello from alice"
    assert entry["author_path"] == "alice.bot"
    # The entry's author_signer_id is the REAL derived signer, never the
    # retired "bot:alice" placeholder.
    assert entry["author_signer_id"] == expected_signer
    refute String.starts_with?(entry["author_signer_id"], "bot:")

    # And the underlying commit is genuinely signed by that key.
    {:ok, head} = CommitStore.latest_commit(CommitStore, messages_uuid)
    assert Signing.signed?(head)
    assert head.signer_id == expected_signer
  end

  test "with no signing_context the post does NOT land (honest failure, no placeholder signer)" do
    messages_uuid = mint_messages_doc()

    # No signing_context in state → neither signer_id nor signing_context
    # is passed → Actions.post_message rejects the write. The stub signer
    # is gone, so an unsigned bot cannot fabricate an identity.
    assert {:error, _reason} =
             PostMessage.call(state(messages_uuid, %{signing_context: nil}), %{"text" => "ghost"})

    {:ok, doc} = DocBuilder.reconstruct_snapshot(CommitStoreClient, messages_uuid)
    assert Messages.list(doc) == []
  end
end
