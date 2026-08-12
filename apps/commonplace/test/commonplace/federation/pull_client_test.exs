defmodule Commonplace.Federation.PullClientTest do
  @moduledoc """
  Phase C pull client (CX-orfw): CID-diff catch-up over an injected
  transport — `NodeSync.catch_up`'s shape with HTTP where RPC was.

  Two REAL stores in one node: `serving` plays the remote peer (its
  data served through a stub transport that mirrors the federation
  endpoints), `pulling` imports through its own UNCHANGED Gate A under
  strict trust. The stub transport is the test boundary — the real
  HTTP socket is proven by the controller tests + the phase-D demo.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Crypto.{Signing, SigningContext}
  alias Commonplace.Federation.{Envelope, PullClient}
  alias Commonplace.Store.{Commit, CommitStore}
  alias Commonplace.Dataflow.RedLog
  alias Commonplace.Tree.DocBuilder
  alias Commonplace.Trust.Capability

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_pull_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)

    # R4c carve-out: PullClient calls CommitStoreClient.store_capability/2
    # on the PULLING side when inlining a fetched envelope's cert chain,
    # and this test also calls CommitStore.store_capability/2 directly on
    # the SERVING side — both delegate to TrustSideStore, so both stores
    # need the full trio (a bare CommitStore has no companion by default).
    n = :rand.uniform(1_000_000)
    serving = :"pull_serving_#{n}"
    pulling = :"pull_pulling_#{n}"

    start_supervised!(
      Supervisor.child_spec(
        {Commonplace.Store.Supervisor,
         data_dir: Path.join(dir, "a"),
         name: :"pull_serving_sup_#{n}",
         commit_store_name: serving,
         trust_side_store_name: :"pull_serving_tss_#{n}",
         pending_imports_name: :"pull_serving_pi_#{n}"},
        id: :serving
      )
    )

    start_supervised!(
      Supervisor.child_spec(
        {Commonplace.Store.Supervisor,
         data_dir: Path.join(dir, "b"),
         name: :"pull_pulling_sup_#{n}",
         commit_store_name: pulling,
         trust_side_store_name: :"pull_pulling_tss_#{n}",
         pending_imports_name: :"pull_pulling_pi_#{n}"},
        id: :pulling
      )
    )

    # Strict trust on the PULLING side: only the root is pinned.
    {root_pub, root_priv} = Signing.generate_keypair()
    root_uuid = "root-" <> UUID.uuid4()

    Application.put_env(:commonplace, :trust, %{
      accept_unsigned: false,
      trusted_identities: %{root_uuid => Signing.encode_key(root_pub)}
    })

    on_exit(fn ->
      Application.delete_env(:commonplace, :trust)
      File.rm_rf!(dir)
    end)

    root_ctx = %SigningContext{
      identity_uuid: root_uuid,
      private_key: root_priv,
      public_key: root_pub
    }

    %{serving: serving, pulling: pulling, root: %{uuid: root_uuid, ctx: root_ctx, pub: root_pub}}
  end

  # Stub transport: implements the two pull endpoints against `serving`.
  defp stub_transport(serving) do
    fn
      :cids, _peer, doc_uuid ->
        cids =
          CommitStore.commit_ids_for_doc(serving, doc_uuid)
          |> Enum.map(&Base.encode64/1)

        {:ok, %{"cids" => cids}}

      :commits, _peer, {doc_uuid, b64_cids} ->
        envelopes =
          for b64 <- b64_cids,
              {:ok, id} = Base.decode64(b64),
              {:ok, commit} <- [CommitStore.get_commit(serving, id)],
              commit.doc_uuid == doc_uuid do
            Envelope.for_commit(serving, commit)
          end

        {:ok, %{"envelopes" => envelopes, "missing" => []}}
    end
  end

  defp seed_delegated_commit(store, root, doc) do
    {agent_pub, agent_priv} = Signing.generate_keypair()
    agent_uuid = "agent-" <> UUID.uuid4()

    {:ok, cert} =
      Capability.delegate(root.ctx, {agent_uuid, agent_pub}, %{
        verbs: [:write],
        scope: {:docs, [doc]},
        caveats: %{not_before: nil, not_after: nil}
      })

    :ok = CommitStore.store_capability(store, cert)

    commit =
      Commit.new(
        doc,
        Yelixer.Encoding.encode_update(Commonplace.Tree.Schema.new_schema()),
        nil,
        %{
          kind: :regular,
          snapshot_parent: :crypto.hash(:sha256, "epoch-" <> doc),
          capability_proof: cert.id
        }
      )
      |> Signing.sign_commit(agent_priv, Signing.signer_id(agent_uuid, agent_pub))

    :ok = CommitStore.import_commit(store, commit, validator: fn _ -> :ok end)
    commit
  end

  defp peer(doc), do: %{name: "peer-a", base_url: "stub://", token: "t", docs: [doc]}

  test "pulls a delegated agent commit into the strict store, cert chain inlined",
       %{serving: serving, pulling: pulling, root: root} do
    doc = UUID.uuid4()
    commit = seed_delegated_commit(serving, root, doc)

    report =
      PullClient.pull_once([peer(doc)], store: pulling, transport: stub_transport(serving))

    assert report.imported >= 1
    assert report.rejected == 0
    assert {:ok, _} = CommitStore.get_commit(pulling, commit.id)
    # The cert chain traveled in the envelope and landed too.
    assert {:ok, _} = CommitStore.get_capability(pulling, commit.metadata.capability_proof)
  end

  test "second pull is a no-op (CID diff finds nothing missing)",
       %{serving: serving, pulling: pulling, root: root} do
    doc = UUID.uuid4()
    _ = seed_delegated_commit(serving, root, doc)

    transport = stub_transport(serving)
    _ = PullClient.pull_once([peer(doc)], store: pulling, transport: transport)
    report = PullClient.pull_once([peer(doc)], store: pulling, transport: transport)

    assert report.imported == 0
    assert report.rejected == 0
  end

  test "an unsigned commit on the serving side is rejected by the pulling gate, counted",
       %{serving: serving, pulling: pulling} do
    doc = UUID.uuid4()

    unsigned =
      Commit.new(
        doc,
        Yelixer.Encoding.encode_update(Commonplace.Tree.Schema.new_schema()),
        nil,
        %{
          kind: :regular,
          snapshot_parent: :crypto.hash(:sha256, "epoch-u")
        }
      )

    # Trust config is global to the node — open a permissive window to
    # seed the serving side, then restore strict for the pull.
    strict = Application.get_env(:commonplace, :trust)
    Application.put_env(:commonplace, :trust, %{accept_unsigned: true, trusted_identities: %{}})
    :ok = CommitStore.import_commit(serving, unsigned, validator: fn _ -> :ok end)
    Application.put_env(:commonplace, :trust, strict)

    report =
      PullClient.pull_once([peer(doc)], store: pulling, transport: stub_transport(serving))

    assert report.rejected >= 1
    assert :none = CommitStore.get_commit(pulling, unsigned.id)
  end

  test "transport errors are reported, not raised", %{pulling: pulling} do
    failing = fn _op, _peer, _arg -> {:error, :econnrefused} end

    report = PullClient.pull_once([peer("any-doc")], store: pulling, transport: failing)

    assert report.imported == 0
    assert [{_peer, _doc, :econnrefused} | _] = report.errors
  end

  test "possessed sibling is excluded from the missing set while a missing CID is requested",
       %{pulling: pulling} do
    previous_trust = Application.get_env(:commonplace, :trust)
    Application.put_env(:commonplace, :trust, %{accept_unsigned: true, trusted_identities: %{}})
    on_exit(fn -> Application.put_env(:commonplace, :trust, previous_trust) end)

    doc = UUID.uuid4()
    {:ok, genesis} = CommitStore.ensure_genesis(pulling, doc)
    :ok = CommitStore.set_latest(pulling, doc, genesis.id)

    local =
      CommitStore.create_chained_commit(
        pulling,
        doc,
        Yelixer.Encoding.encode_update(Commonplace.Tree.Schema.new_schema()),
        %{kind: :regular, snapshot_parent: genesis.id}
      )

    sibling =
      Commit.new(
        doc,
        Yelixer.Encoding.encode_update(Commonplace.Tree.Schema.new_schema()),
        genesis.id,
        %{kind: :regular, snapshot_parent: genesis.id, fixture: :possessed_sibling}
      )

    :ok = CommitStore.import_commit(pulling, sibling, validator: fn _ -> :ok end)
    assert {:ok, %{id: id}} = CommitStore.latest_commit(pulling, doc)
    assert id == local.id
    assert MapSet.member?(CommitStore.all_commit_ids_for_doc(pulling, doc), sibling.id)
    refute MapSet.member?(CommitStore.commit_ids_for_doc(pulling, doc), sibling.id)

    missing_id = :crypto.hash(:sha256, "positive-control-missing")
    sibling_b64 = Base.encode64(sibling.id)
    missing_b64 = Base.encode64(missing_id)
    test_pid = self()

    transport = fn
      :cids, _peer, ^doc ->
        {:ok, %{"cids" => [sibling_b64, missing_b64]}}

      :commits, _peer, {^doc, requested} ->
        send(test_pid, {:requested, requested})
        {:ok, %{"envelopes" => []}}
    end

    report = PullClient.pull_once([peer(doc)], store: pulling, transport: transport)

    assert_receive {:requested, requested}
    assert requested == [missing_b64]
    assert report.errors == []
  end

  test "already-present first envelope does not block the second envelope",
       %{serving: serving, pulling: pulling} do
    previous_trust = Application.get_env(:commonplace, :trust)
    Application.put_env(:commonplace, :trust, %{accept_unsigned: true, trusted_identities: %{}})
    on_exit(fn -> Application.put_env(:commonplace, :trust, previous_trust) end)

    doc = UUID.uuid4()
    {:ok, genesis} = CommitStore.ensure_genesis(serving, doc)
    :ok = CommitStore.set_latest(serving, doc, genesis.id)
    :ok = CommitStore.import_commit(pulling, genesis, validator: fn _ -> :ok end)

    log = RedLog.new(doc, serving) |> RedLog.append_raw(%{"cycle" => 2})
    assert {:ok, _log} = RedLog.commit(log, [])
    {:ok, event} = CommitStore.latest_commit(serving, doc)

    first_envelope = Envelope.for_commit(serving, genesis)
    second_envelope = Envelope.for_commit(serving, event)

    transport = fn
      :cids, _peer, ^doc ->
        {:ok, %{"cids" => [Base.encode64(genesis.id), Base.encode64(event.id)]}}

      :commits, _peer, {^doc, [requested]} ->
        assert requested == Base.encode64(event.id)
        {:ok, %{"envelopes" => [first_envelope, second_envelope]}}
    end

    report = PullClient.pull_once([peer(doc)], store: pulling, transport: transport)

    assert report == %{imported: 1, deferred: 0, rejected: 0, errors: []}
    assert {:ok, _} = CommitStore.get_commit(pulling, event.id)
  end

  test "genesis cycle, event cycle, then quiescent pull stays live and readable",
       %{serving: serving, pulling: pulling} do
    previous_trust = Application.get_env(:commonplace, :trust)
    Application.put_env(:commonplace, :trust, %{accept_unsigned: true, trusted_identities: %{}})
    on_exit(fn -> Application.put_env(:commonplace, :trust, previous_trust) end)

    doc = UUID.uuid4()
    {:ok, genesis} = CommitStore.ensure_genesis(serving, doc)
    :ok = CommitStore.set_latest(serving, doc, genesis.id)
    transport = stub_transport(serving)

    assert %{imported: 1, errors: []} =
             PullClient.pull_once([peer(doc)], store: pulling, transport: transport)

    log = RedLog.new(doc, serving) |> RedLog.append_raw(%{"incident" => "reproduced"})
    assert {:ok, _log} = RedLog.commit(log, [])

    assert %{imported: 1, errors: []} =
             PullClient.pull_once([peer(doc)], store: pulling, transport: transport)

    assert MapSet.size(CommitStore.commit_ids_for_doc(pulling, doc)) == 2
    assert length(CommitStore.commit_log(pulling, doc)) == 2
    assert {:ok, _doc} = DocBuilder.reconstruct_doc(pulling, doc)
    assert RedLog.load(doc, pulling) |> RedLog.read() == [%{"incident" => "reproduced"}]

    assert PullClient.pull_once([peer(doc)], store: pulling, transport: transport) == %{
             imported: 0,
             deferred: 0,
             rejected: 0,
             errors: []
           }

    assert {:ok, _} = CommitStore.get_commit(pulling, genesis.id)
  end
end
