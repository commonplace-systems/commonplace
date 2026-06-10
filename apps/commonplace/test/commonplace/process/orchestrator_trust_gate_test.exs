defmodule Commonplace.Process.OrchestratorTrustGateTest do
  @moduledoc """
  CX-tdkq.2 (R2, Gate B second ingress): the Orchestrator collects
  `__processes.json` from every directory and spawns what it declares —
  in-BEAM GenServers (`:elixir`) or OS commands with `$secret:KEY` env
  resolution (`:sandbox_exec`). A declaration doc is execute-authority,
  so its contributing commit chain must pass
  `Trust.authorized_to_execute?` like any code doc.

  This is the ONLY gate protecting `:sandbox_exec` — that mode never
  touches `SourceDoc.compile`.

  Because the gate drops untrusted declarations from the *declared*
  config, the reconcile loop's normal convergence also STOPS an
  already-running process once trust is revoked (the declaration
  disappears from the diff) — revocation with teeth, for free.
  """
  use ExUnit.Case

  alias Commonplace.Crypto.{Signing, SigningContext}
  alias Commonplace.Document.ContentType
  alias Commonplace.Process.Orchestrator
  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.Schema

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_orch_trust_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    store_name = :"orch_trust_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store_name})

    root_uuid = UUID.uuid4()
    root_doc = Schema.new_schema()
    update = Yelixer.Encoding.encode_update(root_doc)
    CommitStore.create_commit(store_name, root_uuid, update, nil)

    {pub, priv} = Signing.generate_keypair()
    identity = "0c8e0000-0000-0000-0000-#{:rand.uniform(999_999_999_999)}"
    ctx = %SigningContext{identity_uuid: identity, private_key: priv, public_key: pub}

    Process.flag(:trap_exit, true)

    on_exit(fn ->
      Application.delete_env(:commonplace, :trust)
      File.rm_rf!(dir)
    end)

    %{store: store_name, root: root_uuid, identity: identity, pub: pub, ctx: ctx}
  end

  defp strict!(trusted) do
    Application.put_env(:commonplace, :trust, %{
      accept_unsigned: false,
      trusted_identities: trusted
    })
  end

  defp permissive! do
    Application.put_env(:commonplace, :trust, %{
      accept_unsigned: true,
      trusted_identities: %{}
    })
  end

  defp put_doc(store, root, filename, content, opts) do
    uuid = UUID.uuid4()
    doc = Yelixer.Doc.new()
    doc = ContentType.create(doc, :text, filename)
    doc = ContentType.insert_text(doc, 0, content)
    update = Yelixer.Encoding.encode_update(doc)
    CommitStore.create_chained_commit(store, uuid, update, %{kind: :regular}, opts)

    root_doc = load_schema(root, store)
    root_doc = Schema.add_file(root_doc, filename, uuid)
    root_update = Yelixer.Encoding.encode_update(root_doc)
    CommitStore.create_chained_commit(store, root, root_update)
    uuid
  end

  defp load_schema(uuid, store) do
    case CommitStore.latest_commit(store, uuid) do
      {:ok, commit} ->
        doc = Schema.new_schema()
        {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)
        doc

      :none ->
        Schema.new_schema()
    end
  end

  defp greeter_source(n) do
    """
    defmodule Commonplace.UserProcess.TrustGate#{n} do
      use GenServer
      def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
      def init(opts), do: {:ok, opts}
    end
    """
  end

  defp processes_json(name, source_file) do
    Jason.encode!(%{name => %{"mode" => "elixir", "source" => source_file}})
  end

  test "strict: untrusted __processes.json declarations are not started",
       %{store: store, root: root} do
    put_doc(store, root, "tg1.exs", greeter_source("One"), [])
    put_doc(store, root, "__processes.json", processes_json("trust_gate_one", "tg1.exs"), [])

    strict!(%{})

    {:ok, orch} = Orchestrator.start_link(root_uuid: root, store: store, interval: 100)
    Process.sleep(300)

    assert Orchestrator.running_processes(orch) == %{}

    Process.unlink(orch)
    GenServer.stop(orch)
  end

  test "strict: trusted declaration + trusted source starts",
       %{store: store, root: root, identity: identity, pub: pub, ctx: ctx} do
    put_doc(store, root, "tg2.exs", greeter_source("Two"), signing_context: ctx)

    put_doc(
      store,
      root,
      "__processes.json",
      processes_json("trust_gate_two", "tg2.exs"),
      signing_context: ctx
    )

    strict!(%{identity => Signing.encode_key(pub)})

    {:ok, orch} = Orchestrator.start_link(root_uuid: root, store: store, interval: 100)
    Process.sleep(300)

    assert Map.has_key?(Orchestrator.running_processes(orch), "trust_gate_two")

    Process.unlink(orch)
    GenServer.stop(orch)
  end

  test "revoking trust stops an already-running process on the next reconcile",
       %{store: store, root: root} do
    put_doc(store, root, "tg3.exs", greeter_source("Three"), [])
    put_doc(store, root, "__processes.json", processes_json("trust_gate_three", "tg3.exs"), [])

    permissive!()

    {:ok, orch} = Orchestrator.start_link(root_uuid: root, store: store, interval: 100)
    Process.sleep(300)
    assert Map.has_key?(Orchestrator.running_processes(orch), "trust_gate_three")

    # Revoke: strict mode, no pinned identities — the unsigned
    # declaration is no longer execute-authorized.
    strict!(%{})
    Process.sleep(300)

    assert Orchestrator.running_processes(orch) == %{}

    Process.unlink(orch)
    GenServer.stop(orch)
  end

  test "denied declarations emit [:commonplace, :process, :rejected, :trust]",
       %{store: store, root: root} do
    put_doc(store, root, "tg4.exs", greeter_source("Four"), [])
    decl_uuid = put_doc(store, root, "__processes.json", processes_json("tg4", "tg4.exs"), [])

    strict!(%{})

    ref = make_ref()
    parent = self()

    :telemetry.attach(
      {:orch_trust_handler, ref},
      [:commonplace, :process, :rejected, :trust],
      fn _event, _meas, meta, _cfg -> send(parent, {:decl_rejected, ref, meta}) end,
      nil
    )

    {:ok, orch} = Orchestrator.start_link(root_uuid: root, store: store, interval: 100)

    assert_receive {:decl_rejected, ^ref, meta}, 1_000
    assert meta.doc_uuid == decl_uuid

    :telemetry.detach({:orch_trust_handler, ref})
    Process.unlink(orch)
    GenServer.stop(orch)
  end
end
