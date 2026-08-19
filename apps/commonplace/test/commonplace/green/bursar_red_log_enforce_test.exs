defmodule Commonplace.Green.BursarRedLogEnforceTest do
  use ExUnit.Case, async: false

  alias Commonplace.Crypto.{Signing, SigningContext}
  alias Commonplace.Dataflow.RedLog
  alias Commonplace.Document.ContentType
  alias Commonplace.Green.Bursar
  alias Commonplace.Store.{CommitStore, CommitStoreClient}
  alias Commonplace.Tree.{DocBuilder, Schema}

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_bursar_red_log_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    n = :rand.uniform(1_000_000_000)
    store = :"bursar_red_log_store_#{n}"
    start_supervised!({CommitStore, data_dir: dir, name: store})

    old_trust = Application.get_env(:commonplace, :trust)
    old_gate = Application.get_env(:commonplace, :local_write_gate)

    on_exit(fn ->
      restore_env(:trust, old_trust)
      restore_env(:local_write_gate, old_gate)
      File.rm_rf!(dir)
    end)

    {pub, priv} = Signing.generate_keypair()

    ctx = %SigningContext{
      identity_uuid: UUID.uuid4(),
      private_key: priv,
      public_key: pub
    }

    root = UUID.uuid4()
    create_doc(store, root, Schema.new_schema(), ctx)

    %{store: store, root: root, signing_context: ctx}
  end

  defp restore_env(key, nil), do: Application.delete_env(:commonplace, key)
  defp restore_env(key, value), do: Application.put_env(:commonplace, key, value)

  defp create_doc(store, uuid, doc, signing_context) do
    update = Yelixer.Encoding.encode_update(doc)

    CommitStoreClient.create_commit(store, uuid, update, nil, %{},
      signing_context: signing_context
    )
  end

  defp strict!(trusted_contexts) do
    trusted =
      Map.new(trusted_contexts, fn ctx ->
        {ctx.identity_uuid, Signing.encode_key(ctx.public_key)}
      end)

    Application.put_env(:commonplace, :trust, %{
      accept_unsigned: false,
      trusted_identities: trusted
    })

    Application.put_env(:commonplace, :local_write_gate, :enforce)
  end

  defp permissive! do
    Application.put_env(:commonplace, :trust, %{
      accept_unsigned: true,
      trusted_identities: %{}
    })

    Application.put_env(:commonplace, :local_write_gate, :off)
  end

  defp start_bursar(ctx, signing_context) do
    name = :"bursar_red_log_#{:rand.uniform(1_000_000_000)}"

    result =
      Bursar.start_link(
        root_uuid: ctx.root,
        store: ctx.store,
        name: name,
        signing_context: signing_context,
        sweep_interval: 60_000
      )

    case result do
      {:ok, pid} ->
        on_exit(fn ->
          if Process.alive?(pid) do
            try do
              GenServer.stop(pid)
            catch
              :exit, _ -> :ok
            end
          end
        end)

      _ ->
        :ok
    end

    {result, name}
  end

  defp attach(event, callback) do
    id = "#{inspect(event)}-#{System.unique_integer([:positive])}"
    :ok = :telemetry.attach(id, event, callback, nil)
    on_exit(fn -> :telemetry.detach(id) end)
  end

  test "a denial-log write lands signed under enforce", ctx do
    strict!([ctx.signing_context])
    assert {{:ok, _pid}, bursar} = start_bursar(ctx, ctx.signing_context)

    assert {:ok, _} = Bursar.acquire(bursar, "shared.txt", "alice", ttl: 60_000)
    assert {:denied, %{holder: "alice"}} = Bursar.acquire(bursar, "shared.txt", "bob")

    {:ok, schema} = DocBuilder.reconstruct_snapshot(ctx.store, ctx.root)
    {:ok, log_entry} = Schema.get_entry(schema, "__bursar.log")
    {:ok, head} = CommitStore.latest_commit(ctx.store, log_entry.node_id)

    assert head.signer_id ==
             Signing.signer_id(
               ctx.signing_context.identity_uuid,
               ctx.signing_context.public_key
             )

    denied =
      log_entry.node_id
      |> RedLog.load(ctx.store)
      |> RedLog.read()
      |> Enum.filter(&(&1["event"] == "denied"))

    assert [%{"holder" => "bob", "path" => "shared.txt"}] = denied
  end

  test "a refused event write is surfaced and does not advance the in-memory log", ctx do
    permissive!()
    assert {{:ok, _pid}, bursar} = start_bursar(ctx, ctx.signing_context)
    before_log = :sys.get_state(bursar).log

    {other_pub, other_priv} = Signing.generate_keypair()

    other_ctx = %SigningContext{
      identity_uuid: UUID.uuid4(),
      private_key: other_priv,
      public_key: other_pub
    }

    strict!([other_ctx])
    test_pid = self()

    attach([:commonplace, :bursar, :red_log_write_failed], fn event, measurements, metadata, _ ->
      send(test_pid, {:telemetry, event, measurements, metadata})
    end)

    assert {:ok, _} = Bursar.acquire(bursar, "ephemeral.txt", "alice", ttl: 60_000)

    assert_receive {:telemetry, [:commonplace, :bursar, :red_log_write_failed], _, metadata}
    assert match?({:trust_rejected, _}, metadata.reason)
    assert :sys.get_state(bursar).log == before_log
  end

  test "a refused log-doc creation DEGRADES loudly: the Bursar still starts, and no dangling schema entry is written",
       ctx do
    Process.flag(:trap_exit, true)
    permissive!()

    state_uuid = UUID.uuid4()

    state_doc =
      Yelixer.Doc.new()
      |> ContentType.create(:text, "__bursar.json")
      |> ContentType.insert_text(0, "{}")

    create_doc(ctx.store, state_uuid, state_doc, ctx.signing_context)

    {:ok, schema} = DocBuilder.reconstruct_snapshot(ctx.store, ctx.root)
    schema = Schema.add_file(schema, "__bursar.json", state_uuid)

    CommitStoreClient.create_chained_commit(
      ctx.store,
      ctx.root,
      Yelixer.Encoding.encode_update(schema),
      %{},
      signing_context: ctx.signing_context
    )

    strict!([])

    attach([:commonplace, :commit, :rejected, :local_trust], fn _event,
                                                                _measurements,
                                                                _metadata,
                                                                _ ->
      Application.put_env(:commonplace, :trust, %{
        accept_unsigned: true,
        trusted_identities: %{}
      })
    end)

    self_pid = self()

    attach([:commonplace, :bursar, :red_log_create_failed], fn event, _m, metadata, _ ->
      send(self_pid, {:bursar_telemetry, event, metadata})
    end)

    # ⛔ THE BURSAR MUST STILL START. A refused red-LOG write must not take
    # down the custody manager: create_log_doc/2 runs inside init/1 under a
    # `restart: :permanent` child spec, so exiting here would be a boot crash
    # loop on any enforce node with an unresolvable signing context — and it
    # would invert this codebase's own rule, "losing its RECORD must never
    # turn into losing its ENFORCEMENT" (AuditDispatcher.offer/2).
    assert {{:ok, pid}, _name} = start_bursar(ctx, ctx.signing_context)
    assert Process.alive?(pid)

    # …and the refusal is LOUD, not swallowed.
    assert_receive {:bursar_telemetry, [:commonplace, :bursar, :red_log_create_failed], _meta}

    # …and the dangling-entry hazard stays closed: no schema entry points at
    # the commit-less doc.
    {:ok, schema_after} = DocBuilder.reconstruct_snapshot(ctx.store, ctx.root)
    assert :error = Schema.get_entry(schema_after, "__bursar.log")
  end
end
