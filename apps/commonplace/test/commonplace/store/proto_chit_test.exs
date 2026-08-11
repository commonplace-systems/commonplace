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
    refute Map.has_key?(event["proto-pin"], "exclusions")

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

  test "declares binary skips in the persisted event's pin", context do
    %{repo: repo, state_dir: state_dir, store: store, signing_context: signing_context} = context
    File.write!(Path.join(repo, "landed.txt"), "text\n")
    File.write!(Path.join(repo, "excluded.bin"), <<0xFF, 0x00>>)
    File.write!(Path.join(repo, "kept.txt"), <<0x80, 0x81>>)
    init_git(repo)

    kept_uuid = UUID.uuid4()
    kept_doc = Yelixer.Doc.new() |> ContentType.create(:text, "kept.txt")
    kept_doc = ContentType.insert_text(kept_doc, 0, "original")

    assert %Commonplace.Store.Commit{} =
             CommitStoreClient.create_chained_commit(
               store,
               kept_uuid,
               Yelixer.Encoding.encode_update(kept_doc),
               %{},
               signing_context: signing_context
             )

    {:ok, kept_before} = CommitStore.latest_commit(store, kept_uuid)
    root_uuid = UUID.uuid4()
    root_doc = Schema.new_schema() |> Schema.add_file("kept.txt", kept_uuid)

    assert %Commonplace.Store.Commit{} =
             CommitStoreClient.create_chained_commit(
               store,
               root_uuid,
               Yelixer.Encoding.encode_update(root_doc),
               %{},
               signing_context: signing_context
             )

    event_log_uuid = UUID.uuid4()

    assert {:ok, %{event: event}} =
             Commonplace.ProtoChit.emit(repo, ["commit", "-m", "binary floor"],
               root_uuid: root_uuid,
               event_log_uuid: event_log_uuid,
               state_dir: state_dir,
               sync_excludes: [],
               signing_context: signing_context,
               store: store
             )

    assert event["proto-pin"]["exclusions"] == [
             %{"path" => "excluded.bin", "reason" => "excluded-binary"},
             %{"path" => "kept.txt", "reason" => "excluded-binary"}
           ]

    assert Map.has_key?(event["proto-pin"]["entries"], "landed.txt")
    assert Map.has_key?(event["proto-pin"]["entries"], "kept.txt")
    refute Map.has_key?(event["proto-pin"]["entries"], "excluded.bin")

    assert {:ok, kept_after} = CommitStore.latest_commit(store, kept_uuid)
    assert kept_after.id == kept_before.id

    assert RedLog.load(event_log_uuid, store) |> RedLog.read() |> List.last() == event
  end

  test "post-exec annotation witnesses the resulting commit without advancing predecessor",
       context do
    %{repo: repo, state_dir: state_dir, store: store, signing_context: signing_context} = context
    configure_git(repo)
    File.write!(Path.join(repo, "hello.txt"), "parent\n")
    git!(repo, ["add", "hello.txt"])
    git!(repo, ["commit", "-m", "parent"])
    parent_sha = git!(repo, ["rev-parse", "HEAD"])

    File.write!(Path.join(repo, "hello.txt"), "child\n")
    git!(repo, ["add", "hello.txt"])

    root_uuid = UUID.uuid4()
    event_log_uuid = UUID.uuid4()

    assert {:ok, %{event: main_event, event_ref: main_ref}} =
             Commonplace.ProtoChit.emit(repo, ["commit", "-m", "witnessed child"],
               root_uuid: root_uuid,
               event_log_uuid: event_log_uuid,
               state_dir: state_dir,
               sync_excludes: [],
               signing_context: signing_context,
               store: store
             )

    assert main_event["git-sha"] == parent_sha
    assert RedLog.load(event_log_uuid, store) |> RedLog.read() == [main_event]
    predecessor_bytes = File.read!(Path.join(state_dir, "predecessors.json"))

    git!(repo, ["commit", "-m", "witnessed child"])
    resulting_sha = git!(repo, ["rev-parse", "HEAD"])

    assert {:ok, %{event: annotation}} =
             apply(Commonplace.ProtoChit, :annotate, [
               repo,
               main_ref,
               0,
               ["commit", "-m", "witnessed child"],
               [
                 event_log_uuid: event_log_uuid,
                 signing_context: signing_context,
                 store: store
               ]
             ])

    assert annotation == %{
             "kind" => "post-exec",
             "author-principal" => signing_context.identity_uuid,
             "main-event-ref" => main_ref,
             "resulting-git-sha" => resulting_sha,
             "exit-status" => 0,
             "message" => "witnessed child"
           }

    assert RedLog.load(event_log_uuid, store) |> RedLog.read() == [main_event, annotation]
    assert File.read!(Path.join(state_dir, "predecessors.json")) == predecessor_bytes

    checkpoint = main_event["proto-pin"]["checkpoint"]
    assert latest_hex(store, checkpoint["doc"]) == checkpoint["commit"]
    assert {:ok, annotation_commit} = CommitStore.latest_commit(store, event_log_uuid)
    assert String.starts_with?(annotation_commit.signer_id, signing_context.identity_uuid <> "@")
  end

  defp init_git(repo) do
    assert {_, 0} = System.cmd("/usr/bin/git", ["init", "-b", "main"], cd: repo)
  end

  defp configure_git(repo) do
    init_git(repo)
    git!(repo, ["config", "user.name", "Proto Chit Test"])
    git!(repo, ["config", "user.email", "proto@example.invalid"])
  end

  defp git!(repo, args) do
    {output, 0} = System.cmd("/usr/bin/git", args, cd: repo, stderr_to_stdout: true)
    String.trim(output)
  end

  defp latest_hex(store, uuid) do
    {:ok, commit} = CommitStore.latest_commit(store, uuid)
    Base.encode16(commit.id, case: :lower)
  end

  defp restore_env(key, nil), do: Application.delete_env(:commonplace, key)
  defp restore_env(key, value), do: Application.put_env(:commonplace, key, value)
end
