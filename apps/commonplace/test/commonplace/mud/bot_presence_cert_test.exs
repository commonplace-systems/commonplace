defmodule Commonplace.MUD.BotPresenceCertTest do
  @moduledoc """
  CX-0a9a (presence-carve, W7): `Bot.spawn_session/2` auto-issues its
  resolved identity a presence-starter capability cert (`{:write}` verbs,
  `{:presence, identity_uuid}` scope, issued by the node) and threads the
  cid into the `PlayerSession`'s `cert_cids`.

  Separate suite from `bot_test.exs` because cert issuance needs the
  FULL `Commonplace.Store.Supervisor` trio (`CommitStore` +
  `TrustSideStore`, for `store_capability/2` — see
  `Commonplace.Store.CommitStore.trust_side_store_name/1`'s moduledoc);
  `bot_test.exs` deliberately uses a bare `CommitStore` (no companion),
  under which `Bot`'s cert issuance degrades to `cert_cids: []` (asserted
  separately below) rather than crashing the spawn.
  """
  use ExUnit.Case

  alias Commonplace.Crypto.NodeIdentity
  alias Commonplace.MUD.{Bootstrap, Bot}
  alias Commonplace.Presence.Identity
  alias Commonplace.Store.{CommitStore, CommitStoreClient, SecretStore, Supervisor}
  alias Commonplace.Tree.Schema
  alias Yelixer.Encoding

  setup do
    Application.ensure_all_started(:phoenix_pubsub)

    case Phoenix.PubSub.Supervisor.start_link(name: Commonplace.PubSub) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    dir = Path.join(System.tmp_dir!(), "cp_mud_bot_cert_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    n = :rand.uniform(1_000_000)
    store = :"cp_mud_bot_cert_store_#{n}"

    start_supervised!(
      {Supervisor,
       data_dir: dir,
       name: :"cp_mud_bot_cert_sup_#{n}",
       commit_store_name: store,
       trust_side_store_name: :"cp_mud_bot_cert_tss_#{n}",
       pending_imports_name: :"cp_mud_bot_cert_pi_#{n}"}
    )

    on_exit(fn -> File.rm_rf!(dir) end)

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

    on_exit(fn ->
      if Process.alive?(bursar_pid),
        do:
          (try do
             GenServer.stop(bursar_pid)
           catch
             (:exit, _ -> :ok)
           end)
    end)

    root_uuid = UUID.uuid4()
    update = Encoding.encode_update(Schema.new_schema())
    CommitStore.create_commit(store, root_uuid, update, nil)
    {:ok, _} = Bootstrap.seed(root_uuid, store)

    secrets_dir =
      Path.join(System.tmp_dir!(), "cp_mud_bot_cert_secrets_#{:rand.uniform(1_000_000_000)}")

    File.mkdir_p!(secrets_dir)
    secrets_name = :"cp_mud_bot_cert_secrets_#{n}"
    {:ok, secrets_pid} = SecretStore.start_link(data_dir: secrets_dir, name: secrets_name)

    on_exit(fn ->
      Bot.stop("cert-bot")

      if Process.alive?(secrets_pid),
        do:
          (try do
             GenServer.stop(secrets_pid)
           catch
             (:exit, _ -> :ok)
           end)

      File.rm_rf!(secrets_dir)
    end)

    %{store: store, root: root_uuid, secrets: secrets_name}
  end

  test "spawn_session issues a presence-starter cert and threads it into cert_cids", ctx do
    {:ok, _events} =
      Bot.send_input("cert-bot", "look",
        store: ctx.store,
        root_uuid: ctx.root,
        secret_store: ctx.secrets
      )

    assert {:ok, pid} = bot_pid("cert-bot")
    state = :sys.get_state(pid)

    assert [cert_cid] = state.cert_cids
    assert is_binary(cert_cid)

    assert {:ok, identity_uuid} = Identity.lookup("cert-bot", :bot, ctx.root, ctx.store)

    assert {:ok, cap} = CommitStoreClient.get_capability(ctx.store, cert_cid)
    assert cap.claim.verbs == [:write]
    assert cap.claim.scope == {:presence, identity_uuid}
    assert {audience_uuid, _pub} = cap.audience
    assert audience_uuid == identity_uuid

    # Issued by the node.
    assert {:ok, node_identity} = NodeIdentity.identity()
    assert {issuer_uuid, _} = cap.issuer
    assert issuer_uuid == node_identity
  end

  test "re-spawning the same bot name re-issues the SAME cert cid (content-addressed idempotence)",
       ctx do
    {:ok, _} =
      Bot.send_input("cert-bot", "look",
        store: ctx.store,
        root_uuid: ctx.root,
        secret_store: ctx.secrets
      )

    assert {:ok, pid1} = bot_pid("cert-bot")
    [cid1] = :sys.get_state(pid1).cert_cids

    Bot.stop("cert-bot")

    {:ok, _} =
      Bot.send_input("cert-bot", "look",
        store: ctx.store,
        root_uuid: ctx.root,
        secret_store: ctx.secrets
      )

    assert {:ok, pid2} = bot_pid("cert-bot")
    assert pid2 != pid1
    [cid2] = :sys.get_state(pid2).cert_cids

    assert cid1 == cid2
  end

  test "on a store with no TrustSideStore companion, cert issuance degrades to [] without crashing the spawn" do
    # A bare CommitStore (no :trust_side_store companion) — the shape
    # `bot_test.exs`'s own suite uses. `store_capability/2` raises there;
    # `Bot.resolve_signing_opts/4`'s cert-issuance step must catch that
    # and degrade to `cert_cids: []`, exactly like the pre-existing
    # `register_agent` failure path — never let the spawn itself fail.
    dir = Path.join(System.tmp_dir!(), "cp_mud_bot_bare_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    bare_store = :"cp_mud_bot_bare_store_#{:rand.uniform(1_000_000)}"
    {:ok, bare_pid} = CommitStore.start_link(data_dir: dir, name: bare_store)

    root_uuid = UUID.uuid4()
    update = Encoding.encode_update(Schema.new_schema())
    CommitStore.create_commit(bare_store, root_uuid, update, nil)
    {:ok, _} = Bootstrap.seed(root_uuid, bare_store)

    case GenServer.whereis(Commonplace.Green.Bursar) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end

    {:ok, bursar_pid} =
      Commonplace.Green.Bursar.start_link(
        root_uuid: root_uuid,
        store: bare_store,
        sweep_interval: 60_000
      )

    {:ok, _events} = Bot.send_input("bare-bot", "look", store: bare_store, root_uuid: root_uuid)

    assert {:ok, pid} = bot_pid("bare-bot")
    assert :sys.get_state(pid).cert_cids == []

    Bot.stop("bare-bot")

    if Process.alive?(bursar_pid),
      do:
        (try do
           GenServer.stop(bursar_pid)
         catch
           (:exit, _ -> :ok)
         end)

    if Process.alive?(bare_pid),
      do:
        (try do
           GenServer.stop(bare_pid)
         catch
           (:exit, _ -> :ok)
         end)

    File.rm_rf!(dir)
  end

  # CX-2t8p: tight reproduction of the stale-Registry-entry race. Registry
  # unregisters a `{:via, Registry, ...}`-named process by monitoring it and
  # processing the resulting `:DOWN` — that happens in the Registry's OWN
  # process, asynchronously relative to `GenServer.stop/2`'s synchronous
  # return on the CALLER's side. So there's a window, right after
  # `Bot.stop/1` returns, where `Registry.lookup/2` can still hand back the
  # now-dead pid. `Bot.ensure_session/2` trusted that lookup unconditionally
  # (`bot.ex:184-186`), so `send_input`'s `PlayerSession.input_sync` call
  # (bot.ex:130, NOT wrapped in the `:noproc` catch that `drain/1` has) blew
  # up with `{:EXIT, {:noproc, _}}` against the stale pid — exactly the
  # observed CI failure. Looped tight (no sleep) to maximize the chance of
  # landing in that window every run.
  #
  # CX-5gkw: all 50 iterations perform session spawn, a write-bearing verb
  # round-trip, stop, and a write-bearing respawn round-trip. The inherited
  # 60 s limit budgets only 1.2 s/iteration and has expired mid-loop; 10x
  # per-iteration load headroom is 12 s x 50 = 600 s. This finite budget does
  # NOT mask the race: a real dead-pid hit still fails the in-loop assertion
  # immediately, regardless of the loop's total duration.
  @tag timeout: 600_000
  test "stop immediately followed by send_input never hits a dead session pid", ctx do
    Enum.each(1..50, fn i ->
      name = "respawn-race-bot"

      {:ok, _} =
        Bot.send_input(name, "look",
          store: ctx.store,
          root_uuid: ctx.root,
          secret_store: ctx.secrets
        )

      assert {:ok, pid} = bot_pid(name)
      Bot.stop(name)

      assert {:ok, _events} =
               Bot.send_input(name, "look",
                 store: ctx.store,
                 root_uuid: ctx.root,
                 secret_store: ctx.secrets
               ),
             "iteration #{i}: send_input crashed against a stale/dead session pid #{inspect(pid)}"
    end)

    Bot.stop("respawn-race-bot")
  end

  defp bot_pid(name) do
    case Registry.lookup(Commonplace.MUD.BotRegistry, name) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  end
end
