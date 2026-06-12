defmodule CommonplaceWebWeb.FederationRoundTripTest do
  @moduledoc """
  Phase C acceptance (CX-orfw.1): the FULL federation round-trip over a
  REAL TCP socket — two separate-rooted stores, no shared anything.

  The serving workspace (default CommitStore behind the real router +
  parsers, listening on an ephemeral port via Bandit) holds an agent's
  delegated, signed commit. The pulling workspace (its own CommitStore)
  runs `PullClient.pull_once/2` with the DEFAULT HTTP transport (Req) —
  CID diff, envelope fetch, cert verify+store, and import through its
  own strict Gate A. This is move #1's invariant end-to-end: an external
  principal's commit crosses a dumb transport and lands only because the
  cert chain verifies against a locally-pinned root.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Crypto.{Signing, SigningContext}
  alias Commonplace.Federation.PullClient
  alias Commonplace.Store.{Commit, CommitStore}
  alias Commonplace.Trust.Capability

  @token "round-trip-token"

  defmodule ServerPipeline do
    @moduledoc false
    use Plug.Builder

    plug Plug.Parsers, parsers: [:json], pass: ["*/*"], json_decoder: Jason
    plug CommonplaceWebWeb.Router
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_fed_rt_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)

    # Serving side = the DEFAULT CommitStore (the controller's store),
    # pointed at scratch (wiki_live_test pattern).
    Application.put_env(:commonplace, :data_dir, dir)
    sup = Commonplace.Store.CommitStoreSupervisor
    _ = Supervisor.terminate_child(sup, CommitStore)
    _ = Supervisor.delete_child(sup, CommitStore)
    {:ok, _} = Supervisor.start_child(sup, {CommitStore, data_dir: dir})

    # Pulling side = its own store, its own root.
    pulling = :"fed_rt_pulling_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: Path.join(dir, "pulling"), name: pulling})

    # Real HTTP server on an ephemeral port: parsers + the real router.
    server = start_supervised!({Bandit, plug: ServerPipeline, scheme: :http, port: 0})
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    Application.put_env(:commonplace_web, :federation_peers, %{@token => "puller"})

    on_exit(fn ->
      Application.delete_env(:commonplace_web, :federation_peers)
      Application.delete_env(:commonplace, :trust)
      Application.put_env(:commonplace, :data_dir, "tmp/test_data")
      File.rm_rf!(dir)
    end)

    %{pulling: pulling, port: port}
  end

  test "agent commit federates A→B over real HTTP and lands through strict Gate A",
       %{pulling: pulling, port: port} do
    # Shared root of trust: pinned on the pulling side, issuer of the
    # agent's cert on the serving side.
    {root_pub, root_priv} = Signing.generate_keypair()
    root_uuid = "root-" <> UUID.uuid4()
    root_ctx = %SigningContext{identity_uuid: root_uuid, private_key: root_priv, public_key: root_pub}

    Application.put_env(:commonplace, :trust, %{
      accept_unsigned: false,
      trusted_identities: %{root_uuid => Signing.encode_key(root_pub)}
    })

    # On the SERVING workspace: an agent with a delegated write cert
    # authors a signed commit.
    doc = UUID.uuid4()
    {agent_pub, agent_priv} = Signing.generate_keypair()
    agent_uuid = "agent-" <> UUID.uuid4()

    {:ok, cert} =
      Capability.delegate(root_ctx, {agent_uuid, agent_pub}, %{
        verbs: [:write],
        scope: {:docs, [doc]},
        caveats: %{not_before: nil, not_after: nil}
      })

    :ok = CommitStore.store_capability(CommitStore, cert)

    commit =
      Commit.new(doc, Yelixer.Encoding.encode_update(Commonplace.Tree.Schema.new_schema()), nil, %{
        kind: :regular,
        snapshot_parent: :crypto.hash(:sha256, "fed-rt-epoch"),
        capability_proof: cert.id
      })
      |> Signing.sign_commit(agent_priv, Signing.signer_id(agent_uuid, agent_pub))

    :ok = CommitStore.import_commit(CommitStore, commit, validator: fn _ -> :ok end)

    # The pulling workspace federates over the real socket — default
    # HTTP transport, bearer-token auth, strict import gate.
    peer = %{name: "ws-a", base_url: "http://127.0.0.1:#{port}", token: @token, docs: [doc]}
    report = PullClient.pull_once([peer], store: pulling)

    assert report.imported >= 1
    assert report.errors == []
    assert {:ok, landed} = CommitStore.get_commit(pulling, commit.id)
    assert landed.signer_id == Signing.signer_id(agent_uuid, agent_pub)
    assert {:ok, _} = CommitStore.get_capability(pulling, cert.id)

    # And the wrong token is turned away at the door.
    bad_peer = %{peer | token: "wrong"}
    bad_report = PullClient.pull_once([bad_peer], store: pulling)
    assert [{_, _, {:http_status, 403}} | _] = bad_report.errors
  end
end
