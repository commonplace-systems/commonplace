defmodule Commonplace.Bd.CloseCommitImportTest do
  @moduledoc """
  PERMANENT REGRESSION PIN — bd commit metadata must round-trip
  through `CommitStore.import_commit/3`.

  WHY THIS TEST EXISTS: the bd test suite (~140 tests) never imports
  a single commit — everything is exercised through local writes
  (`create_commit` / `create_chained_commit`), which never run
  `Commonplace.Store.Namespace`'s validator at all. That validator
  ONLY runs on `CommitStore.import_commit/3` — the front door for
  federation pull and BEAM-cluster catch-up sync. This means a change
  to the SHAPE of a bd commit's `metadata` can pass all ~140 local
  tests while silently breaking every bd write on the remote path,
  and nothing in the existing suite would catch it. This file is the
  pin for that gap: it is the only bd test that actually calls
  `import_commit/3`.

  THE CONCRETE HISTORY THAT MOTIVATED THIS (2026-08-05): a
  terminal-pin change made `Commonplace.Bd.Issue.close/4` stamp its
  commit's metadata as `%{kind: :regular, bd_terminal_pin: <json>}`
  instead of the legacy `%{}` every other bd write still uses.
  `Commonplace.Store.Namespace.do_validate/2` short-circuits
  `metadata == %{} -> :ok` unconditionally, but routes
  `Map.get(m, :kind) == :regular` into `validate_regular/3`, which
  requires a `:snapshot_parent` key. `CommitBuilder.stamp_snapshot_parent/4`
  could not compute one: it derives `snapshot_parent` from the
  PARENT commit's `Namespace.current_namespace/1`, and every prior bd
  commit was (and, per this test, still is) legacy `%{}` — whose
  `current_namespace/1` clause returns `nil`. So the close commit
  landed in its origin store with `kind: :regular` and NO
  `:snapshot_parent` at all, and `validate_regular/3`'s catch-all
  clause rejected it on import with
  `{:error, {:namespace_rejected, :missing_snapshot_parent}}` —
  every time, on every peer, unconditionally. A round-trip test
  proved this (control `%{}` commit: `:ok`; close commit:
  `{:error, {:namespace_rejected, :missing_snapshot_parent}}`) and
  the terminal-pin change was reverted on that evidence. Today's tree
  has bd's close commits back to plain `%{}` metadata, matching every
  other bd write.

  IF THIS TEST EVER FAILS: the first thing to suspect is a change to
  what `commit_metadata` (or equivalent) a `Commonplace.Bd.*` write
  path passes down to `CommitStoreClient` / `Schemas.write_text_doc/4`
  — anything that moves a bd commit's `metadata` off the legacy `%{}`
  shape without also correctly threading `:snapshot_parent` (or
  otherwise satisfying `Namespace.validate_commit_from_db/2`) will
  reproduce exactly this failure mode, invisibly to every other bd
  test.

  Isolation: every store here is its own tmp-dir `CommitStore` —
  never the real `.commonplace/` or `dogfood-mud/` workspace.
  """
  use ExUnit.Case

  alias Commonplace.Bd.{Issue, Schemas, Workspace}
  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.Schema
  alias Yelixer.Encoding

  setup do
    dir_a = Path.join(System.tmp_dir!(), "cp_bd_close_import_a_#{:rand.uniform(1_000_000)}")
    dir_create = Path.join(System.tmp_dir!(), "cp_bd_close_import_create_#{:rand.uniform(1_000_000)}")
    dir_update = Path.join(System.tmp_dir!(), "cp_bd_close_import_update_#{:rand.uniform(1_000_000)}")
    dir_close = Path.join(System.tmp_dir!(), "cp_bd_close_import_close_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir_a)
    File.mkdir_p!(dir_create)
    File.mkdir_p!(dir_update)
    File.mkdir_p!(dir_close)

    store_a = :"commit_store_close_import_a_#{:rand.uniform(1_000_000)}"
    store_create = :"commit_store_close_import_create_#{:rand.uniform(1_000_000)}"
    store_update = :"commit_store_close_import_update_#{:rand.uniform(1_000_000)}"
    store_close = :"commit_store_close_import_close_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir_a, name: store_a}, id: :store_a)
    start_supervised!({CommitStore, data_dir: dir_create, name: store_create}, id: :store_create)
    start_supervised!({CommitStore, data_dir: dir_update, name: store_update}, id: :store_update)
    start_supervised!({CommitStore, data_dir: dir_close, name: store_close}, id: :store_close)

    on_exit(fn ->
      File.rm_rf!(dir_a)
      File.rm_rf!(dir_create)
      File.rm_rf!(dir_update)
      File.rm_rf!(dir_close)
    end)

    root = UUID.uuid4()
    update = Encoding.encode_update(Schema.new_schema())
    CommitStore.create_commit(store_a, root, update, nil)

    %{
      store_a: store_a,
      store_create: store_create,
      store_update: store_update,
      store_close: store_close,
      root: root
    }
  end

  # Resolves the __issue.json meta-doc's node uuid, the same way
  # Commonplace.Bd.Invariants and the write-guard-import-bypass test
  # do.
  defp issue_meta_node_id(root, id, store) do
    {:ok, dir_uuid} = Workspace.issue_dir_uuid(root, id, store)
    {:ok, schema} = Schemas.load_dir_schema(dir_uuid, store)
    {:ok, entry} = Schema.get_entry(schema, Schemas.issue_filename())
    entry.node_id
  end

  # `CommitStore.commit_log/3` returns newest-first, so a straight
  # `Enum.reverse/1` gives oldest-first INCLUDING the newest (tested)
  # commit as the last element. This drops that last element so the
  # returned list is strictly the ancestry — everything BEFORE the
  # commit under test — leaving that commit's own `import_commit/3`
  # call to be the first time it's ever offered to the target store
  # (so a genuine first-time `:ok` is observable, not just
  # `:already_exists` from having been replayed a moment earlier).
  defp ancestry_of(store, node_id) do
    store
    |> CommitStore.commit_log(node_id, limit: CommitStore.max_commit_log_limit())
    |> Enum.reverse()
    |> Enum.drop(-1)
  end

  # Faithfully replays `commits` (a list, OLDEST-FIRST — caller's
  # responsibility to order it that way, so each parent lands before
  # its child) into `target_store` via the SAME import_commit/3 front
  # door under test.
  defp replay_chain(target_store, commits) do
    Enum.each(commits, fn commit ->
      result = CommitStore.import_commit(target_store, commit)

      assert result in [:ok, :already_exists],
             "chain replay failed on #{commit.id} (kind=#{inspect(Map.get(commit.metadata, :kind))}): #{inspect(result)}"
    end)
  end

  test "CREATE, UPDATE, and CLOSE commits all round-trip through import_commit/3 into an independent store",
       ctx do
    {:ok, a, _} = Issue.create(ctx.root, %{title: "A"}, ctx.store_a)
    node_id = issue_meta_node_id(ctx.root, a.id, ctx.store_a)

    # Ancestry of the CREATE commit (genesis only), excluding the
    # create commit itself.
    create_ancestry = ancestry_of(ctx.store_a, node_id)
    {:ok, create_commit} = CommitStore.latest_commit(ctx.store_a, node_id)

    # ---- UPDATE: an ordinary title change. ----
    {:ok, _a_updated} = Issue.update(ctx.root, a.id, %{title: "A, renamed"}, ctx.store_a)
    {:ok, update_commit} = CommitStore.latest_commit(ctx.store_a, node_id)
    update_ancestry = ancestry_of(ctx.store_a, node_id)

    # ---- CLOSE. ----
    {:ok, a_closed} = Issue.close(ctx.root, a.id, [reason: "done"], ctx.store_a)
    assert a_closed.status == "closed"
    {:ok, close_commit} = CommitStore.latest_commit(ctx.store_a, node_id)
    close_ancestry = ancestry_of(ctx.store_a, node_id)

    # Sanity: three genuinely distinct, causally-chained commits.
    assert update_commit.parent_id == create_commit.id
    assert close_commit.parent_id == update_commit.id

    # ---- Inspect actual metadata on all three (today's expected
    # shape: plain %{} on every bd write, close included). ----
    IO.puts("create_commit.metadata = #{inspect(create_commit.metadata)}")
    IO.puts("update_commit.metadata = #{inspect(update_commit.metadata)}")
    IO.puts("close_commit.metadata = #{inspect(close_commit.metadata)}")

    assert create_commit.metadata == %{}
    assert update_commit.metadata == %{}
    assert close_commit.metadata == %{}

    # ---- Round-trip each commit, with its own full ancestry
    # faithfully replayed first, into its own independent target
    # store. ----
    replay_chain(ctx.store_create, create_ancestry)
    create_import_result = CommitStore.import_commit(ctx.store_create, create_commit)
    IO.puts("CREATE import_commit/3 result: #{inspect(create_import_result)}")

    replay_chain(ctx.store_update, update_ancestry)
    update_import_result = CommitStore.import_commit(ctx.store_update, update_commit)
    IO.puts("UPDATE import_commit/3 result: #{inspect(update_import_result)}")

    replay_chain(ctx.store_close, close_ancestry)
    close_import_result = CommitStore.import_commit(ctx.store_close, close_commit)
    IO.puts("CLOSE import_commit/3 result: #{inspect(close_import_result)}")

    # ---- The pin: every kind of bd write commit is ACCEPTED on
    # import into an independent store. ----
    assert create_import_result in [:ok, :already_exists],
           "CREATE commit failed to import: #{inspect(create_import_result)}"

    assert update_import_result in [:ok, :already_exists],
           "UPDATE commit failed to import: #{inspect(update_import_result)}"

    assert close_import_result in [:ok, :already_exists],
           "CLOSE commit failed to import: #{inspect(close_import_result)} — " <>
             "this is the exact failure mode of the 2026-08-05 terminal-pin regression " <>
             "({:error, {:namespace_rejected, :missing_snapshot_parent}}); the first " <>
             "suspect is any change to what commit_metadata a Commonplace.Bd.* write " <>
             "path now passes down."
  end
end
