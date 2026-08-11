defmodule Commonplace.Bd.MigrateTest do
  use ExUnit.Case

  alias Commonplace.Bd.{Issue, Migrate}
  alias Commonplace.Crypto.Signing
  alias Commonplace.Crypto.SigningContext
  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.{DocBuilder, Schema}
  alias Yelixer.Encoding

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_bd_migrate_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    store = :"commit_store_migrate_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store})
    on_exit(fn -> File.rm_rf!(dir) end)

    root = UUID.uuid4()
    update = Encoding.encode_update(Schema.new_schema())
    CommitStore.create_commit(store, root, update, nil)

    %{dir: dir, store: store, root: root}
  end

  defp jsonl(records) do
    records
    |> Enum.map(&Jason.encode!/1)
    |> Enum.join("\n")
  end

  test "a refused bd ensure stops migration without a partial /bd/ or import", ctx do
    root = minimal_root!(ctx.store, ctx.dir)
    export = jsonl([%{"id" => "CX-refused", "title" => "must not migrate", "status" => "open"}])

    assert {:error, refusal} = Migrate.import_from_export(root, export, ctx.store)

    assert refusal ==
             "bd ensure refused before export migration: " <>
               "{:trust_rejected, \"workspace class 'minimal' does not accept root entry 'bd' — declared in profile\"}; " <>
               "export migration did not run"

    assert :error = Schema.get_entry(load_schema!(ctx.store, root), "bd")
  end

  describe "status filter" do
    test "closed and wontfix are skipped; open/in_progress/blocked/review are imported verbatim", ctx do
      export =
        jsonl([
          %{"id" => "CX-1", "title" => "open one", "status" => "open", "priority" => 2, "issue_type" => "task"},
          %{"id" => "CX-2", "title" => "in progress one", "status" => "in_progress", "priority" => 1, "issue_type" => "bug"},
          %{"id" => "CX-3", "title" => "blocked one", "status" => "blocked", "priority" => 2, "issue_type" => "task"},
          %{"id" => "CX-4", "title" => "review one", "status" => "review", "priority" => 2, "issue_type" => "task"},
          %{"id" => "CX-5", "title" => "closed one", "status" => "closed", "priority" => 2, "issue_type" => "task"},
          %{"id" => "CX-6", "title" => "wontfix one", "status" => "wontfix", "priority" => 2, "issue_type" => "task"}
        ])

      {:ok, result} = Migrate.import_from_export(ctx.root, export, ctx.store)

      assert result.imported == 4
      assert result.skipped_closed == 2

      for {id, expected_status} <- [
            {"CX-1", "open"},
            {"CX-2", "in_progress"},
            {"CX-3", "blocked"},
            {"CX-4", "review"}
          ] do
        {:ok, issue} = Issue.show(ctx.root, id, ctx.store)
        assert issue.status == expected_status
        assert issue.legacy_id == id
        assert issue.done_when == "manual"
        assert issue.claimed_by == nil
        assert issue.needs == []
      end

      assert {:error, :not_found} = Issue.show(ctx.root, "CX-5", ctx.store)
      assert {:error, :not_found} = Issue.show(ctx.root, "CX-6", ctx.store)
    end
  end

  defp minimal_root!(store, data_dir) do
    root = UUID.uuid4()
    schema = Schema.new_schema() |> Schema.put_workspace_profile(:minimal)
    CommitStore.create_commit(store, root, Encoding.encode_update(schema), nil)
    File.write!(Path.join(data_dir, "root"), root)
    root
  end

  defp load_schema!(store, uuid) do
    {:ok, schema} = DocBuilder.reconstruct_snapshot(store, uuid)
    schema
  end

  describe "no tokens minted" do
    test "an imported in_progress issue has claimed_by nil", ctx do
      export =
        jsonl([
          %{"id" => "CX-ip", "title" => "wip", "status" => "in_progress", "priority" => 1, "issue_type" => "task"}
        ])

      {:ok, _result} = Migrate.import_from_export(ctx.root, export, ctx.store)

      {:ok, issue} = Issue.show(ctx.root, "CX-ip", ctx.store)
      assert issue.claimed_by == nil
    end
  end

  describe "C-invariant drop" do
    test "a dep whose prereq is closed (not imported) is dropped and manifested", ctx do
      export =
        jsonl([
          %{"id" => "CX-closed-prereq", "title" => "closed prereq", "status" => "closed", "priority" => 2, "issue_type" => "task"},
          %{
            "id" => "CX-dependent",
            "title" => "dependent",
            "status" => "open",
            "priority" => 2,
            "issue_type" => "task",
            "dependencies" => [
              %{"issue_id" => "CX-dependent", "depends_on_id" => "CX-closed-prereq", "type" => "blocks"}
            ]
          }
        ])

      {:ok, result} = Migrate.import_from_export(ctx.root, export, ctx.store)

      assert result.edges_added == 0
      assert [%{from: "CX-closed-prereq", to: "CX-dependent", reason: :prereq_not_imported}] = result.manifest

      {:ok, issue} = Issue.show(ctx.root, "CX-dependent", ctx.store)
      refute Enum.any?(issue.needs, fn %{"ticket" => t} -> t == "CX-closed-prereq" end)
    end
  end

  describe "guarded edge add" do
    test "a dep between two imported tickets adds needs via the guard", ctx do
      export =
        jsonl([
          %{"id" => "CX-a", "title" => "A", "status" => "open", "priority" => 2, "issue_type" => "task"},
          %{
            "id" => "CX-b",
            "title" => "B",
            "status" => "open",
            "priority" => 2,
            "issue_type" => "task",
            "dependencies" => [%{"issue_id" => "CX-b", "depends_on_id" => "CX-a", "type" => "blocks"}]
          }
        ])

      {:ok, result} = Migrate.import_from_export(ctx.root, export, ctx.store)

      assert result.edges_added == 1
      assert result.manifest == []

      {:ok, issue_b} = Issue.show(ctx.root, "CX-b", ctx.store)
      assert Enum.any?(issue_b.needs, fn %{"ticket" => t} -> t == "CX-a" end)
    end

    test "a would-be cycle among imported tickets is refused and manifested, not forced", ctx do
      # X blocks Y (Y.needs gains X), Y blocks X (X.needs would gain Y) -> cycle.
      export =
        jsonl([
          %{
            "id" => "CX-x",
            "title" => "X",
            "status" => "open",
            "priority" => 2,
            "issue_type" => "task",
            "dependencies" => [%{"issue_id" => "CX-x", "depends_on_id" => "CX-y", "type" => "blocks"}]
          },
          %{
            "id" => "CX-y",
            "title" => "Y",
            "status" => "open",
            "priority" => 2,
            "issue_type" => "task",
            "dependencies" => [%{"issue_id" => "CX-y", "depends_on_id" => "CX-x", "type" => "blocks"}]
          }
        ])

      {:ok, result} = Migrate.import_from_export(ctx.root, export, ctx.store)

      # One edge lands, the other is refused as a cycle.
      assert result.edges_added == 1
      assert [%{reason: :guard_refused} = manifested] = result.manifest
      assert manifested.from in ["CX-x", "CX-y"]
      assert manifested.to in ["CX-x", "CX-y"]
    end
  end

  describe "blocks-only filter" do
    test "a parent-child dependency edge is NOT converted into needs", ctx do
      export =
        jsonl([
          %{"id" => "CX-epic", "title" => "epic", "status" => "open", "priority" => 2, "issue_type" => "epic"},
          %{
            "id" => "CX-sub",
            "title" => "subtask",
            "status" => "open",
            "priority" => 2,
            "issue_type" => "task",
            "dependencies" => [
              %{"issue_id" => "CX-sub", "depends_on_id" => "CX-epic", "type" => "parent-child"}
            ]
          }
        ])

      {:ok, result} = Migrate.import_from_export(ctx.root, export, ctx.store)

      assert result.edges_added == 0
      assert result.manifest == []

      {:ok, issue_sub} = Issue.show(ctx.root, "CX-sub", ctx.store)
      assert issue_sub.needs == []
    end

    test "supersedes and related edges are also skipped, only blocks converts", ctx do
      export =
        jsonl([
          %{"id" => "CX-old", "title" => "old", "status" => "open", "priority" => 2, "issue_type" => "task"},
          %{"id" => "CX-friend", "title" => "friend", "status" => "open", "priority" => 2, "issue_type" => "task"},
          %{"id" => "CX-blocker", "title" => "blocker", "status" => "open", "priority" => 2, "issue_type" => "task"},
          %{
            "id" => "CX-mixed",
            "title" => "mixed",
            "status" => "open",
            "priority" => 2,
            "issue_type" => "task",
            "dependencies" => [
              %{"issue_id" => "CX-mixed", "depends_on_id" => "CX-old", "type" => "supersedes"},
              %{"issue_id" => "CX-mixed", "depends_on_id" => "CX-friend", "type" => "related"},
              %{"issue_id" => "CX-mixed", "depends_on_id" => "CX-blocker", "type" => "blocks"}
            ]
          }
        ])

      {:ok, result} = Migrate.import_from_export(ctx.root, export, ctx.store)

      assert result.edges_added == 1
      assert result.manifest == []

      {:ok, issue_mixed} = Issue.show(ctx.root, "CX-mixed", ctx.store)
      needs_tickets = Enum.map(issue_mixed.needs, & &1["ticket"])
      assert needs_tickets == ["CX-blocker"]
    end
  end

  describe "three_way/3" do
    test "agrees when query, walk, and supplied bd_cli ready ids all match", ctx do
      export =
        jsonl([
          %{"id" => "CX-r1", "title" => "ready one", "status" => "open", "priority" => 2, "issue_type" => "task"},
          %{
            "id" => "CX-blocked1",
            "title" => "blocked one",
            "status" => "open",
            "priority" => 2,
            "issue_type" => "task",
            "dependencies" => [%{"issue_id" => "CX-blocked1", "depends_on_id" => "CX-r1", "type" => "blocks"}]
          }
        ])

      {:ok, _result} = Migrate.import_from_export(ctx.root, export, ctx.store)

      result = Migrate.three_way(ctx.root, ctx.store, MapSet.new(["CX-r1"]))

      assert result.agree? == true
      assert result.query == MapSet.new(["CX-r1"])
      assert result.walk == MapSet.new(["CX-r1"])
      assert result.bd_cli == MapSet.new(["CX-r1"])
    end

    test "disagreement is localized and non-vacuous when bd_cli set is wrong", ctx do
      export =
        jsonl([
          %{"id" => "CX-r2", "title" => "ready two", "status" => "open", "priority" => 2, "issue_type" => "task"}
        ])

      {:ok, _result} = Migrate.import_from_export(ctx.root, export, ctx.store)

      # Perturb: claim a bd-ready set that has a spurious extra id not
      # actually ready per query/walk.
      bad_bd_cli = MapSet.new(["CX-r2", "CX-phantom"])

      result = Migrate.three_way(ctx.root, ctx.store, bad_bd_cli)

      refute result.agree?
      assert MapSet.member?(result.only_in_bd_cli, "CX-phantom")
      refute MapSet.member?(result.only_in_query, "CX-phantom")
      refute MapSet.member?(result.only_in_walk, "CX-phantom")
    end
  end

  # Bd P2 S5 — node-signing support for the ticket-DAG migration path,
  # so the live cutover (which writes into an enforce workspace with NO
  # /bd/ yet) can create the skeleton + every issue doc + every guarded
  # edge as signed commits. `root_uuid`/`store` come from the file-level
  # setup (created BEFORE trust is tightened below, same pattern as
  # close_gate_test.exs / local_write_gate_test.exs — the gate is only
  # turned on inside each test, never around fixture setup).
  describe "enforce mode (Bd P2 S5 signing plumb)" do
    setup do
      {pub, priv} = Signing.generate_keypair()
      identity = "bd-migrate-test-invoker"

      sc = %SigningContext{
        identity_uuid: identity,
        private_key: priv,
        public_key: pub
      }

      old_trust = Application.get_env(:commonplace, :trust)
      old_gate = Application.get_env(:commonplace, :local_write_gate)

      Application.put_env(:commonplace, :trust, %{
        accept_unsigned: false,
        trusted_identities: %{identity => Signing.encode_key(pub)}
      })

      Application.put_env(:commonplace, :local_write_gate, :enforce)

      on_exit(fn ->
        case old_trust do
          nil -> Application.delete_env(:commonplace, :trust)
          v -> Application.put_env(:commonplace, :trust, v)
        end

        case old_gate do
          nil -> Application.delete_env(:commonplace, :local_write_gate)
          v -> Application.put_env(:commonplace, :local_write_gate, v)
        end
      end)

      %{sc: sc}
    end

    test "a signed import lands under enforce: skeleton + tickets + edges all pass the gate", ctx do
      export =
        jsonl([
          %{"id" => "CX-sr1", "title" => "ready one", "status" => "open", "priority" => 2, "issue_type" => "task"},
          %{
            "id" => "CX-sblocked1",
            "title" => "blocked one",
            "status" => "open",
            "priority" => 2,
            "issue_type" => "task",
            "dependencies" => [
              %{"issue_id" => "CX-sblocked1", "depends_on_id" => "CX-sr1", "type" => "blocks"}
            ]
          }
        ])

      {:ok, result} =
        Migrate.import_from_export(ctx.root, export, ctx.store, nil, signing_context: ctx.sc)

      assert result.imported == 2
      assert result.edges_added == 1

      {:ok, issue_r1} = Issue.show(ctx.root, "CX-sr1", ctx.store)
      assert issue_r1.legacy_id == "CX-sr1"

      {:ok, issue_blocked1} = Issue.show(ctx.root, "CX-sblocked1", ctx.store)
      assert Enum.any?(issue_blocked1.needs, fn %{"ticket" => t} -> t == "CX-sr1" end)

      three_way = Migrate.three_way(ctx.root, ctx.store, MapSet.new(["CX-sr1"]))
      assert three_way.agree? == true
    end

    test "an unsigned import does NOT land under enforce (denied, not decorative)", ctx do
      export =
        jsonl([
          %{"id" => "CX-un1", "title" => "unsigned one", "status" => "open", "priority" => 2, "issue_type" => "task"}
        ])

      # No signing_context -> default opts \\ [] -> unsigned. Every write
      # on the path (skeleton creation included, since /bd/ doesn't exist
      # yet under this fresh root) is denied by the local_write_gate.
      # Depending on exactly which write hits the gate first, this either
      # raises (a MatchError on a `{:ok, _} = ...` pattern upstream of the
      # gate, or a bare `{:error, {:trust_rejected, :unsigned}}` bubbling
      # out of Migrate itself) or returns without creating anything -- in
      # either case the ticket must NOT exist afterward.
      try do
        Migrate.import_from_export(ctx.root, export, ctx.store)
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
      end

      # Confirming the ticket never landed is itself denied here: since
      # the unsigned import never got far enough to create /bd/, and
      # Workspace's read-lookup path (`issues_dir_uuid` -> `ensure_bd_dir`)
      # is a LAZY creator that also writes unsigned by default, the
      # lookup itself now raises under enforce instead of cleanly
      # returning "not found" -- which is itself proof nothing landed
      # (an `{:ok, _}` from Issue.show would prove the opposite).
      result =
        try do
          Issue.show(ctx.root, "CX-un1", ctx.store)
        rescue
          _ -> :denied
        catch
          :exit, _ -> :denied
        end

      refute match?({:ok, _}, result)
    end
  end
end
