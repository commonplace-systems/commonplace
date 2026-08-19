defmodule Commonplace.Green.BursarEnforcePersistTest do
  @moduledoc """
  Incident 2026-07-12 regression: under `local_write_gate: :enforce` the Bursar's
  OWN durable writes to `__bursar.json` / `__bursar.log` were UNSIGNED →
  `{:trust_rejected, :unsigned}` → a retry-loop of denials + tokens never
  persisting durably. Live-state (a REAL Bursar, not a mock) — the class the
  green 516/0 suite missed because it never asserted the persist COMMIT landed.

  PIN 1: a permanent-token acquire under enforce triggers persist_state → the
  `__bursar.json` write must land NODE-SIGNED (the Bursar signs as the node), not
  be denied. PIN 2: a DOWN Bursar must NOT crash a `take` — it surfaces a graceful
  refusal (the case_clause that took the session down mid-take is closed).
  """
  use ExUnit.Case, async: false

  alias Commonplace.Crypto.{NodeIdentity, Signing}
  alias Commonplace.Green.{Bursar, BursarClient}
  alias Commonplace.MUD.{Schemas, Take}
  alias Commonplace.MUD.Schemas.{Object, Room}
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.Schema

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_bursar_enf_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    n = :rand.uniform(1_000_000_000)
    store = :"bursar_enf_store_#{n}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: dir,
       name: :"bursar_enf_sup_#{n}",
       commit_store_name: store,
       trust_side_store_name: :"bursar_enf_tss_#{n}",
       pending_imports_name: :"bursar_enf_pi_#{n}"}
    )

    old_data_dir = Application.get_env(:commonplace, :data_dir)
    old_trust = Application.get_env(:commonplace, :trust)
    old_knob = Application.get_env(:commonplace, :local_write_gate)
    Application.put_env(:commonplace, :data_dir, dir)
    Application.put_env(:commonplace, :trust, %{accept_unsigned: false, trusted_identities: %{}})
    Application.put_env(:commonplace, :local_write_gate, :enforce)

    on_exit(fn ->
      restore = fn key, v ->
        if is_nil(v),
          do: Application.delete_env(:commonplace, key),
          else: Application.put_env(:commonplace, key, v)
      end

      restore.(:data_dir, old_data_dir)
      restore.(:trust, old_trust)
      restore.(:local_write_gate, old_knob)
      File.rm_rf!(dir)
    end)

    {:ok, node_ctx} = NodeIdentity.signing_context()
    {:ok, node_identity} = NodeIdentity.identity()

    {:ok, root} = Schemas.create_dir_with_meta(nil, nil, store, signing_context: node_ctx)

    case GenServer.whereis(Bursar) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end

    {:ok, bursar_pid} = Bursar.start_link(root_uuid: root, store: store, sweep_interval: 60_000)

    on_exit(fn ->
      if Process.alive?(bursar_pid),
        do:
          (try do
             GenServer.stop(bursar_pid)
           catch
             (:exit, _ -> :ok)
           end)
    end)

    %{
      store: store,
      node_ctx: node_ctx,
      node_identity: node_identity,
      root: root,
      bursar_pid: bursar_pid
    }
  end

  defp signer_of(store, uuid) do
    {:ok, commit} = CommitStoreClient.latest_commit(store, uuid)

    case Signing.parse_signer_id(commit.signer_id || "") do
      {:ok, id, _} -> id
      _ -> nil
    end
  end

  defp doc_uuid(store, root, name) do
    {:ok, schema} = Schemas.load_dir_schema(root, store)
    {:ok, entry} = Schema.get_entry(schema, name)
    entry.node_id
  end

  test "PIN 1: a permanent-token acquire under enforce persists __bursar.json NODE-SIGNED (not unsigned-denied)",
       %{store: store, node_identity: node_identity, root: root} do
    item = UUID.uuid4()

    # A PERMANENT (ttl:nil) token — the durable ownership kind that triggers a
    # persist_state write to __bursar.json.
    assert {:ok, _} =
             BursarClient.acquire(Bursar, item, node_identity,
               authenticated_as: node_identity,
               ttl: nil
             )

    # The Bursar survived (would be down if the write had crashed it) and the
    # token is queryable.
    assert {:held, %{holder: ^node_identity}} = BursarClient.query(Bursar, item)

    # __bursar.json (the DURABLE token table) landed NODE-SIGNED — the fix.
    # Pre-fix this write was unsigned → {:trust_rejected, :unsigned} under enforce,
    # so the durable ownership table never persisted.
    assert signer_of(store, doc_uuid(store, root, "__bursar.json")) == node_identity

    # __bursar.log (the audit trail) is DELIBERATELY left unsigned: it logs EVERY
    # op (incl. the 1Hz ephemeral tick-lease), so signing it would re-land ~86k
    # append-only entries/day — the CX-i9ca/sqyc churn that OOM-crashed the
    # dogfood serve. Its unsigned write being denied under enforce is a tolerated
    # no-op (log_event ignores the result). Only the DURABLE json is signed.
  end

  test "PIN 2: a DOWN Bursar surfaces a graceful refusal on take — never a case_clause crash",
       %{
         store: store,
         node_ctx: node_ctx,
         node_identity: node_identity,
         root: root,
         bursar_pid: bursar_pid
       } do
    # A curated object in a shared room, node inventory.
    {:ok, room} =
      Schemas.create_dir_with_meta(
        Schemas.room_filename(),
        Schemas.encode_room(%Room{name: "Hall", description: "x"}),
        store,
        signing_context: node_ctx
      )

    {:ok, item} =
      Schemas.create_dir_with_meta(
        Schemas.object_filename(),
        Schemas.encode_object(%Object{name: "gong"}),
        store,
        signing_context: node_ctx
      )

    {:ok, inventory} = Schemas.create_dir_with_meta(nil, nil, store, signing_context: node_ctx)

    for {parent, name, child} <- [{root, "hall", room}, {room, "gong.obj", item}] do
      {:ok, schema} = Schemas.load_dir_schema(parent, store)
      schema = Schema.add_directory(schema, name, child)

      {metadata, opts} =
        Commonplace.MUD.SignedWrite.opts_for(parent, store: store, signing_context: node_ctx)

      _ =
        CommitStoreClient.create_chained_commit(
          store,
          parent,
          Yelixer.Encoding.encode_update(schema),
          metadata,
          opts
        )
    end

    _ = node_identity

    # Take the Bursar DOWN, then take → BursarClient returns :bursar_unavailable.
    GenServer.stop(bursar_pid)
    assert {:error, :bursar_unavailable} = BursarClient.query(Bursar, item)

    # Take must NOT crash (pre-fix: case_clause in ensure_node_holds). It returns
    # a graceful error tuple.
    result =
      try do
        Take.take(item, "gong.obj", room, inventory, node_identity, store: store, root_uuid: root)
      rescue
        e -> {:raised, e}
      catch
        k, v -> {:caught, k, v}
      end

    assert match?({:error, _}, result),
           "a down Bursar must give a graceful error, got: #{inspect(result)}"
  end
end
