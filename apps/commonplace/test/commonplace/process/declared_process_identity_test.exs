defmodule Commonplace.Process.DeclaredProcessIdentityTest do
  @moduledoc """
  CX-hk0s acceptance: an execute-authorized declared process is registered
  as an actor and its sandbox RedLog writes as that process under enforce.
  """

  use ExUnit.Case, async: false

  alias Commonplace.Crypto.{Signing, SigningContext}
  alias Commonplace.Dataflow.RedLog
  alias Commonplace.Document.ContentType
  alias Commonplace.Presence.Identity
  alias Commonplace.Process.{Orchestrator, SandboxExecRunner}
  alias Commonplace.Store.{CommitStore, SecretStore}
  alias Commonplace.Tree.Schema

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_declared_identity_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)

    old_data_dir = Application.get_env(:commonplace, :data_dir)
    old_trust = Application.get_env(:commonplace, :trust)
    old_local_gate = Application.get_env(:commonplace, :local_write_gate)

    node_identity = "fixture-node-#{UUID.uuid4()}"
    {node_pub, node_priv} = Signing.generate_keypair()

    File.write!(Path.join(dir, "node_id"), node_identity <> "\n")

    File.write!(
      Path.join(dir, "node_signing_key"),
      Base.encode64(node_pub) <> "\n" <> Base.encode64(node_priv) <> "\n"
    )

    Application.put_env(:commonplace, :data_dir, dir)

    n = :rand.uniform(1_000_000)
    store = :"declared_identity_store_#{n}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: Path.join(dir, "store"),
       name: :"declared_identity_sup_#{n}",
       commit_store_name: store,
       trust_side_store_name: :"declared_identity_tss_#{n}",
       pending_imports_name: :"declared_identity_pi_#{n}"}
    )

    root_uuid = UUID.uuid4()
    root_doc = Schema.new_schema()
    CommitStore.create_commit(store, root_uuid, Yelixer.Encoding.encode_update(root_doc), nil)

    node_ctx = %SigningContext{
      identity_uuid: node_identity,
      private_key: node_priv,
      public_key: node_pub
    }

    Application.put_env(:commonplace, :trust, %{
      accept_unsigned: false,
      trusted_identities: %{node_identity => Signing.encode_key(node_pub)}
    })

    Application.put_env(:commonplace, :local_write_gate, :enforce)

    on_exit(fn ->
      restore_env(:data_dir, old_data_dir)
      restore_env(:trust, old_trust)
      restore_env(:local_write_gate, old_local_gate)
      File.rm_rf!(dir)
    end)

    %{store: store, root: root_uuid, node_ctx: node_ctx}
  end

  test "reconciling twice writes NOTHING new to the identity doc", ctx do
    # ⛔ THE STORM REGRESSION. register_process_identity/3 runs on EVERY
    # reconcile pass (5s in production). Identity.register_agent/4 ->
    # register/5 takes the existing-identity branch -> touch_last_seen/3,
    # which writes an UNCONDITIONAL create_chained_commit whose `last_seen`
    # timestamp differs every time and so can NEVER dedupe.
    #
    # ~17,280 commits per declared process per day, growing the identity
    # doc's chain without bound — and ACCEPTED writes, so unlike the 08-07
    # storm nothing refuses them and nothing reports it. The fix is
    # lookup-before-register (Identity.lookup/4 is a pure read).
    #
    # ⚠️ This asserts on COMMIT COUNT, not on "the process still runs" —
    # those are different claims and only one of them is about this change.
    name = "reconcile_idem_#{:rand.uniform(1_000_000)}"

    declaration =
      Jason.encode!(%{
        name => %{
          "mode" => "sandbox-exec",
          "command" => "/bin/echo",
          "args" => ["idempotence"]
        }
      })

    put_doc(ctx.store, ctx.root, "__processes.json", declaration, signing_context: ctx.node_ctx)

    {:ok, orch} =
      Orchestrator.start_link(root_uuid: ctx.root, store: ctx.store, interval: 60_000)

    send(orch, :reconcile)
    _ = :sys.get_state(orch)

    {:ok, identity_uuid} = Identity.lookup(name, :bot, ctx.root, ctx.store)
    before_count = length(CommitStore.commit_log(ctx.store, identity_uuid, limit: 10_000))
    assert before_count > 0, "expected the first pass to have created the identity doc"

    # Three more passes, as production would do every 5 seconds.
    for _ <- 1..3 do
      send(orch, :reconcile)
      _ = :sys.get_state(orch)
    end

    after_count = length(CommitStore.commit_log(ctx.store, identity_uuid, limit: 10_000))

    assert after_count == before_count,
           "reconcile wrote #{after_count - before_count} new commit(s) to the identity doc " <>
             "across 3 passes; at the production 5s interval that is " <>
             "#{div((after_count - before_count) * 17_280, 3)} commits/day/process"

    Process.unlink(orch)
    GenServer.stop(orch)

    SecretStore.delete("signing_key:" <> identity_uuid)
    SecretStore.delete("signing_pub:" <> identity_uuid)
  end

  test "registered sandbox process lands RedLog commits as itself under enforce", ctx do
    name = "declared_writer_#{:rand.uniform(1_000_000)}"

    declaration =
      Jason.encode!(%{
        name => %{
          "mode" => "sandbox-exec",
          "command" => "/bin/echo",
          "args" => ["process-owned log"]
        }
      })

    put_doc(ctx.store, ctx.root, "__processes.json", declaration, signing_context: ctx.node_ctx)

    {:ok, orch} =
      Orchestrator.start_link(root_uuid: ctx.root, store: ctx.store, interval: 60_000)

    send(orch, :reconcile)
    _ = :sys.get_state(orch)

    {:ok, identity_uuid} = Identity.lookup(name, :bot, ctx.root, ctx.store)
    {:ok, process_pub_b64} = SecretStore.get("signing_pub:" <> identity_uuid)
    process_pub = Base.decode64!(process_pub_b64)

    runner = Map.fetch!(Orchestrator.running_processes(orch), name)
    log_uuid = SandboxExecRunner.event_log_uuid(runner)

    head =
      eventually(fn ->
        case CommitStore.latest_commit(ctx.store, log_uuid) do
          {:ok, commit} -> {:ok, commit}
          :none -> :retry
        end
      end)

    assert head.signer_id == Signing.signer_id(identity_uuid, process_pub)
    assert is_binary(head.metadata.capability_proof)

    events = log_uuid |> RedLog.load(ctx.store) |> RedLog.read()
    assert Enum.any?(events, &(&1["line"] == "process-owned log"))

    Process.unlink(orch)
    GenServer.stop(orch)

    SecretStore.delete("signing_key:" <> identity_uuid)
    SecretStore.delete("signing_pub:" <> identity_uuid)
  end

  defp put_doc(store, root, filename, content, opts) do
    uuid = UUID.uuid4()
    doc = Yelixer.Doc.new()
    doc = ContentType.create(doc, :text, filename)
    doc = ContentType.insert_text(doc, 0, content)

    CommitStore.create_chained_commit(
      store,
      uuid,
      Yelixer.Encoding.encode_update(doc),
      %{kind: :regular},
      opts
    )

    root_doc = load_schema(root, store)
    root_doc = Schema.add_file(root_doc, filename, uuid)

    CommitStore.create_chained_commit(
      store,
      root,
      Yelixer.Encoding.encode_update(root_doc),
      %{},
      opts
    )

    uuid
  end

  defp load_schema(uuid, store) do
    {:ok, commit} = CommitStore.latest_commit(store, uuid)
    doc = Schema.new_schema()
    {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)
    doc
  end

  defp eventually(fun, timeout_ms \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_eventually(fun, deadline)
  end

  defp do_eventually(fun, deadline) do
    case fun.() do
      {:ok, value} ->
        value

      :retry ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("timed out waiting for declared process RedLog commit")
        else
          receive do
          after
            25 -> do_eventually(fun, deadline)
          end
        end
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:commonplace, key)
  defp restore_env(key, value), do: Application.put_env(:commonplace, key, value)
end
