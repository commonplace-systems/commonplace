defmodule Commonplace.Bd.IssueTest do
  use ExUnit.Case

  alias Commonplace.Bd.{Issue, Workspace}
  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.Schema
  alias Yelixer.Encoding

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_bd_issue_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    store = :"commit_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store})
    on_exit(fn -> File.rm_rf!(dir) end)

    root = UUID.uuid4()
    update = Encoding.encode_update(Schema.new_schema())
    CommitStore.create_commit(store, root, update, nil)

    %{store: store, root: root}
  end

  test "create + show round-trip", ctx do
    {:ok, issue, _dir} = Issue.create(ctx.root, %{title: "test", priority: "p1"}, ctx.store)
    assert issue.title == "test"
    assert issue.priority == "p1"
    assert issue.status == "open"
    assert String.starts_with?(issue.id, "CX-")

    {:ok, fetched} = Issue.show(ctx.root, issue.id, ctx.store)
    assert fetched.id == issue.id
    assert fetched.title == "test"
  end

  test "update modifies fields and bumps updated_at", ctx do
    {:ok, issue, _} = Issue.create(ctx.root, %{title: "x"}, ctx.store)
    Process.sleep(15)

    {:ok, updated} =
      Issue.update(ctx.root, issue.id, %{status: "in_progress", owner: "alice"}, ctx.store)

    assert updated.status == "in_progress"
    assert updated.owner == "alice"
    assert updated.updated_at != issue.updated_at
  end

  test "update REFUSES ticket_create_deadline by name — a create-ceremony bound, void on update",
       ctx do
    {:ok, issue, _} = Issue.create(ctx.root, %{title: "z"}, ctx.store)

    # CX-gc7q's deadline is scoped to the create chain deliberately. Handed
    # to update it must be a NAMED refusal at the front door — not the deep
    # KeyError it was (client Keyword.fetch! on the missing
    # :ticket_create_document companion, measured 2026-08-18), and not a
    # silent ignore (the caller would believe the deadline is armed).
    assert {:error, msg} =
             Issue.update(ctx.root, issue.id, %{status: "in_progress"}, ctx.store,
               ticket_create_deadline: System.monotonic_time(:millisecond) + 60_000
             )

    assert msg =~ "ticket_create_deadline applies only to the create chain"

    # The refusal wrote nothing: the issue is unchanged.
    {:ok, fetched} = Issue.show(ctx.root, issue.id, ctx.store)
    assert fetched.status == "open"
  end

  test "close sets closed_at and closed_reason", ctx do
    {:ok, issue, _} = Issue.create(ctx.root, %{title: "y"}, ctx.store)
    {:ok, closed} = Issue.close(ctx.root, issue.id, [reason: "did it"], ctx.store)
    assert closed.status == "closed"
    assert is_binary(closed.closed_at)
    assert closed.closed_reason == "did it"
  end

  test "list returns every created issue", ctx do
    {:ok, a, _} = Issue.create(ctx.root, %{title: "a"}, ctx.store)
    {:ok, b, _} = Issue.create(ctx.root, %{title: "b"}, ctx.store)
    {:ok, c, _} = Issue.create(ctx.root, %{title: "c"}, ctx.store)

    ids = Issue.list(ctx.root, ctx.store) |> Enum.map(fn {i, _} -> i.id end) |> Enum.sort()
    assert Enum.sort([a.id, b.id, c.id]) == ids
  end

  test "show returns :not_found for unknown id", ctx do
    assert {:error, :not_found} = Issue.show(ctx.root, "CX-zzzz", ctx.store)
  end

  test "ensure_bd_dir is idempotent", ctx do
    a = Workspace.ensure_bd_dir(ctx.root, ctx.store)
    b = Workspace.ensure_bd_dir(ctx.root, ctx.store)
    assert a == b
  end

  test "description round-trips", ctx do
    {:ok, issue, _} = Issue.create(ctx.root, %{title: "z", description: "the body"}, ctx.store)
    {:ok, body} = Issue.description(ctx.root, issue.id, ctx.store)
    assert body == "the body"
  end

  # Slice S1 Part 2: signing_context opts-plumb, mirroring the
  # byte-compatible pattern of Tree.Merge.merge/4 / Tree.Fork.fork/2 —
  # default [] reproduces prior (unsigned) behavior for every existing
  # caller (all the tests above call with 3-4 positional args and no
  # opts), and passing signing_context: ctx lands a signed commit.
  test "update threads signing_context through to land a signed commit", ctx do
    {:ok, issue, dir_uuid} = Issue.create(ctx.root, %{title: "x"}, ctx.store)

    {pub, priv} = Commonplace.Crypto.Signing.generate_keypair()

    signing_context = %Commonplace.Crypto.SigningContext{
      identity_uuid: "test-issue-updater",
      private_key: priv,
      public_key: pub
    }

    {:ok, updated} =
      Issue.update(ctx.root, issue.id, %{status: "in_progress"}, ctx.store,
        signing_context: signing_context
      )

    assert updated.status == "in_progress"

    {:ok, schema} = Commonplace.Bd.Schemas.load_dir_schema(dir_uuid, ctx.store)

    {:ok, entry} =
      Commonplace.Tree.Schema.get_entry(schema, Commonplace.Bd.Schemas.issue_filename())

    {:ok, commit} = CommitStore.latest_commit(ctx.store, entry.node_id)

    assert is_binary(commit.signature)
    assert is_binary(commit.signer_id)
  end

  test "update with no opts stays unsigned (byte-compatible default)", ctx do
    {:ok, issue, dir_uuid} = Issue.create(ctx.root, %{title: "x"}, ctx.store)
    {:ok, _updated} = Issue.update(ctx.root, issue.id, %{status: "in_progress"}, ctx.store)

    {:ok, schema} = Commonplace.Bd.Schemas.load_dir_schema(dir_uuid, ctx.store)

    {:ok, entry} =
      Commonplace.Tree.Schema.get_entry(schema, Commonplace.Bd.Schemas.issue_filename())

    {:ok, commit} = CommitStore.latest_commit(ctx.store, entry.node_id)

    assert commit.signature == nil
    assert commit.signer_id == nil
  end
end
