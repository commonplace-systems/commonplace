defmodule Commonplace.SnapshotCompactTest do
  use ExUnit.Case, async: false

  alias Commonplace.Crypto.{NodeIdentity, Signing}
  alias Commonplace.SnapshotCompact
  alias Commonplace.Store.CommitStore
  alias Yelixer.{Doc, Encoding}
  alias Yelixer.Types.Text

  setup do
    dir = Path.join(System.tmp_dir!(), "snapshot_compact_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    store = :"snapshot_compact_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store})

    if Process.whereis(Commonplace.SnapshotWorker) == nil do
      start_supervised!(Commonplace.SnapshotWorker)
    end

    old_data_dir = Application.get_env(:commonplace, :data_dir)
    old_trust = Application.get_env(:commonplace, :trust)
    old_write_gate = Application.get_env(:commonplace, :local_write_gate)
    Application.put_env(:commonplace, :data_dir, dir)

    on_exit(fn ->
      restore_env(:data_dir, old_data_dir)
      restore_env(:trust, old_trust)
      restore_env(:local_write_gate, old_write_gate)
      File.rm_rf!(dir)
    end)

    %{store: store, dir: dir}
  end

  defp text_update(client_id, text) do
    doc = Doc.new(client_id: client_id)
    {doc, _type} = Doc.get_or_create_type(doc, "t", :text)
    doc = Text.insert(doc, "t", 0, text)
    Encoding.encode_update(doc)
  end

  defp seed_chain(store, uuid, count, opts \\ []) do
    for i <- 1..count do
      CommitStore.create_chained_commit(
        store,
        uuid,
        text_update(i, "c#{i}"),
        %{kind: :regular},
        opts
      )
    end
  end

  defp row_count(store) do
    store
    |> CommitStore.db_handle()
    |> CubDB.select()
    |> Enum.count()
  end

  test "deep pure chain: census, destination-counted execute, immediate noop rerun", %{
    store: store
  } do
    seed_chain(store, "deep", 6)
    seed_chain(store, "tiny", 2)

    dry = SnapshotCompact.run(:dry_run, store, threshold: 5)
    dry_text = SnapshotCompact.format(dry)
    IO.puts("RED PROOF 1A — CENSUS\n" <> dry_text)

    assert dry.ok?
    assert Enum.map(dry.census.work, & &1.uuid) == ["deep"]
    assert dry.census.total == 2
    assert dry.census.accounted == 2

    rows_before = row_count(store)
    execute = SnapshotCompact.run(:execute, store, threshold: 5)
    rows_after = row_count(store)
    execute_text = SnapshotCompact.format(execute)

    IO.puts(
      "RED PROOF 1B — EXECUTE\n" <>
        execute_text <>
        "destination rows: before=#{rows_before} after=#{rows_after} delta=#{rows_after - rows_before}"
    )

    assert execute.ok?
    assert execute.execution.snapshotted == 1
    assert execute.acceptance.unaccounted == []
    assert rows_after == rows_before + 1

    rerun = SnapshotCompact.run(:execute, store, threshold: 5)
    rerun_text = SnapshotCompact.format(rerun)
    IO.puts("RED PROOF 1C — IMMEDIATE RERUN\n" <> rerun_text)

    assert rerun.ok?
    assert rerun.census.work == []
    assert rerun.execution.outcomes == []
    assert row_count(store) == rows_after
  end

  test "a post-trim chain exactly at the limit is bounded", %{store: store} do
    seed_chain(store, "at-limit", 5)

    report = SnapshotCompact.run(:dry_run, store, threshold: 5)

    assert report.ok?
    assert report.census.work == []
    assert Enum.map(report.census.noop, & &1.uuid) == ["at-limit"]
  end

  test "unreadable doc is named and makes the incomplete denominator red", %{store: store} do
    seed_chain(store, "readable", 2)
    CommitStore.create_chained_commit(store, "unreadable", <<1, 2, 3>>, %{kind: :regular})

    report = SnapshotCompact.run(:dry_run, store, threshold: 5)
    incomplete = length(report.census.work) + length(report.census.noop)

    IO.puts(
      "RED PROOF 2 — UNREADABLE DENOMINATOR\n" <>
        SnapshotCompact.format(report) <>
        "incomplete identity: work + noop = total :: #{incomplete} = #{report.census.total} [BROKEN]"
    )

    assert report.ok?
    assert incomplete != report.census.total
    assert [%{uuid: "unreadable", reason: _named}] = report.census.unreadable
    assert report.census.accounted == report.census.total
  end

  test "enforce-mode sweep lands the existing node-signed snapshot", %{store: store} do
    {:ok, node_context} = NodeIdentity.signing_context()
    seed_chain(store, "strict-deep", 6, signing_context: node_context)

    {:ok, node_identity} = NodeIdentity.identity()

    Application.put_env(:commonplace, :trust, %{
      accept_unsigned: false,
      trusted_identities: %{}
    })

    Application.put_env(:commonplace, :local_write_gate, :enforce)

    report = SnapshotCompact.run(:execute, store, threshold: 5)
    {:ok, snapshot} = CommitStore.latest_commit(store, "strict-deep")

    IO.puts(
      "RED PROOF 3 — ENFORCE SIGNING\n" <>
        SnapshotCompact.format(report) <>
        "snapshot signer present: #{not is_nil(snapshot.signer_id)}\n" <>
        "snapshot signature present: #{not is_nil(snapshot.signature)}\n" <>
        "snapshot signer: #{snapshot.signer_id}"
    )

    assert report.ok?
    assert snapshot.metadata.kind == :snapshot
    assert snapshot.signer_id != nil
    assert snapshot.signature != nil
    assert {:ok, ^node_identity, _fingerprint} = Signing.parse_signer_id(snapshot.signer_id)
    assert :ok = Signing.verify_commit(snapshot, node_context.public_key)
  end

  test "driver has no direct store-opening escape hatch" do
    source = File.read!(Path.expand("../../../../bin/snapshot-compact", __DIR__))

    matches =
      Enum.filter(
        ["CubDB", "CommitStore", "Store.Supervisor", "data_dir"],
        &String.contains?(source, &1)
      )

    IO.puts(
      "RED PROOF 4 — STRUCTURAL\n" <>
        "forbidden direct-store references: #{inspect(matches)}\n" <>
        "serve RPC present: #{String.contains?(source, ":erpc.call")}"
    )

    assert matches == []
    assert source =~ ":erpc.call"
    assert source =~ "Commonplace.SnapshotCompact"
  end

  test "a red acceptance report prints unnamed shapes instead of crashing" do
    census = %{
      total: 1,
      work: [],
      noop: [],
      unreadable: [],
      snapshot_bounded_noop: [],
      distribution: [],
      worst: [],
      identity_ok?: true
    }

    report = %{
      mode: :execute,
      threshold: 5,
      census: census,
      execution: %{
        outcomes: [],
        snapshotted: 0,
        already_bounded: 0,
        refused: 0,
        identity_ok?: true
      },
      acceptance: %{
        total: 1,
        bounded: 0,
        named_refusals: [],
        unaccounted: [
          %{uuid: "still-deep", chain_length: 6, head_kind: :regular, snapshot_bounded?: false}
        ],
        denominator_stable?: true,
        identity_ok?: true
      },
      ok?: false
    }

    output = SnapshotCompact.format(report)

    assert output =~ "unaccounted:\n  still-deep"
    assert output =~ "destination verdict: BROKEN"
  end

  defp restore_env(key, nil), do: Application.delete_env(:commonplace, key)
  defp restore_env(key, value), do: Application.put_env(:commonplace, key, value)
end
