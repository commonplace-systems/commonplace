defmodule Commonplace.Store.ProtoChitChainTest do
  @moduledoc """
  A2 read surface: `ProtoChit.chain/2` walks the punctuation chain
  newest-first, pairs each event with its enclosing commit's ref and
  signer rendering, folds post-exec annotations under their main events,
  and REFUSES a log whose commit/event counts disagree rather than
  misattributing refs.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Crypto.{Signing, SigningContext}
  alias Commonplace.Dataflow.RedLog
  alias Commonplace.ProtoChit
  alias Commonplace.Store.CommitStoreClient

  setup do
    base = Path.join(System.tmp_dir!(), "proto_chit_chain_#{System.unique_integer([:positive])}")
    store_dir = Path.join(base, "store")

    n = System.unique_integer([:positive])
    store = :"proto_chit_chain_store_#{n}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: store_dir,
       name: :"proto_chit_chain_supervisor_#{n}",
       commit_store_name: store,
       trust_side_store_name: :"proto_chit_chain_trust_#{n}",
       pending_imports_name: :"proto_chit_chain_pending_#{n}"}
    )

    {public_key, private_key} = Signing.generate_keypair()
    identity = "proto-chit-chain-principal-#{n}"

    signing_context = %SigningContext{
      identity_uuid: identity,
      private_key: private_key,
      public_key: public_key
    }

    on_exit(fn -> File.rm_rf!(base) end)

    %{store: store, signing_context: signing_context, identity: identity}
  end

  defp append_event(log_uuid, store, signing_context, event) do
    log = log_uuid |> RedLog.load(store) |> RedLog.append_raw(event)

    {:ok, _log} =
      RedLog.commit(log,
        signing_context: signing_context,
        metadata: %{kind: :regular, proto_chit: true}
      )

    {:ok, commit} = CommitStoreClient.latest_commit(store, log_uuid)
    Base.encode16(commit.id, case: :lower)
  end

  defp main_event(message) do
    %{
      "verb" => "commit",
      "author-principal" => "principal-under-test",
      "message" => message,
      "proto-pin" => nil,
      "predecessor-ref" => %{"branch" => "main", "event-refs" => [], "unresolved" => []},
      "git-sha" => nil
    }
  end

  test "chain returns main events newest-first with refs captured at write time", ctx do
    log_uuid = UUID.uuid4()

    ref_first = append_event(log_uuid, ctx.store, ctx.signing_context, main_event("first"))
    ref_second = append_event(log_uuid, ctx.store, ctx.signing_context, main_event("second"))

    assert {:ok, [newest, oldest]} = ProtoChit.chain(log_uuid, store: ctx.store)

    # Direction calibrated against a KNOWN ordering: "second" was appended
    # last, so it must render first.
    assert newest.event["message"] == "second"
    assert newest.event_ref == ref_second
    assert oldest.event["message"] == "first"
    assert oldest.event_ref == ref_first
  end

  test "post-exec annotations fold under their main event by main-event-ref", ctx do
    log_uuid = UUID.uuid4()

    main_ref = append_event(log_uuid, ctx.store, ctx.signing_context, main_event("landed"))

    _annotation_ref =
      append_event(log_uuid, ctx.store, ctx.signing_context, %{
        "kind" => "post-exec",
        "author-principal" => "principal-under-test",
        "main-event-ref" => main_ref,
        "resulting-git-sha" => nil,
        "exit-status" => 0,
        "message" => "landed"
      })

    assert {:ok, [entry]} = ProtoChit.chain(log_uuid, store: ctx.store)
    assert entry.event_ref == main_ref
    assert [annotation] = entry.annotations
    assert annotation.event["exit-status"] == 0
  end

  test "signer rendering is presence, and present for signed commits", ctx do
    log_uuid = UUID.uuid4()
    append_event(log_uuid, ctx.store, ctx.signing_context, main_event("signed one"))

    assert {:ok, [entry]} = ProtoChit.chain(log_uuid, store: ctx.store)
    assert entry.signer.signed == true
    assert is_binary(entry.signer.signer_id)
  end

  test "a commit/event count disagreement is refused, not misattributed", ctx do
    log_uuid = UUID.uuid4()

    # Two appends inside ONE commit break the one-event-per-commit write
    # discipline the pairing relies on: 2 events, 1 commit.
    log =
      log_uuid
      |> RedLog.load(ctx.store)
      |> RedLog.append_raw(main_event("a"))
      |> RedLog.append_raw(main_event("b"))

    {:ok, _} =
      RedLog.commit(log,
        signing_context: ctx.signing_context,
        metadata: %{kind: :regular, proto_chit: true}
      )

    assert {:error, {:log_shape_mismatch, %{events: 2, at: {:delta, _ref, 2}}}} =
             ProtoChit.chain(log_uuid, store: ctx.store)
  end

  test "empty log yields an empty chain", ctx do
    assert {:ok, []} = ProtoChit.chain(UUID.uuid4(), store: ctx.store)
  end
end
