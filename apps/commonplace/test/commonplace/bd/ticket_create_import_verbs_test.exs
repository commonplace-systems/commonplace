defmodule Commonplace.Bd.TicketCreateImportVerbsTest do
  @moduledoc """
  CX-6cz3, step 1 of the tix-authority migration
  (`/home/jes/commonplace-plan/docs/plans/2026-08-05-tix-authority-migration-design.md`
  §7, rulings @6418506): the GATED write surface for ticket creation
  and import — `ticket_create` (minted id) and `ticket_import`
  (supplied id, batch) on `Commonplace.ViewActionDispatch`.

  The four ruled build conditions each have a named test below:

    1. the import allow posture is a spec-derived ENUMERATION
       (`import_allow_posture/0`), never inferred from the records —
       "posture from spec" / "one-byte control" describe.
    2. byte-identical no-op detection is content-hash equality; a
       ONE-BYTE-different record must NOT no-op (the gate-bypass
       control).
    3. `create_with_id` (the supplied-id primitive that supersedes
       `Bd.Importer.create_with_fixed_id`) has no ungated caller —
       proven by `Commonplace.Bd.SuppliedIdCreationScanTest`.
    4. a deliberately cycle-introducing import batch refuses LOUDLY,
       per record, naming the edge.

  Fixture mirrors `Commonplace.Bd.TicketVerbsTest` — the dispatcher
  talks to the default-named `CommitStore` via `CommitStoreClient`, so
  this needs the "root pointer file + running default CommitStore"
  setup, not a custom-named store the dispatcher singleton can't see.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Bd.Invariants
  alias Commonplace.Bd.Issue
  alias Commonplace.Bd.Schemas
  alias Commonplace.Bd.WriteGuard
  alias Commonplace.Crypto.Signing
  alias Commonplace.Crypto.SigningContext
  alias Commonplace.Store.CommitStore
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.Schema
  alias Commonplace.ViewActionDispatch

  setup do
    dir =
      Path.join(System.tmp_dir!(), "cp_ticket_create_import_test_#{:rand.uniform(1_000_000_000)}")

    File.mkdir_p!(dir)
    prior_data_dir = Application.get_env(:commonplace, :data_dir)
    Application.put_env(:commonplace, :data_dir, dir)

    sup = Commonplace.Store.CommitStoreSupervisor
    _ = Supervisor.terminate_child(sup, Commonplace.Store.CommitStore)
    _ = Supervisor.delete_child(sup, Commonplace.Store.CommitStore)

    {:ok, _pid} = Supervisor.start_child(sup, {Commonplace.Store.CommitStore, data_dir: dir})

    root_uuid = UUID.uuid4()
    update = Yelixer.Encoding.encode_update(Schema.new_schema())
    CommitStore.create_commit(Commonplace.Store.CommitStore, root_uuid, update, nil)
    File.write!(Path.join(dir, "root"), root_uuid)

    on_exit(fn ->
      Application.put_env(:commonplace, :data_dir, prior_data_dir || "tmp/test_data")
      File.rm_rf!(dir)
    end)

    {pub, priv} = Signing.generate_keypair()

    ctx = %SigningContext{
      identity_uuid: "test-tix-importer",
      private_key: priv,
      public_key: pub
    }

    %{root: root_uuid, signing_context: ctx}
  end

  defp import_batch(records, ctx) do
    ViewActionDispatch.dispatch("ticket_import", %{
      args: %{"records" => records},
      signing_context: ctx,
      source: "test"
    })
  end

  defp record(id, overrides \\ %{}) do
    Map.merge(
      %{
        "id" => id,
        "title" => "record #{id}",
        "status" => "open",
        "priority" => 2,
        "issue_type" => "task"
      },
      overrides
    )
  end

  describe "ticket_create (minted id, gated)" do
    test "mints an id and lands an open ticket", %{root: root, signing_context: ctx} do
      assert {:ok, :tree_mutation, details} =
               ViewActionDispatch.dispatch("ticket_create", %{
                 args: %{"title" => "a new tix", "type" => "bug", "priority" => "p0"},
                 signing_context: ctx,
                 source: "test"
               })

      assert details.action == "ticket_create"
      id = details.ticket
      assert is_binary(id)

      {:ok, issue} = Issue.show(root, id)
      assert issue.title == "a new tix"
      assert issue.type == "bug"
      assert issue.priority == "p0"
      assert issue.status == "open"
      assert issue.done_when == "manual"
    end

    test "status is FORCED open — a client-supplied closed status never lands", %{
      root: root,
      signing_context: ctx
    } do
      assert {:ok, :tree_mutation, details} =
               ViewActionDispatch.dispatch("ticket_create", %{
                 args: %{"title" => "sneaky", "status" => "closed"},
                 signing_context: ctx,
                 source: "test"
               })

      {:ok, issue} = Issue.show(root, details.ticket)
      assert issue.status == "open"
    end

    test "a malformed initial needs entry is refused by the shared shape validator", %{
      signing_context: ctx
    } do
      assert {:error, reason} =
               ViewActionDispatch.dispatch("ticket_create", %{
                 args: %{"title" => "bad needs", "needs" => [%{"nope" => "x"}]},
                 signing_context: ctx,
                 source: "test"
               })

      assert reason =~ "needs entry"
    end

    test "initial needs edges run the SAME cycle walk ticket_add_needs uses", %{
      root: root,
      signing_context: ctx
    } do
      # A freshly minted id cannot be reached by anything, so a legal
      # initial edge lands...
      assert {:ok, :tree_mutation, a} =
               ViewActionDispatch.dispatch("ticket_create", %{
                 args: %{"title" => "A"},
                 signing_context: ctx,
                 source: "test"
               })

      assert {:ok, :tree_mutation, b} =
               ViewActionDispatch.dispatch("ticket_create", %{
                 args: %{"title" => "B", "needs" => [%{"ticket" => a.ticket}]},
                 signing_context: ctx,
                 source: "test"
               })

      {:ok, b_issue} = Issue.show(root, b.ticket)
      assert b_issue.needs == [%{"ticket" => a.ticket}]

      # ...and closing the loop back through the existing verb is still
      # refused, so creation did not open a side door into the graph.
      assert {:error, reason} =
               ViewActionDispatch.dispatch("ticket_add_needs", %{
                 args: %{"ticket" => a.ticket, "needs_ticket" => b.ticket},
                 signing_context: ctx,
                 source: "test"
               })

      assert reason =~ "cycle"
    end

    test "missing title is refused", %{signing_context: ctx} do
      assert {:error, reason} =
               ViewActionDispatch.dispatch("ticket_create", %{
                 args: %{},
                 signing_context: ctx,
                 source: "test"
               })

      assert reason =~ "title"
    end
  end

  describe "ticket_import: the declared-denominator reporting shape (ruling (b))" do
    test "LANDED ∪ REFUSED ∪ NOOP == the declared input set, never a bare count", %{
      signing_context: ctx
    } do
      records = [record("CX-aaa"), record("CX-bbb"), %{"title" => "no id at all"}]

      assert {:ok, :tree_mutation, r} = import_batch(records, ctx)

      assert r.declared == 3
      assert length(r.declared_ids) == 3
      assert r.unaccounted == []

      accounted =
        MapSet.new(Enum.map(r.landed, & &1.id) ++ Enum.map(r.refused, & &1.id) ++ r.noop)

      assert MapSet.equal?(accounted, MapSet.new(r.declared_ids))

      # The id-less record is REFUSED and NAMED, not silently dropped.
      assert [%{id: missing_id, reason: reason}] = r.refused
      assert missing_id =~ "no id"
      assert reason =~ "id"
    end

    test "a refusal on record N does not abort the batch — later records still land", %{
      root: root,
      signing_context: ctx
    } do
      records = [%{"title" => "bad"}, record("CX-after")]

      assert {:ok, :tree_mutation, r} = import_batch(records, ctx)
      assert length(r.refused) == 1
      assert [%{id: "CX-after", op: :created}] = r.landed
      assert {:ok, _} = Issue.show(root, "CX-after")
    end
  end

  describe "ticket_import: supplied ids land with their bd ids preserved" do
    test "creates absent tickets with the supplied id and full record", %{
      root: root,
      signing_context: ctx
    } do
      rec =
        record("CX-keepme", %{
          "title" => "supplied id",
          "priority" => 1,
          "issue_type" => "bug",
          "owner" => "alice",
          "description" => "the body",
          "severity" => "high"
        })

      assert {:ok, :tree_mutation, r} = import_batch([rec], ctx)
      assert [%{id: "CX-keepme", op: :created}] = r.landed

      {:ok, issue} = Issue.show(root, "CX-keepme")
      assert issue.id == "CX-keepme"
      assert issue.priority == "p1"
      assert issue.type == "bug"
      assert issue.owner == "alice"
      assert issue.extra["severity"] == "high"
      {:ok, body} = Issue.description(root, "CX-keepme")
      assert body == "the body"
    end

    test "an existing ticket takes an UPDATE through the gate", %{
      root: root,
      signing_context: ctx
    } do
      assert {:ok, :tree_mutation, _} = import_batch([record("CX-upd", %{"title" => "v1"})], ctx)

      assert {:ok, :tree_mutation, r} =
               import_batch([record("CX-upd", %{"title" => "v2", "priority" => 0})], ctx)

      assert [%{id: "CX-upd", op: :updated}] = r.landed
      {:ok, issue} = Issue.show(root, "CX-upd")
      assert issue.title == "v2"
      assert issue.priority == "p0"
    end

    test "the jsonl convenience arg reuses the importer's parser", %{
      root: root,
      signing_context: ctx
    } do
      jsonl = Jason.encode!(record("CX-jsonl", %{"title" => "from jsonl"}))

      assert {:ok, :tree_mutation, r} =
               ViewActionDispatch.dispatch("ticket_import", %{
                 args: %{"jsonl" => jsonl},
                 signing_context: ctx,
                 source: "test"
               })

      assert [%{id: "CX-jsonl", op: :created}] = r.landed
      {:ok, issue} = Issue.show(root, "CX-jsonl")
      assert issue.title == "from jsonl"
    end
  end

  describe "CONDITION 2: byte-identical no-op is content-hash equality (gate-bypass control)" do
    test "re-importing the IDENTICAL record is a no-op: no write, no gate", %{
      root: root,
      signing_context: ctx
    } do
      rec = record("CX-noop", %{"title" => "stable"})
      assert {:ok, :tree_mutation, _} = import_batch([rec], ctx)

      {:ok, dir_uuid} = Commonplace.Bd.Workspace.issue_dir_uuid(root, "CX-noop")
      {:ok, schema} = Schemas.load_dir_schema(dir_uuid)
      {:ok, entry} = Schema.get_entry(schema, Schemas.issue_filename())
      before_log = CommitStoreClient.commit_log(CommitStoreClient, entry.node_id) |> length()

      assert {:ok, :tree_mutation, r} = import_batch([rec], ctx)
      assert r.noop == ["CX-noop"]
      assert r.landed == []

      after_log = CommitStoreClient.commit_log(CommitStoreClient, entry.node_id) |> length()
      assert after_log == before_log, "a no-op must not land a commit"
    end

    test "CONTROL: a ONE-BYTE-different record is NOT treated as a no-op", %{
      root: root,
      signing_context: ctx
    } do
      rec = record("CX-onebyte", %{"title" => "stable"})
      assert {:ok, :tree_mutation, _} = import_batch([rec], ctx)

      # Exactly one byte differs: "stable" -> "stablf".
      changed = record("CX-onebyte", %{"title" => "stablf"})
      assert byte_size(changed["title"]) == byte_size(rec["title"])

      assert {:ok, :tree_mutation, r} = import_batch([changed], ctx)

      assert r.noop == [], "a one-byte-different record must NOT no-op (that would skip the gate)"
      assert [%{id: "CX-onebyte", op: :updated}] = r.landed

      {:ok, issue} = Issue.show(root, "CX-onebyte")
      assert issue.title == "stablf"
    end

    test "the description is stored content: a body-only change is NOT a no-op", %{
      root: root,
      signing_context: ctx
    } do
      assert {:ok, :tree_mutation, _} =
               import_batch([record("CX-body", %{"description" => "first body"})], ctx)

      assert {:ok, :tree_mutation, r} =
               import_batch([record("CX-body", %{"description" => "second body"})], ctx)

      assert r.noop == []
      assert [%{id: "CX-body", op: :updated}] = r.landed
      assert {:ok, "second body"} = Issue.description(root, "CX-body")
    end

    test "a record that says nothing about the body never blanks one (present-key semantics)", %{
      root: root,
      signing_context: ctx
    } do
      assert {:ok, :tree_mutation, _} =
               import_batch([record("CX-keepbody", %{"description" => "keep me"})], ctx)

      # No "description" key at all, and a real field change so the
      # record is not a no-op.
      assert {:ok, :tree_mutation, r} =
               import_batch([record("CX-keepbody", %{"title" => "renamed"})], ctx)

      assert [%{id: "CX-keepbody", op: :updated}] = r.landed
      assert {:ok, "keep me"} = Issue.description(root, "CX-keepbody")
    end

    test "a record that says nothing about needs never wipes locally-added edges", %{
      root: root,
      signing_context: ctx
    } do
      assert {:ok, :tree_mutation, _} = import_batch([record("CX-edges")], ctx)
      assert {:ok, :tree_mutation, _} = import_batch([record("CX-prereq")], ctx)

      assert {:ok, :tree_mutation, _} =
               ViewActionDispatch.dispatch("ticket_add_needs", %{
                 args: %{"ticket" => "CX-edges", "needs_ticket" => "CX-prereq"},
                 signing_context: ctx,
                 source: "test"
               })

      assert {:ok, :tree_mutation, _} =
               import_batch([record("CX-edges", %{"title" => "renamed"})], ctx)

      {:ok, issue} = Issue.show(root, "CX-edges")
      assert issue.needs == [%{"ticket" => "CX-prereq"}]
    end

    test "CONTROL: the no-op skip cannot smuggle a protected-field change past the gate", %{
      root: root,
      signing_context: ctx
    } do
      # A closed record lands, then a re-import tries to reopen it. The
      # hash differs (status changed), so the gate RUNS and the
      # post-close freeze refuses it.
      closed = record("CX-frozen", %{"status" => "closed", "closed_at" => "2026-01-01T00:00:00Z"})
      assert {:ok, :tree_mutation, _} = import_batch([closed], ctx)

      reopen = record("CX-frozen", %{"status" => "open"})
      assert {:ok, :tree_mutation, r} = import_batch([reopen], ctx)

      assert r.noop == []
      assert r.landed == []
      assert [%{id: "CX-frozen", reason: reason}] = r.refused
      assert reason =~ "frozen"

      {:ok, issue} = Issue.show(root, "CX-frozen")
      assert issue.status == "closed"
    end
  end

  describe "CONDITION 4: a cycle-introducing import batch refuses LOUDLY, per record" do
    test "records whose needs edges close a cycle are refused, naming the edge", %{
      root: root,
      signing_context: ctx
    } do
      # A needs B lands first (B does not exist yet — the needs shape is
      # legal, the cycle walk simply finds nothing).
      assert {:ok, :tree_mutation, _} =
               import_batch([record("CX-cyc-a", %{"needs" => [%{"ticket" => "CX-cyc-b"}]})], ctx)

      # Now B needs A. Walking A's local-needs-ancestors reaches B, so
      # this edge would close the cycle A -> B -> A.
      batch = [
        record("CX-cyc-b", %{"needs" => [%{"ticket" => "CX-cyc-a"}]}),
        record("CX-innocent")
      ]

      assert {:ok, :tree_mutation, r} = import_batch(batch, ctx)

      assert [%{id: "CX-cyc-b", reason: reason}] = r.refused
      assert reason =~ "cycle"
      assert reason =~ "CX-cyc-b"
      assert reason =~ "CX-cyc-a"

      # Per-record: the innocent record in the SAME batch still lands.
      assert [%{id: "CX-innocent", op: :created}] = r.landed

      # And the refused ticket did not land at all.
      assert {:error, :not_found} = Issue.show(root, "CX-cyc-b")
      assert r.unaccounted == []
    end

    test "a self-needing record is refused", %{signing_context: ctx} do
      assert {:ok, :tree_mutation, r} =
               import_batch([record("CX-self", %{"needs" => [%{"ticket" => "CX-self"}]})], ctx)

      assert [%{id: "CX-self", reason: reason}] = r.refused
      assert reason =~ "cycle"
    end
  end

  describe "CONDITION 1: the import allow posture is enumerated from the tix record SPEC" do
    test "the posture is a fixed list, and every name is a Schemas.Issue field" do
      posture = ViewActionDispatch.import_allow_posture()

      assert posture == [:status, :closed_at, :closed_reason, :done_witness, :claimed_by]

      issue_fields = %Schemas.Issue{id: "x"} |> Map.from_struct() |> Map.keys()
      assert Enum.all?(posture, &(&1 in issue_fields))
    end

    test "the ENFORCED subset is exactly WriteGuard's protected fields ∩ the posture" do
      # Drift alarm: if WriteGuard's protected set widens, this pins the
      # fact that the posture has to be re-reviewed rather than silently
      # letting a newly-protected field ride in on an import.
      enforced = Enum.filter(ViewActionDispatch.import_allow_posture(), &(&1 in WriteGuard.protected_fields()))
      assert enforced == [:status, :done_witness, :claimed_by]
    end

    test "the posture does NOT admit a protected field it never enumerated", %{
      signing_context: ctx
    } do
      # `needs` is not protected (it is shape+cycle-gated instead), but
      # `done_when` IS frozen after close — a record carrying a
      # done_when change on a closed ticket is refused, proving the
      # import path is not a blanket allow-everything.
      closed = record("CX-posture", %{"status" => "closed"})
      assert {:ok, :tree_mutation, _} = import_batch([closed], ctx)

      assert {:ok, :tree_mutation, r} =
               import_batch(
                 [
                   record("CX-posture", %{
                     "status" => "closed",
                     "done_when" => %{"type" => "pr_merge", "target" => "some-doc"}
                   })
                 ],
                 ctx
               )

      assert [%{id: "CX-posture", reason: reason}] = r.refused
      assert reason =~ "frozen"
    end
  end

  describe "provenance stamp (ruling (c)) and the freeze pin (ruling (a))" do
    test "an import-created commit carries source=bd + a bd-store content hash", %{
      root: root,
      signing_context: ctx
    } do
      assert {:ok, :tree_mutation, _} = import_batch([record("CX-prov")], ctx)

      stamp = import_stamp(root, "CX-prov")

      assert stamp["source"] == "bd"
      assert is_binary(stamp["sources_pin"]) and byte_size(stamp["sources_pin"]) == 64
      assert is_binary(stamp["output"]) and byte_size(stamp["output"]) == 64
      assert stamp["transform"] =~ "ticket_import"
    end

    test "an imported CLOSED ticket carries the freeze pin, on the same mechanism close uses", %{
      root: root,
      signing_context: ctx
    } do
      assert {:ok, :tree_mutation, _} =
               import_batch([record("CX-closed", %{"status" => "closed"})], ctx)

      {:ok, dir_uuid} = Commonplace.Bd.Workspace.issue_dir_uuid(root, "CX-closed")
      {:ok, schema} = Schemas.load_dir_schema(dir_uuid)
      {:ok, entry} = Schema.get_entry(schema, Schemas.issue_filename())

      pin =
        CommitStoreClient.commit_log(CommitStoreClient, entry.node_id)
        |> Enum.find_value(fn c -> Map.get(c.metadata, :bd_terminal_pin) end)

      assert is_binary(pin), "an imported closed ticket must carry the terminal pin"
      assert {:ok, %{"status" => "closed"}} = Jason.decode(pin)

      # And the pin the import stamped is one the resting-state
      # invariant accepts — same reader, same key, same mechanism.
      assert Invariants.closed_matches_pin(root, "CX-closed") == :ok
    end

    test "an imported OPEN ticket carries NO freeze pin", %{root: root, signing_context: ctx} do
      assert {:ok, :tree_mutation, _} = import_batch([record("CX-open")], ctx)

      {:ok, dir_uuid} = Commonplace.Bd.Workspace.issue_dir_uuid(root, "CX-open")
      {:ok, schema} = Schemas.load_dir_schema(dir_uuid)
      {:ok, entry} = Schema.get_entry(schema, Schemas.issue_filename())

      refute CommitStoreClient.commit_log(CommitStoreClient, entry.node_id)
             |> Enum.any?(fn c -> Map.has_key?(c.metadata, :bd_terminal_pin) end)
    end
  end

  defp import_stamp(root, id) do
    {:ok, dir_uuid} = Commonplace.Bd.Workspace.issue_dir_uuid(root, id)
    {:ok, schema} = Schemas.load_dir_schema(dir_uuid)
    {:ok, entry} = Schema.get_entry(schema, Schemas.issue_filename())

    CommitStoreClient.commit_log(CommitStoreClient, entry.node_id)
    |> Enum.find_value(fn c -> Map.get(c.metadata, :bd_import) end)
  end
end
