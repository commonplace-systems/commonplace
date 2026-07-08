defmodule Commonplace.MUD.BotTest do
  use ExUnit.Case

  alias Commonplace.Crypto.{AgentKeys, Signing}
  alias Commonplace.MUD.{Bootstrap, Bot, PlayerSession}
  alias Commonplace.Presence.Identity
  alias Commonplace.Store.{CommitStore, SecretStore}
  alias Commonplace.Tree.Schema
  alias Yelixer.Encoding

  setup do
    Application.ensure_all_started(:phoenix_pubsub)

    case Phoenix.PubSub.Supervisor.start_link(name: Commonplace.PubSub) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    dir = Path.join(System.tmp_dir!(), "cp_mud_bot_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    store = :"commit_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store})
    on_exit(fn -> File.rm_rf!(dir) end)

    # Moves take green tokens (move #4): start a Bursar under its default
    # name so World.move's default route finds it (replaces the retired
    # :global MoveServer).
    case GenServer.whereis(Commonplace.Green.Bursar) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end

    {:ok, bursar_pid} =
      Commonplace.Green.Bursar.start_link(
        root_uuid: UUID.uuid4(),
        store: store,
        sweep_interval: 60_000
      )

    on_exit(fn -> if Process.alive?(bursar_pid), do: GenServer.stop(bursar_pid) end)

    root_uuid = UUID.uuid4()
    update = Encoding.encode_update(Schema.new_schema())
    CommitStore.create_commit(store, root_uuid, update, nil)
    {:ok, _} = Bootstrap.seed(root_uuid, store)

    # CX-5plk: isolated SecretStore so per-bot signing-key custody
    # assertions don't share state with the app's global SecretStore
    # (or other tests running concurrently against it).
    secrets_dir = Path.join(System.tmp_dir!(), "cp_mud_bot_secrets_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(secrets_dir)
    secrets_name = :"cp_mud_bot_secrets_#{:rand.uniform(1_000_000_000)}"
    {:ok, secrets_pid} = SecretStore.start_link(data_dir: secrets_dir, name: secrets_name)

    on_exit(fn ->
      Bot.stop("bartleby")
      Bot.stop("watcher")
      Bot.stop("scribe")
      Bot.stop("dup")
      if Process.alive?(secrets_pid), do: GenServer.stop(secrets_pid)
      File.rm_rf!(secrets_dir)
    end)

    %{store: store, root: root_uuid, secrets: secrets_name}
  end

  defp human_player(name, ctx) do
    parent = self()
    output_fn = fn text -> send(parent, {:human, name, text}) end

    {:ok, session} =
      PlayerSession.start_link(
        player_name: name,
        root_uuid: ctx.root,
        store: ctx.store,
        output_fn: output_fn,
        owner_pid: parent
      )

    drain_human(name)
    session
  end

  defp drain_human(name) do
    receive do
      {:human, ^name, _} -> drain_human(name)
    after
      30 -> :ok
    end
  end

  test "bot.send_input spawns a session and returns the room render", ctx do
    {:ok, events} = Bot.send_input("bartleby", "look", store: ctx.store, root_uuid: ctx.root)
    text = Enum.join(events, "\n")
    assert text =~ "Start Room"
    assert text =~ "north"
  end

  test "bot session persists across calls; second send sees fewer events", ctx do
    {:ok, _greet_events} = Bot.send_input("bartleby", "look", store: ctx.store, root_uuid: ctx.root)
    {:ok, second} = Bot.send_input("bartleby", "look", store: ctx.store, root_uuid: ctx.root)
    text = Enum.join(second, "\n")
    assert text =~ "Start Room"
    # No greet event from a fresh session this time.
    refute text =~ "Welcome"
  end

  test "bot can walk the world and ends up in a different room", ctx do
    {:ok, _} = Bot.send_input("bartleby", "look", store: ctx.store, root_uuid: ctx.root)
    {:ok, events} = Bot.send_input("bartleby", "north", store: ctx.store, root_uuid: ctx.root)
    text = Enum.join(events, "\n")
    assert text =~ "Forest Path"
  end

  # CX-gq7a: "quit" stops the PlayerSession (replies :ok, then
  # `{:stop, :normal, ...}`); the settle-then-drain that
  # `Bot.send_input` always does lands against the now-dead pid.
  # `GenServer.call` there raises `:noproc` — this must be reported as
  # a clean disconnect, NOT bubble up as a crash (which the MCP layer
  # used to mis-blame on CommitStore overload — CX-0nkq).
  test "quit stops the session cleanly — send_input reports a clean disconnect, not a crash",
       ctx do
    {:ok, _} = Bot.send_input("bartleby", "look", store: ctx.store, root_uuid: ctx.root)

    assert {:ok, events} = Bot.send_input("bartleby", "quit", store: ctx.store, root_uuid: ctx.root)
    text = Enum.join(events, "\n")
    assert text =~ "clean disconnect"
    refute text =~ "CommitStore"

    # The session really did stop; a subsequent send spawns a fresh one
    # rather than erroring against the dead pid.
    assert {:ok, fresh_events} =
             Bot.send_input("bartleby", "look", store: ctx.store, root_uuid: ctx.root)

    assert Enum.join(fresh_events, "\n") =~ "Start Room"
  end

  # CX-nf8p R4 (never-queue): an over-rate command must be REJECTED at the
  # entry point and NEVER reach the PlayerSession mailbox. We spawn + spend
  # the (tiny) burst on a first command, then fire a distinctive command
  # that must be dropped — proving it never executed by asserting its
  # payload never comes back as a world event.
  test "R4: an over-rate bot command is dropped and never reaches the session (reject-before-enqueue)",
       ctx do
    old = Application.get_env(:commonplace, :mud_rate_limit)

    on_exit(fn ->
      if is_nil(old),
        do: Application.delete_env(:commonplace, :mud_rate_limit),
        else: Application.put_env(:commonplace, :mud_rate_limit, old)
    end)

    # Burst of 1, ~no refill within the test; principal scope disabled.
    Application.put_env(:commonplace, :mud_rate_limit,
      session_rate: 1,
      session_burst: 1,
      principal_rate: 1,
      principal_burst: 1_000_000,
      disconnect_after_drops: 1_000
    )

    # First command spends the single burst token (spawns the session).
    {:ok, _} = Bot.send_input("bartleby", "look", store: ctx.store, root_uuid: ctx.root)

    # Second command is over-rate → dropped. Its distinctive payload must
    # NOT be echoed back (would mean `say` ran = it reached the session).
    {:ok, events} =
      Bot.send_input("bartleby", "say ZZZ_NEVER_REACHED_ZZZ", store: ctx.store, root_uuid: ctx.root)

    text = Enum.join(events, "\n")
    assert text =~ "rate limited"
    refute text =~ "ZZZ_NEVER_REACHED_ZZZ"
  end

  test "bot hears human player's say", ctx do
    {:ok, _} = Bot.send_input("bartleby", "look", store: ctx.store, root_uuid: ctx.root)
    alice = human_player("alice", ctx)
    PlayerSession.input_sync(alice, "say hello bartleby")
    Process.sleep(80)

    {:ok, events} = Bot.read_events("bartleby")
    text = Enum.join(events, "\n")
    assert text =~ "alice says, \"hello bartleby\""

    PlayerSession.stop(alice)
  end

  test "bot's say is heard by a human player in the same room", ctx do
    alice = human_player("alice", ctx)
    {:ok, _} = Bot.send_input("bartleby", "look", store: ctx.store, root_uuid: ctx.root)

    # Drain alice's mailbox first
    drain_human("alice")

    {:ok, _} = Bot.send_input("bartleby", "say hi alice", store: ctx.store, root_uuid: ctx.root)
    Process.sleep(80)

    received =
      Stream.repeatedly(fn ->
        receive do
          {:human, "alice", text} -> text
        after
          50 -> nil
        end
      end)
      |> Stream.take_while(& &1)
      |> Enum.to_list()
      |> Enum.join("\n")

    assert received =~ "bartleby says, \"hi alice\""

    PlayerSession.stop(alice)
  end

  test "bot can take an object and see it in inventory", ctx do
    {:ok, _} = Bot.send_input("bartleby", "look", store: ctx.store, root_uuid: ctx.root)
    {:ok, take_events} = Bot.send_input("bartleby", "take cloak", store: ctx.store, root_uuid: ctx.root)
    take_text = Enum.join(take_events, "\n")
    assert take_text =~ "You take cloak"

    {:ok, inv_events} = Bot.send_input("bartleby", "inventory", store: ctx.store, root_uuid: ctx.root)
    inv_text = Enum.join(inv_events, "\n")
    assert inv_text =~ "cloak"
  end

  describe "CX-5plk: per-bot signing identity" do
    test "a bot session's writes are signed with the bot's own resolved identity", ctx do
      {:ok, _} =
        Bot.send_input("scribe", "look", store: ctx.store, root_uuid: ctx.root, secret_store: ctx.secrets)

      pid = :global.whereis_name({Bot, "scribe"})
      assert is_pid(pid)
      state = :sys.get_state(pid)

      # The session resolved a real signing context (not the pre-CX-5plk
      # nil/unsigned default).
      assert %Commonplace.Crypto.SigningContext{} = state.signing_context
      assert is_binary(state.signer_id)

      # It's the BOT's identity — a `:bot` cold identity registered under
      # the bot's own name, not some other principal.
      assert {:ok, identity_uuid} = Identity.lookup("scribe", :bot, ctx.root, ctx.store)
      assert {:ok, pub} = AgentKeys.ensure(identity_uuid, ctx.secrets)
      assert state.signer_id == Signing.signer_id(identity_uuid, pub)

      # Store-level: the player-dir commit created at bootstrap actually
      # carries that signer, not just the in-memory session state.
      assert {:ok, dir_head} = CommitStore.latest_commit(ctx.store, state.player_dir_uuid)
      assert dir_head.signer_id == state.signer_id
    end

    test "same bot name resolves to the same identity/key across calls and a session restart", ctx do
      {:ok, _} =
        Bot.send_input("dup", "look", store: ctx.store, root_uuid: ctx.root, secret_store: ctx.secrets)

      pid1 = :global.whereis_name({Bot, "dup"})
      state1 = :sys.get_state(pid1)
      assert is_binary(state1.signer_id)

      # Second send_input reuses the SAME live session (same pid), same
      # signer.
      {:ok, _} =
        Bot.send_input("dup", "look", store: ctx.store, root_uuid: ctx.root, secret_store: ctx.secrets)

      assert :global.whereis_name({Bot, "dup"}) == pid1
      assert :sys.get_state(pid1).signer_id == state1.signer_id

      assert {:ok, identity_uuid} = Identity.lookup("dup", :bot, ctx.root, ctx.store)
      assert {:ok, pub_before} = AgentKeys.ensure(identity_uuid, ctx.secrets)

      # Restart: stop the session outright, then spawn a fresh one for
      # the same name — idempotent registration must resolve the SAME
      # identity_uuid and the SAME keypair (no re-mint).
      Bot.stop("dup")
      wait_until(fn -> :global.whereis_name({Bot, "dup"}) == :undefined end)

      {:ok, _} =
        Bot.send_input("dup", "look", store: ctx.store, root_uuid: ctx.root, secret_store: ctx.secrets)

      pid2 = :global.whereis_name({Bot, "dup"})
      assert is_pid(pid2)
      assert pid2 != pid1

      state2 = :sys.get_state(pid2)
      assert state2.signer_id == state1.signer_id

      assert {:ok, ^identity_uuid} = Identity.lookup("dup", :bot, ctx.root, ctx.store)
      assert {:ok, ^pub_before} = AgentKeys.ensure(identity_uuid, ctx.secrets)
    end

    test "permissive-node path is unaffected: a bot with no secret_store override still lands writes", ctx do
      # No `secret_store:` opt — resolves against the app's global
      # SecretStore, same as production. Permissive workspaces (no
      # trust config set, as in this test's environment) don't gate on
      # signed-vs-unsigned, so the bot's writes land exactly as they did
      # before CX-5plk.
      {:ok, events} = Bot.send_input("watcher", "look", store: ctx.store, root_uuid: ctx.root)
      text = Enum.join(events, "\n")
      assert text =~ "Start Room"

      {:ok, take_events} = Bot.send_input("watcher", "take cloak", store: ctx.store, root_uuid: ctx.root)
      assert Enum.join(take_events, "\n") =~ "You take cloak"
    end
  end

  describe "CX-z0v7: unified session cap" do
    test "a bot spawn is refused once the cap is exhausted, and no session is registered", ctx do
      prior = Application.get_env(:commonplace, :mud_session_limit, [])
      Application.put_env(:commonplace, :mud_session_limit, max_total: 0, max_per_principal: 0)

      on_exit(fn ->
        if prior == [] do
          Application.delete_env(:commonplace, :mud_session_limit)
        else
          Application.put_env(:commonplace, :mud_session_limit, prior)
        end
      end)

      assert {:error, :session_limit} =
               Bot.send_input("capped", "look", store: ctx.store, root_uuid: ctx.root)

      assert :undefined = :global.whereis_name({Bot, "capped"})
    end
  end

  defp wait_until(fun, tries \\ 50)
  defp wait_until(_fun, 0), do: flunk("condition never became true")

  defp wait_until(fun, tries) do
    if fun.() do
      :ok
    else
      Process.sleep(20)
      wait_until(fun, tries - 1)
    end
  end
end
