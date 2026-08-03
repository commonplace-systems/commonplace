defmodule Commonplace.Trust.PagedAuthorizationWalkTest do
  @moduledoc """
  CX-klpi held half: pins the paged Gate B (`Trust.authorized_to_execute?/4`)
  and `:define_verb` (`DefineVerbGate.authorized_to_define?/5`) walks —
  multi-page clean chains agree with a single-page walk, an incomplete
  chain (missing mid-chain commit) fails closed with
  `{:authorization_chain_incomplete, _}`, a runaway chain fails closed
  with `{:authorization_chain_too_long, _}` under a small ceiling, and
  the execute-clean snapshot cache still halts the walk early across a
  page boundary.
  """
  use ExUnit.Case, async: false
  require Logger

  alias Commonplace.Crypto.{Signing, SigningContext}
  alias Commonplace.Document.ContentType
  alias Commonplace.Store.{CommitStore, CommitStoreClient}
  alias Commonplace.Trust
  alias Commonplace.Trust.DefineVerbGate

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_paged_walk_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    n = :rand.uniform(1_000_000_000)
    store = :"paged_walk_store_#{n}"
    tss = :"paged_walk_tss_#{n}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: dir,
       name: :"paged_walk_sup_#{n}",
       commit_store_name: store,
       trust_side_store_name: tss,
       pending_imports_name: :"paged_walk_pi_#{n}"}
    )

    on_exit(fn -> File.rm_rf!(dir) end)

    {pub, priv} = Signing.generate_keypair()
    identity = "trusted-#{:rand.uniform(999_999_999)}"
    ctx = %SigningContext{identity_uuid: identity, private_key: priv, public_key: pub}

    cfg = %{accept_unsigned: false, trusted_identities: %{identity => Signing.encode_key(pub)}}

    %{store: store, trust_side_store: tss, ctx: ctx, cfg: cfg}
  end

  defp put(store, uuid, body, metadata, ctx) do
    doc = Yelixer.Doc.new() |> ContentType.create(:text, "code.ex")
    doc = ContentType.insert_text(doc, 0, body)
    update = Yelixer.Encoding.encode_update(doc)
    CommitStore.create_chained_commit(store, uuid, update, metadata, signing_context: ctx)
  end

  defp attach(event) do
    test_pid = self()
    ref = make_ref()

    :telemetry.attach(
      "#{inspect(event)}-#{inspect(ref)}",
      event,
      fn ^event, measurements, metadata, _ -> send(test_pid, {:telemetry, event, measurements, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach("#{inspect(event)}-#{inspect(ref)}") end)
  end

  defp count_paged_events do
    receive do
      {:telemetry, [:commonplace, :trust, :authorization_walk_paged], _, _} -> 1 + count_paged_events()
    after
      0 -> 0
    end
  end

  describe "authorized_to_execute?/4 paging" do
    test "multi-page clean chain agrees with a single large-page walk and fires paged telemetry",
         %{store: store, ctx: ctx, cfg: cfg} do
      attach([:commonplace, :trust, :authorization_walk_paged])

      uuid = UUID.uuid4()

      for i <- 1..9 do
        put(store, uuid, "defmodule Chain#{i} do\nend", %{kind: :regular}, ctx)
      end

      assert :ok = Trust.authorized_to_execute?(store, uuid, cfg, page_size: 3)
      assert :ok = Trust.authorized_to_execute?(store, uuid, cfg, page_size: 10_000)

      # 10 commits total (9 regular + auto-stamped genesis), page_size 3:
      # genesis lands on the 4th page — 3 extra page fetches beyond the first.
      assert count_paged_events() >= 2
    end

    test "incomplete chain (missing mid-chain commit) fails closed",
         %{store: store, ctx: ctx, cfg: cfg} do
      uuid = UUID.uuid4()

      commits = for i <- 1..6, do: put(store, uuid, "defmodule Gap#{i} do\nend", %{kind: :regular}, ctx)

      # Delete a commit strictly between genesis and head so the walk's
      # `parent_id` chase runs into a hole regardless of page alignment.
      victim = Enum.at(commits, 2)
      db = CommitStore.db_handle(store)
      CubDB.delete(db, {:commit, victim.id})

      assert {:error, {:authorization_chain_incomplete, _last_seen_id}} =
               Trust.authorized_to_execute?(store, uuid, cfg, page_size: 3)

      # The Logger.error above is async — flush before the test process
      # exits so it doesn't race the CLI formatter's teardown.
      Logger.flush()
    end

    test "runaway chain fails closed under a small total ceiling",
         %{store: store, ctx: ctx, cfg: cfg} do
      old = Application.get_env(:commonplace, :max_authorization_walk_commits)
      Application.put_env(:commonplace, :max_authorization_walk_commits, 5)

      on_exit(fn ->
        case old do
          nil -> Application.delete_env(:commonplace, :max_authorization_walk_commits)
          v -> Application.put_env(:commonplace, :max_authorization_walk_commits, v)
        end
      end)

      uuid = UUID.uuid4()
      for i <- 1..10, do: put(store, uuid, "defmodule Long#{i} do\nend", %{kind: :regular}, ctx)

      assert {:error, {:authorization_chain_too_long, n}} =
               Trust.authorized_to_execute?(store, uuid, cfg, page_size: 3)

      assert n > 5
    end

    test "cached-clean snapshot in a later page halts the walk without reading further",
         %{store: store, trust_side_store: tss, ctx: ctx, cfg: cfg} do
      uuid = UUID.uuid4()

      put(store, uuid, "defmodule Snap do\nend", %{kind: :regular}, ctx)
      snap = put(store, uuid, "defmodule Snap do\n  def a, do: 1\nend", %{kind: :snapshot}, ctx)
      put(store, uuid, "defmodule Snap do\n  def a, do: 1\n  def b, do: 2\nend", %{kind: :regular}, ctx)
      put(store, uuid, "defmodule Snap do\n  def a, do: 1\n  def b, do: 2\n  def c, do: 3\nend", %{kind: :regular}, ctx)

      # First (unpaged) walk backfills the snapshot's execute-clean cache.
      assert :ok = Trust.authorized_to_execute?(store, uuid, cfg)
      :sys.get_state(store)
      :sys.get_state(tss)

      fp = :erlang.phash2({cfg.trusted_identities, CommitStoreClient.revocation_set_hash(store)})
      assert {:ok, true} = CommitStore.get_execute_clean(store, fp, snap.id)

      # Chain (oldest -> newest): genesis, r1, snap, r2, r3. Newest-first
      # log: r3, r2, snap, r1, genesis — with page_size:2, page 1 is
      # [r3, r2] and the snapshot lands as the FIRST item of page 2
      # ([snap, r1]). Delete everything strictly below the snapshot
      # (r1 and genesis) — if the paged walk needed to read past the
      # cached-clean snapshot to reach them it would hit a hole and fail
      # closed instead of returning :ok.
      full = CommitStoreClient.commit_log(store, uuid, limit: 100)
      assert length(full) == 5
      genesis = List.last(full)
      r1 = Enum.at(full, -2)

      db = CommitStore.db_handle(store)
      CubDB.delete(db, {:commit, genesis.id})
      CubDB.delete(db, {:commit, r1.id})

      assert :ok = Trust.authorized_to_execute?(store, uuid, cfg, page_size: 2)
    end
  end

  describe "authorized_to_define?/5 paging" do
    test "multi-page clean chain agrees with a single large-page walk",
         %{store: store, ctx: ctx, cfg: cfg} do
      uuid = UUID.uuid4()
      section = UUID.uuid4()

      for i <- 1..9 do
        put(store, uuid, "defmodule VChain#{i} do\nend", %{kind: :regular}, ctx)
      end

      assert :ok = DefineVerbGate.authorized_to_define?(store, uuid, [section], cfg, page_size: 3)
      assert :ok = DefineVerbGate.authorized_to_define?(store, uuid, [section], cfg, page_size: 10_000)
    end

    test "incomplete chain fails closed",
         %{store: store, ctx: ctx, cfg: cfg} do
      uuid = UUID.uuid4()
      section = UUID.uuid4()

      commits = for i <- 1..6, do: put(store, uuid, "defmodule VGap#{i} do\nend", %{kind: :regular}, ctx)
      victim = Enum.at(commits, 2)
      db = CommitStore.db_handle(store)
      CubDB.delete(db, {:commit, victim.id})

      assert {:error, {:authorization_chain_incomplete, _}} =
               DefineVerbGate.authorized_to_define?(store, uuid, [section], cfg, page_size: 3)

      Logger.flush()
    end

    test "runaway chain fails closed under a small total ceiling",
         %{store: store, ctx: ctx, cfg: cfg} do
      old = Application.get_env(:commonplace, :max_authorization_walk_commits)
      Application.put_env(:commonplace, :max_authorization_walk_commits, 5)

      on_exit(fn ->
        case old do
          nil -> Application.delete_env(:commonplace, :max_authorization_walk_commits)
          v -> Application.put_env(:commonplace, :max_authorization_walk_commits, v)
        end
      end)

      uuid = UUID.uuid4()
      section = UUID.uuid4()
      for i <- 1..10, do: put(store, uuid, "defmodule VLong#{i} do\nend", %{kind: :regular}, ctx)

      assert {:error, {:authorization_chain_too_long, n}} =
               DefineVerbGate.authorized_to_define?(store, uuid, [section], cfg, page_size: 3)

      assert n > 5
    end
  end

  describe "CommitStore.commit_log_from/3" do
    test "continues the backward walk from an arbitrary commit id", %{store: store, ctx: ctx} do
      uuid = UUID.uuid4()
      commits = for i <- 1..5, do: put(store, uuid, "defmodule From#{i} do\nend", %{kind: :regular}, ctx)

      full = CommitStoreClient.commit_log(store, uuid, limit: 100)
      assert length(full) == 6

      third_newest = Enum.at(full, 2)
      rest = CommitStoreClient.commit_log_from(store, third_newest.id, limit: 100)

      assert Enum.map(rest, & &1.id) == Enum.map(Enum.drop(full, 2), & &1.id)
      refute commits == []
    end

    test "short result when the chain runs out before the limit", %{store: store, ctx: ctx} do
      uuid = UUID.uuid4()
      put(store, uuid, "defmodule ShortFrom do\nend", %{kind: :regular}, ctx)

      full = CommitStoreClient.commit_log(store, uuid, limit: 100)
      genesis = List.last(full)

      assert CommitStoreClient.commit_log_from(store, genesis.id, limit: 100) == [genesis]
    end
  end
end
