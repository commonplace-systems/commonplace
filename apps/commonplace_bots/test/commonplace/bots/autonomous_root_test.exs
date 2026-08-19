defmodule Commonplace.Bots.AutonomousRootTest do
  @moduledoc """
  CX-k87w pin — the autonomous-tick dispatch tail must thread the
  REGISTERED `mud_root` (as `:root_uuid`) into the Worker, not leave it to
  fall back to the workspace root.

  Deliberately does NOT use `worker_hook` — that's exactly why this gap
  stayed green before the fix: `worker_hook` intercepts BEFORE
  `invoke_worker/4` assembles the spawn opts, so the threading bug was never
  exercised. This test drives the REAL `invoke_worker` -> `spawn_worker` ->
  `Commonplace.Bots.Worker.run/4` path and observes what root the Worker
  actually resolved through the `look` tool's output: without the fix,
  `Worker.run/4` resolves `root_uuid` from `opts[:root_uuid] || workspace_root()`
  (both nil/wrong on this test's isolated store), so `mud_ctx` comes back
  `nil` and `look` refuses ("You are not in the world.") instead of showing
  the citizen's provisioned Foyer.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Bots.{Citizen, Dispatcher}
  alias Commonplace.Bots.Identity, as: BotIdentity
  alias Commonplace.Bots.MudContext
  alias Commonplace.Crypto.NodeIdentity
  alias Commonplace.Document.ContentType
  alias Commonplace.Store.{CommitStore, SecretStore}
  alias Commonplace.Tree.Schema
  alias Yelixer.Encoding

  setup do
    n = :rand.uniform(1_000_000_000)
    dir = Path.join(System.tmp_dir!(), "cp_bots_autoroot_#{n}")
    File.mkdir_p!(dir)
    store = :"autoroot_store_#{n}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: dir,
       name: :"autoroot_sup_#{n}",
       commit_store_name: store,
       trust_side_store_name: :"autoroot_tss_#{n}",
       pending_imports_name: :"autoroot_pi_#{n}"}
    )

    old_data_dir = Application.get_env(:commonplace, :data_dir)
    Application.put_env(:commonplace, :data_dir, dir)

    secrets_dir = Path.join(System.tmp_dir!(), "cp_bots_autoroot_secrets_#{n}")
    File.mkdir_p!(secrets_dir)
    secrets = :"autoroot_secrets_#{n}"
    {:ok, secrets_pid} = SecretStore.start_link(data_dir: secrets_dir, name: secrets)

    {:ok, node_ctx} = NodeIdentity.signing_context()

    # A REAL dispatcher bound to THIS test's store, with NO worker_hook —
    # the point of this pin is to exercise the production spawn_worker path.
    test_pid = self()

    bots_sup = Commonplace.Bots.Supervisor
    _ = Supervisor.terminate_child(bots_sup, Commonplace.Bots.Dispatcher)
    _ = Supervisor.delete_child(bots_sup, Commonplace.Bots.Dispatcher)

    {:ok, _pid} =
      Supervisor.start_child(
        bots_sup,
        Supervisor.child_spec(
          {Commonplace.Bots.Dispatcher,
           [rate_limit_enabled: false, store: store, node_ctx: node_ctx]},
          id: Commonplace.Bots.Dispatcher
        )
      )

    on_exit(fn ->
      _ = Supervisor.terminate_child(bots_sup, Commonplace.Bots.Dispatcher)
      _ = Supervisor.delete_child(bots_sup, Commonplace.Bots.Dispatcher)
      # Let the spawned worker Task drain before the store disappears.
      Process.sleep(200)

      {:ok, _pid} =
        Supervisor.start_child(
          bots_sup,
          Supervisor.child_spec({Commonplace.Bots.Dispatcher, []},
            id: Commonplace.Bots.Dispatcher
          )
        )

      Application.put_env(:commonplace, :data_dir, old_data_dir || "tmp/test_data")

      if Process.alive?(secrets_pid) do
        try do
          GenServer.stop(secrets_pid)
        catch
          :exit, _ -> :ok
        end
      end

      File.rm_rf!(dir)
      File.rm_rf!(secrets_dir)
    end)

    # The MUD root — DELIBERATELY distinct from any workspace root the
    # Worker might fall back to (`Commonplace.Workspace.root_uuid/0`),
    # so a wrong-root resolution is observable, not accidentally correct.
    mud_root = UUID.uuid4()

    CommitStore.create_commit(
      store,
      mud_root,
      Encoding.encode_update(Schema.new_schema()),
      nil,
      %{},
      signing_context: node_ctx
    )

    %{store: store, mud_root: mud_root, secrets: secrets, node_ctx: node_ctx, test_pid: test_pid}
  end

  ## Fixtures (mirrors heartbeat_test.exs / worker_test.exs conventions)

  defp mint_text_doc(store, name, body) do
    uuid = UUID.uuid4()
    doc = Yelixer.Doc.new()
    doc = ContentType.create(doc, :text, name)
    doc = if body == "", do: doc, else: ContentType.insert_text(doc, 0, body)
    CommitStore.create_commit(store, uuid, Encoding.encode_update(doc), nil)
    uuid
  end

  # A text doc whose commit is NODE-signed — the C3a charter grantor. Without
  # a node-signed bot.json, `Allowlist.resolve/4` closes to `[]` and `look`
  # would be denied for an unrelated reason (no charter), masking this pin.
  defp mint_signed_text_doc(store, node_ctx, name, body) do
    uuid = UUID.uuid4()
    doc = Yelixer.Doc.new()
    doc = ContentType.create(doc, :text, name)
    doc = if body == "", do: doc, else: ContentType.insert_text(doc, 0, body)
    update = Yelixer.Encoding.encode_update(doc)
    CommitStore.create_commit(store, uuid, update, nil, %{}, signing_context: node_ctx)
    uuid
  end

  # Minimal .bot CHARTER dir — persona.md + trigger.regex + a NODE-signed
  # bot.json granting exactly ["look"] (the minimum this pin needs).
  defp mint_bot_dir(store, node_ctx) do
    schema =
      Schema.new_schema()
      |> Schema.add_file("persona.md", mint_text_doc(store, "persona.md", "I am camillo."))
      |> Schema.add_file("trigger.regex", mint_text_doc(store, "trigger.regex", "(?i)@camillo"))
      |> Schema.add_file(
        "bot.json",
        mint_signed_text_doc(store, node_ctx, "bot.json", Jason.encode!(%{"tools" => ["look"]}))
      )

    uuid = UUID.uuid4()
    CommitStore.create_commit(store, uuid, Encoding.encode_update(schema), nil)
    uuid
  end

  defp provision_camillo(ctx) do
    {:ok, prov} = Citizen.provision("camillo", ctx.mud_root, ctx.store, secret_store: ctx.secrets)

    {:ok, sc} =
      BotIdentity.resolve_signing_context("camillo", ctx.mud_root, ctx.store,
        secret_store: ctx.secrets
      )

    {:ok, mud_ctx} = MudContext.resolve(%{name: "camillo"}, sc, ctx.mud_root, ctx.store)
    {prov, mud_ctx}
  end

  defp tick(name),
    do: send(Process.whereis(Commonplace.Bots.Dispatcher), {:autonomous_tick, name})

  defp tool_use(id, name, input) do
    %{
      "stop_reason" => "tool_use",
      "content" => [
        %{"type" => "tool_use", "id" => id, "name" => name, "input" => input}
      ],
      "usage" => %{"output_tokens" => 5}
    }
  end

  defp end_turn(text \\ "ok") do
    %{
      "stop_reason" => "end_turn",
      "content" => [%{"type" => "text", "text" => text}],
      "usage" => %{"output_tokens" => 5}
    }
  end

  # Call 1: emit a `look` tool_use. Call 2: the request the Worker sends
  # BACK to the model carries the look tool_result in its messages — capture
  # that request (not just the outcome) so the test can inspect what the
  # bot actually saw, then end the turn.
  defp stub_client(test_pid) do
    {:ok, agent} = Agent.start_link(fn -> 0 end)

    fn request ->
      case Agent.get_and_update(agent, fn n -> {n + 1, n + 1} end) do
        1 ->
          {:ok, tool_use("t1", "look", %{})}

        _ ->
          send(test_pid, {:worker_request, request})
          {:ok, end_turn()}
      end
    end
  end

  test "autonomous tick's look tool sees the REGISTERED mud_root, not the workspace root", ctx do
    {prov, _mud_ctx} = provision_camillo(ctx)
    bot_dir = mint_bot_dir(ctx.store, ctx.node_ctx)

    # Seed the agenda non-empty so the heartbeat trigger wakes (not :skip).
    {:ok, sc} =
      BotIdentity.resolve_signing_context("camillo", ctx.mud_root, ctx.store,
        secret_store: ctx.secrets
      )

    {:ok, mud_ctx} = MudContext.resolve(%{name: "camillo"}, sc, ctx.mud_root, ctx.store)
    :ok = Commonplace.Bots.Agenda.append(%{"text" => "look around"}, mud_ctx)

    :ok =
      Dispatcher.register_autonomous_bot("camillo.bot", bot_dir, ctx.mud_root, 60_000,
        secret_store: ctx.secrets,
        client_fn: stub_client(ctx.test_pid)
      )

    tick("camillo")

    assert_receive {:worker_request, request}, 5_000

    [_initial, _assistant_msg, user_msg] = request.messages
    [%{"type" => "tool_result"} = tool_result] = user_msg["content"]

    refute tool_result["is_error"] == true,
           "look tool errored: #{inspect(tool_result["content"])}"

    text = tool_result["content"]

    # Without the fix, Worker.run/4 resolves root_uuid from opts[:root_uuid]
    # (absent on the old code path) || workspace_root() — NOT ctx.mud_root —
    # so mud_ctx comes back nil and `look` refuses gracefully instead of
    # showing the world. That refusal string is the RED signature; asserting
    # its absence (and the presence of the provisioned Foyer) is the pin.
    refute text =~ "not in the world"
    assert text =~ "Foyer"
    assert prov.foyer_uuid
  end
end
