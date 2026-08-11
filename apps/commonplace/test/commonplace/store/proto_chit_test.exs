defmodule Commonplace.Store.ProtoChitTest do
  use ExUnit.Case, async: false

  alias Commonplace.Crypto.{Signing, SigningContext}
  alias Commonplace.Dataflow.RedLog
  alias Commonplace.Document.ContentType
  alias Commonplace.Store.{CommitStoreClient, CommitStore}
  alias Commonplace.Tree.Schema

  setup do
    base = Path.join(System.tmp_dir!(), "proto_chit_store_#{System.unique_integer([:positive])}")
    store_dir = Path.join(base, "store")
    repo = Path.join(base, "repo")
    state_dir = Path.join(base, "state")
    File.mkdir_p!(repo)

    n = System.unique_integer([:positive])
    store = :"proto_chit_store_#{n}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: store_dir,
       name: :"proto_chit_supervisor_#{n}",
       commit_store_name: store,
       trust_side_store_name: :"proto_chit_trust_#{n}",
       pending_imports_name: :"proto_chit_pending_#{n}"}
    )

    {public_key, private_key} = Signing.generate_keypair()
    identity = "proto-chit-principal-#{n}"

    signing_context = %SigningContext{
      identity_uuid: identity,
      private_key: private_key,
      public_key: public_key
    }

    old_trust = Application.get_env(:commonplace, :trust)
    old_gate = Application.get_env(:commonplace, :local_write_gate)

    Application.put_env(:commonplace, :trust, %{
      accept_unsigned: false,
      trusted_identities: %{identity => Signing.encode_key(public_key)}
    })

    Application.put_env(:commonplace, :local_write_gate, :enforce)

    on_exit(fn ->
      restore_env(:trust, old_trust)
      restore_env(:local_write_gate, old_gate)
      File.rm_rf!(base)
    end)

    %{repo: repo, state_dir: state_dir, store: store, signing_context: signing_context}
  end

  test "refuses emission when sync scope was not declared", context do
    %{signing_context: signing_context} = context

    assert {:error, {:sync_scope_undeclared, message}} =
             Commonplace.ProtoChit.emit("/not/a/repository", ["commit", "-m", "undeclared"],
               root_uuid: UUID.uuid4(),
               event_log_uuid: UUID.uuid4(),
               state_dir: "/not/a/state-dir",
               signing_context: signing_context,
               store: context.store
             )

    assert message =~ "PROTO_CHIT_SYNC_EXCLUDES"
    assert message =~ "--sync-exclude"
    assert message =~ "--declare-empty-sync-excludes"
  end

  test "cuts a real pin and lands the six-field event as the supplied principal", context do
    %{repo: repo, state_dir: state_dir, store: store, signing_context: signing_context} = context
    File.write!(Path.join(repo, "hello.txt"), "hello\n")
    init_git(repo)

    file_uuid = UUID.uuid4()
    file_doc = Yelixer.Doc.new() |> ContentType.create(:text, "hello.txt")
    file_doc = ContentType.insert_text(file_doc, 0, "hello\n")

    assert %Commonplace.Store.Commit{} =
             CommitStoreClient.create_chained_commit(
               store,
               file_uuid,
               Yelixer.Encoding.encode_update(file_doc),
               %{},
               signing_context: signing_context
             )

    root_uuid = UUID.uuid4()
    root_doc = Schema.new_schema() |> Schema.add_file("hello.txt", file_uuid)

    assert %Commonplace.Store.Commit{} =
             CommitStoreClient.create_chained_commit(
               store,
               root_uuid,
               Yelixer.Encoding.encode_update(root_doc),
               %{},
               signing_context: signing_context
             )

    event_log_uuid = UUID.uuid4()
    trace = Path.join(state_dir, "fired.ndjson")

    assert {:ok, %{event: event, event_ref: event_ref}} =
             Commonplace.ProtoChit.emit(repo, ["commit", "-m", "punctuate"],
               root_uuid: root_uuid,
               event_log_uuid: event_log_uuid,
               state_dir: state_dir,
               trace_file: trace,
               sync_excludes: [],
               signing_context: signing_context,
               store: store
             )

    assert Map.keys(event) |> Enum.sort() ==
             Enum.sort([
               "author-principal",
               "git-sha",
               "message",
               "predecessor-ref",
               "proto-pin",
               "verb"
             ])

    assert event["verb"] == "commit"
    assert event["author-principal"] == signing_context.identity_uuid
    assert event["message"] == "punctuate"
    assert event["proto-pin"]["format"] == "commonplace-reflog-path-pin/v1"

    assert event["proto-pin"]["entries"]["hello.txt"] == %{
             "doc" => file_uuid,
             "commit" => latest_hex(store, file_uuid)
           }

    assert event["predecessor-ref"] == %{"branch" => "main", "event-refs" => []}
    assert event["git-sha"] == nil
    assert Jason.decode!(File.read!(trace)) == event

    assert {:ok, landed} = CommitStore.latest_commit(store, event_log_uuid)
    assert Base.encode16(landed.id, case: :lower) == event_ref
    assert String.starts_with?(landed.signer_id, signing_context.identity_uuid <> "@")
    assert RedLog.load(event_log_uuid, store) |> RedLog.read() == [event]
  end

  defp init_git(repo) do
    assert {_, 0} = System.cmd("/usr/bin/git", ["init", "-b", "main"], cd: repo)
  end

  defp latest_hex(store, uuid) do
    {:ok, commit} = CommitStore.latest_commit(store, uuid)
    Base.encode16(commit.id, case: :lower)
  end

  defp restore_env(key, nil), do: Application.delete_env(:commonplace, key)
  defp restore_env(key, value), do: Application.put_env(:commonplace, key, value)
end
