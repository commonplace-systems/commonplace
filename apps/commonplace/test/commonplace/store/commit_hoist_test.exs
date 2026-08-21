defmodule Commonplace.Store.CommitHoistTest do
  @moduledoc """
  CX-3erd: tests for the caller-side hoisted build+sign write path.

  Before this bead, `CommitStoreClient.create_commit/6` and
  `create_chained_commit/5` (local mode) delegated the ENTIRE
  build+sign pipeline to `CommitStore`'s serialized `handle_call`.
  After this bead, the client reads `:latest`, builds+signs via
  `Commonplace.Store.CommitBuilder.build/6` in its OWN process, and
  lands the result with `CommitStore.put_built_commit/4` (a CAS'd
  verb) — retrying (bounded) on `{:error, :parent_moved}` and falling
  back to the retained legacy serialized verb after exhaustion.

  These tests pin:

    1. The CX-l7j invariant (linear chain under concurrency) still
       holds through the new CAS-based mechanism, plus the CAS
       primitive itself.
    2. `snapshot_parent` inheritance parity between the hoisted and
       legacy paths.
    3. The CX-m3x legacy nil-parent hatch survives the hoist.
    4. The genesis race resolves to exactly one genesis row.
    5. Signing parity (explicit context, ambient fallback + telemetry,
       `:unsigned`).
    6. Retry-exhaustion falls back to the legacy serialized verb.
    7. `import_commit`'s id-verification gate now runs at the client
       edge in local mode.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Store.{Commit, CommitStore, CommitStoreClient, SecretStore}
  alias Commonplace.Crypto.{Signing, SigningContext}

  setup do
    dir = Path.join(System.tmp_dir!(), "cx3erd_hoist_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    name = :"cx3erd_store_#{:rand.uniform(1_000_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: name})
    on_exit(fn -> File.rm_rf!(dir) end)
    %{store: name}
  end

  # Walks parent chain from head, stopping at (and excluding) the
  # auto-stamped `:genesis` commit so assertions count only the
  # caller-written commits — mirrors ConcurrentChainedCommitTest.
  defp walk_chain(store, from_id), do: walk_chain(store, from_id, [])
  defp walk_chain(_store, nil, acc), do: Enum.reverse(acc)

  defp walk_chain(store, id, acc) do
    case CommitStore.get_commit(store, id) do
      {:ok, %{metadata: %{kind: :genesis}}} -> Enum.reverse(acc)
      {:ok, commit} -> walk_chain(store, commit.parent_id, [commit.id | acc])
      :none -> Enum.reverse(acc)
    end
  end

  defp attach(event) do
    test_pid = self()
    ref = make_ref()

    :telemetry.attach(
      "#{inspect(event)}-#{inspect(ref)}",
      event,
      fn ^event, measurements, metadata, _config ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach("#{inspect(event)}-#{inspect(ref)}") end)
  end

  describe "CX-l7j CAS pin via the hoisted path" do
    test "N concurrent create_chained_commit callers all succeed, all commits persisted, chain is linear",
         %{store: store} do
      uuid = "hoist-concurrent"
      n = 40

      tasks =
        for i <- 1..n do
          Task.async(fn ->
            CommitStoreClient.create_chained_commit(store, uuid, <<i::32>>, %{})
          end)
        end

      # CX-5gkw: keep this 10 s await. Even if every one of 40 callers uses all
      # five bounded CAS attempts, this is at most 200 write attempts, 15x less
      # work than CX-qzbh's measured 3,000-write hammer (9.9-13.9 s). A linear
      # projection is below 1 s, leaving over 10x headroom here.
      commits = Task.await_many(tasks, 10_000)

      ids = MapSet.new(commits, & &1.id)
      assert MapSet.size(ids) == n, "duplicate commit ids suggest lost writes"

      {:ok, head} = CommitStore.latest_commit(store, uuid)
      chain = walk_chain(store, head.id)
      chain_ids = MapSet.new(chain)

      assert MapSet.size(MapSet.difference(ids, chain_ids)) == 0,
             "some concurrent writes are siblings unreachable from :latest"

      assert length(chain) == n,
             "expected #{n}-long linear chain, got #{length(chain)}"

      # Strict linearity: every commit's parent is unique (no shared parents).
      parents =
        Enum.map(chain, fn id ->
          {:ok, c} = CommitStore.get_commit(store, id)
          c.parent_id
        end)

      assert Enum.uniq(parents) == parents
    end

    test "put_built_commit direct CAS: stale expected_parent_id rejects and writes nothing", %{
      store: store
    } do
      c1 = CommitStoreClient.create_commit(store, "cas-direct", <<1>>, nil)
      {:ok, latest_before} = CommitStore.latest_commit(store, "cas-direct")

      candidate = Commit.new("cas-direct", <<2>>, c1.id, %{})

      # Deliberately stale: current :latest is c1.id, not nil.
      assert {:error, :parent_moved} = CommitStore.put_built_commit(store, candidate, nil, nil)

      {:ok, latest_after} = CommitStore.latest_commit(store, "cas-direct")
      assert latest_after.id == latest_before.id
      assert :none = CommitStore.get_commit(store, candidate.id)
    end
  end

  describe "snapshot_parent inheritance parity (CX-a04)" do
    test "hoisted create_chained_commit stamps the same snapshot_parent shape as the legacy server verb",
         %{store: store} do
      uuid_hoisted = "parity-hoisted"
      uuid_legacy = "parity-legacy"

      # Build the identical scenario on two docs: a :regular root, then a
      # snapshot, then a subsequent :regular commit that must inherit
      # snapshot_parent = snapshot.id.
      _root_h = CommitStore.create_commit(store, uuid_hoisted, <<1>>, nil, %{kind: :regular})
      snap_h = CommitStore.create_snapshot_commit(store, uuid_hoisted, <<9>>)

      reg_h =
        CommitStoreClient.create_chained_commit(store, uuid_hoisted, <<2>>, %{kind: :regular})

      _root_l = CommitStore.create_commit(store, uuid_legacy, <<1>>, nil, %{kind: :regular})
      snap_l = CommitStore.create_snapshot_commit(store, uuid_legacy, <<9>>)
      reg_l = CommitStore.create_chained_commit(store, uuid_legacy, <<2>>, %{kind: :regular})

      assert reg_h.metadata[:snapshot_parent] == snap_h.id
      assert reg_l.metadata[:snapshot_parent] == snap_l.id

      # Parity: same metadata SHAPE (kind + presence of snapshot_parent),
      # modulo the doc-specific snapshot id itself.
      assert Map.delete(reg_h.metadata, :snapshot_parent) ==
               Map.delete(reg_l.metadata, :snapshot_parent)
    end

    test "hoisted create_commit on a fresh doc stamps snapshot_parent = genesis.id, matching legacy",
         %{store: store} do
      uuid_hoisted = "parity-genesis-hoisted"
      uuid_legacy = "parity-genesis-legacy"

      hoisted =
        CommitStoreClient.create_commit(store, uuid_hoisted, <<1>>, nil, %{kind: :regular})

      legacy = CommitStore.create_commit(store, uuid_legacy, <<1>>, nil, %{kind: :regular})

      assert hoisted.metadata[:snapshot_parent] == Commit.genesis(uuid_hoisted).id
      assert legacy.metadata[:snapshot_parent] == Commit.genesis(uuid_legacy).id

      assert Map.delete(hoisted.metadata, :snapshot_parent) ==
               Map.delete(legacy.metadata, :snapshot_parent)
    end
  end

  describe "legacy nil-parent hatch parity (CX-m3x)" do
    test "pre-umbrella doc with existing :latest keeps nil parent through the hoisted create_commit path",
         %{store: store} do
      uuid = "hoist-legacy-hatch"

      legacy = Commit.new(uuid, <<7>>, nil, %{})
      :ok = CommitStore.import_commit(store, legacy)
      :ok = CommitStore.set_latest(store, uuid, legacy.id)

      # Hoisted path, parent_id = nil, on a doc that already has :latest.
      new_commit = CommitStoreClient.create_commit(store, uuid, <<8>>, nil)
      assert new_commit.parent_id == nil

      genesis_id = Commit.genesis(uuid).id
      assert :none = CommitStore.get_commit(store, genesis_id)
    end
  end

  describe "genesis race (CX-m3x, hoisted path)" do
    test "two concurrent first-writers on a fresh doc: exactly one genesis row, loser retries chained",
         %{store: store} do
      uuid = "hoist-genesis-race"

      tasks =
        for i <- 1..2 do
          Task.async(fn ->
            CommitStoreClient.create_chained_commit(store, uuid, <<i::32>>, %{})
          end)
        end

      [c1, c2] = Task.await_many(tasks, 5_000)

      genesis_id = Commit.genesis(uuid).id
      assert {:ok, genesis} = CommitStore.get_commit(store, genesis_id)
      assert genesis.metadata == %{kind: :genesis, doc_uuid: uuid}

      ids = MapSet.new([c1.id, c2.id])
      assert MapSet.size(ids) == 2, "both writers should land distinct commits"

      {:ok, head} = CommitStore.latest_commit(store, uuid)
      chain = walk_chain(store, head.id)
      assert length(chain) == 2
      assert MapSet.new(chain) == ids

      # Exactly one of the two chains directly off genesis.
      parents_of_chain =
        Enum.map(chain, fn id ->
          {:ok, c} = CommitStore.get_commit(store, id)
          c.parent_id
        end)

      assert Enum.count(parents_of_chain, &(&1 == genesis_id)) == 1
    end
  end

  describe "signing parity (CX-hoj, hoisted path)" do
    test "explicit signing_context signs via the hoisted create_commit path", %{store: store} do
      {pub, priv} = Signing.generate_keypair()
      ctx = %SigningContext{identity_uuid: "agent-1", private_key: priv, public_key: pub}

      commit =
        CommitStoreClient.create_commit(store, "sign-explicit", <<1>>, nil, %{kind: :regular},
          signing_context: ctx
        )

      assert commit.signature != nil
      assert commit.signer_id == Signing.signer_id("agent-1", pub)
      assert :ok = Signing.verify_commit(commit, pub)
    end

    test "nil signing_context + global key loaded ambient-signs and fires telemetry from the hoisted path",
         %{store: store} do
      {gpub, gpriv} = Signing.generate_keypair()
      SecretStore.set("signing_key:default", Base.encode64(gpriv))
      SecretStore.set("signing_pub:default", Base.encode64(gpub))
      SecretStore.set("signing_identity", "human-uuid")

      on_exit(fn ->
        SecretStore.delete("signing_key:default")
        SecretStore.delete("signing_pub:default")
        SecretStore.delete("signing_identity")
      end)

      attach([:commonplace, :commit, :ambient_signed])

      uuid = "sign-ambient"
      commit = CommitStoreClient.create_commit(store, uuid, <<1>>, nil, %{kind: :regular})

      assert commit.signature != nil
      assert :ok = Signing.verify_commit(commit, gpub)

      assert_receive {:telemetry, [:commonplace, :commit, :ambient_signed], _meas, metadata}
      assert metadata.doc_uuid == uuid
      assert metadata.commit_id == commit.id
    end

    test ":unsigned always yields an unsigned commit via the hoisted path, even with a global key loaded",
         %{store: store} do
      {gpub, gpriv} = Signing.generate_keypair()
      SecretStore.set("signing_key:default", Base.encode64(gpriv))
      SecretStore.set("signing_pub:default", Base.encode64(gpub))

      on_exit(fn ->
        SecretStore.delete("signing_key:default")
        SecretStore.delete("signing_pub:default")
      end)

      attach([:commonplace, :commit, :ambient_signed])

      uuid = "sign-unsigned"

      commit =
        CommitStoreClient.create_commit(store, uuid, <<1>>, nil, %{kind: :regular},
          signing_context: :unsigned
        )

      assert commit.signature == nil
      assert commit.signer_id == nil

      # Scope the refute to THIS test's doc: the telemetry event is
      # node-global, and under a concurrent full-suite run another test's
      # ambient-signed commit otherwise lands in this mailbox and trips
      # the refute (observed on CI 32491781016, a foreign random-uuid doc —
      # the SAME class 6de68b15 fixed in ambient_signing_telemetry_test;
      # this was the missed sibling instance).
      refute_receive {:telemetry, [:commonplace, :commit, :ambient_signed], _,
                      %{doc_uuid: ^uuid}},
                     100
    end
  end

  describe "retry-exhaustion fallback" do
    test "sustained CAS contention exhausts retries and falls back to the legacy serialized verb",
         %{store: store} do
      uuid = "hoist-retry-exhaustion"

      # Seed :latest so the client's build resolves a non-nil parent (avoids
      # genesis special-casing muddying the picture).
      seed = CommitStoreClient.create_commit(store, uuid, <<0>>, nil)

      # Hammer :latest with a raw (non-CAS) writer running concurrently, so
      # by the time the hoisted path's CAS reaches the server, :latest has
      # almost certainly moved out from under every one of its
      # @max_chain_attempts (5) attempts — forcing exhaustion and driving
      # the fallback to CommitStore.create_chained_commit/5 (observable via
      # the CX-9hql :call telemetry's verb tag).
      hammer =
        Task.async(fn ->
          for i <- 1..3000 do
            CommitStore.set_latest(store, uuid, Commit.new(uuid, <<i::32>>, seed.id, %{}).id)
          end
        end)

      attach([:commonplace, :commit_store, :call])

      commit = CommitStoreClient.create_chained_commit(store, uuid, <<99>>, %{})

      # CX-5gkw: CX-qzbh measured this exact 3,000-write hammer at 9.9-13.9 s,
      # so 10 s sits inside its workload distribution. A 30 s await is over
      # 2x the measured maximum while remaining a finite hang detector. The
      # containing test keeps its 60 s timeout, over 4x that maximum. This does
      # NOT mask fallback failure: the commit and telemetry assertions below
      # remain byte-for-byte unchanged and independent of elapsed time.
      Task.await(hammer, 30_000)

      assert commit.doc_uuid == uuid

      assert_receive {:telemetry, [:commonplace, :commit_store, :call], _meas,
                      %{verb: :create_chained_commit}},
                     2_000
    end
  end

  describe "write_cpu site tagging (CX-3erd follow-up)" do
    test "hoisted create_chained_commit emits caller-side write_cpu with site: :caller and build > 0",
         %{store: store} do
      attach([:commonplace, :commit_store, :write_cpu])

      uuid = "hoist-write-cpu-caller"
      commit = CommitStoreClient.create_chained_commit(store, uuid, <<1>>, %{})
      assert commit.doc_uuid == uuid

      assert_receive {:telemetry, [:commonplace, :commit_store, :write_cpu], meas,
                      %{site: :caller} = meta}

      assert meta.verb == :create_chained_commit
      assert meta.doc_uuid == uuid
      assert meas.build > 0
      # The caller never persists — that phase belongs to the server's
      # :put_built_commit event.
      assert meas.persist == 0
      assert meas.validate == 0
    end

    test "the server-side :put_built_commit event carries site: :server with build == 0",
         %{store: store} do
      attach([:commonplace, :commit_store, :write_cpu])

      uuid = "hoist-write-cpu-server"
      _commit = CommitStoreClient.create_chained_commit(store, uuid, <<1>>, %{})

      assert_receive {:telemetry, [:commonplace, :commit_store, :write_cpu], meas,
                      %{verb: :put_built_commit} = meta}

      assert meta.site == :server
      assert meta.doc_uuid == uuid
      assert meas.build == 0
      assert meas.sign == 0
      assert meas.persist > 0
    end
  end

  describe "import_commit verify_id-at-the-edge (CX-3erd / CX-gwz)" do
    test "local-mode import of an id-tampered commit rejects without reaching the server, telemetry still fires",
         %{store: store} do
      good = CommitStoreClient.create_commit(store, "tamper-victim", <<1>>, nil)
      tampered = %{good | update: <<99>>}

      attach([:commonplace, :commit_store, :call])
      attach([:commonplace, :commit, :rejected, :id_mismatch])

      assert {:error, {:id_mismatch, _computed, claimed}} =
               CommitStoreClient.import_commit(store, tampered)

      assert claimed == good.id

      assert_receive {:telemetry, [:commonplace, :commit, :rejected, :id_mismatch], _meas, meta}
      assert meta.doc_uuid == "tamper-victim"

      refute_receive {:telemetry, [:commonplace, :commit_store, :call], _,
                      %{verb: :import_commit}},
                     200
    end

    test "local-mode import of a valid commit still reaches the server and succeeds", %{
      store: store
    } do
      good = CommitStoreClient.create_commit(store, "tamper-safe", <<1>>, nil)
      other = Commit.new("tamper-safe-2", <<2>>, nil, %{})

      assert :ok = CommitStoreClient.import_commit(store, other)
      assert {:ok, fetched} = CommitStore.get_commit(store, other.id)
      assert fetched.id == other.id
      # sanity: the earlier commit is untouched
      assert {:ok, _} = CommitStore.get_commit(store, good.id)
    end
  end
end
