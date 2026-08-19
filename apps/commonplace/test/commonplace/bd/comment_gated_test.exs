defmodule Commonplace.Bd.CommentGatedTest do
  @moduledoc """
  CX-xmsd, defect layer 1: `Commonplace.Bd.Comment` reported success for
  writes the store had denied.

  Parent principle (boss 2026-08-05, verbatim in CX-xmsd): **a success
  report is a claim BY THE WRITER ABOUT ITSELF** — `{:ok, %Comment{}}`
  is equally consistent with wrote-everything, wrote-nothing, and
  never-tried. Only the DESTINATION count separates them, so every
  test below that claims a write landed also counts `Comment.list/3`.

  The first test is the RED-FIRST CONTROL: it was written against the
  OLD library and watched fail (old `add/4` returned `{:ok, %Comment{}}`
  under Mode-B enforce while the comments dir stayed empty). It is the
  restore-the-bug detector — revert the `add/5` result checks and this
  goes red again.

  Enforce-mode harness mirrors
  `Commonplace.Trust.AuditChokePerfTest`'s setup (Store.Supervisor trio
  under unique names, trust env saved/restored, rate table reset) so a
  denial-heavy neighbour cannot suppress or leak into this file.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Bd.{Comment, Issue}
  alias Commonplace.Crypto.{Signing, SigningContext}
  alias Commonplace.Store.CommitStore
  alias Commonplace.Trust.AuditLog
  alias Commonplace.Tree.Schema
  alias Yelixer.Encoding

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_bd_comment_gated_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    n = :rand.uniform(1_000_000_000)
    store = :"cg_store_#{n}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: dir,
       name: :"cg_sup_#{n}",
       commit_store_name: store,
       trust_side_store_name: :"cg_tss_#{n}",
       pending_imports_name: :"cg_pi_#{n}"}
    )

    AuditLog.reset_rate_table()

    old_gate = Application.get_env(:commonplace, :local_write_gate)
    old_trust = Application.get_env(:commonplace, :trust)

    on_exit(fn ->
      put_or_del(:local_write_gate, old_gate)
      put_or_del(:trust, old_trust)
      File.rm_rf!(dir)
    end)

    # Build the host issue PERMISSIVELY — this file's subject is the
    # comment write, not the ticket write, and a denied fixture would
    # make every assertion below vacuous.
    Application.put_env(:commonplace, :local_write_gate, :off)
    Application.delete_env(:commonplace, :trust)

    root = UUID.uuid4()
    CommitStore.create_commit(store, root, Encoding.encode_update(Schema.new_schema()), nil)
    {:ok, issue, _} = Issue.create(root, %{title: "host"}, store)

    {pub, priv} = Signing.generate_keypair()
    identity = "cx-xmsd-comment-writer"

    ctx = %SigningContext{identity_uuid: identity, private_key: priv, public_key: pub}

    %{
      store: store,
      root: root,
      issue_id: issue.id,
      ctx: ctx,
      identity: identity,
      pub: pub
    }
  end

  defp put_or_del(key, nil), do: Application.delete_env(:commonplace, key)
  defp put_or_del(key, v), do: Application.put_env(:commonplace, key, v)

  defp strict!(trusted \\ %{}) do
    Application.put_env(:commonplace, :trust, %{
      accept_unsigned: false,
      trusted_identities: trusted
    })
  end

  defp enforce!, do: Application.put_env(:commonplace, :local_write_gate, :enforce)

  describe "RED-FIRST CONTROL: a denied comment write must not report success" do
    test "unsigned add under Mode-B enforce is an error, and lands nothing", ctx do
      strict!()
      enforce!()

      result = Comment.add(ctx.root, ctx.issue_id, %{body: "denied", author: "alice"}, ctx.store)

      assert {:error, {:comment_write_failed, stage, _reason}} = result,
             "add reported #{inspect(result)} for a write the store denied — " <>
               "phantom success (CX-xmsd layer 1)"

      assert stage in [:doc_create, :entry_attach]

      # The destination, not the writer's own claim.
      assert Comment.list(ctx.root, ctx.issue_id, ctx.store) == []
    end
  end

  describe "the signed path lands, counted at the destination" do
    test "signed adds under enforce land, and list/3 counts every one", ctx do
      strict!(%{ctx.identity => Signing.encode_key(ctx.pub)})
      enforce!()
      opts = [signing_context: ctx.ctx]

      assert {:ok, c1} =
               Comment.add(ctx.root, ctx.issue_id, %{body: "first", author: "a"}, ctx.store, opts)

      assert {:ok, c2} =
               Comment.add(
                 ctx.root,
                 ctx.issue_id,
                 %{body: "second", author: "b"},
                 ctx.store,
                 opts
               )

      landed = Comment.list(ctx.root, ctx.issue_id, ctx.store)

      assert length(landed) == 2, "writer claimed 2, destination holds #{length(landed)}"
      assert Enum.map(landed, & &1.id) |> Enum.sort() == Enum.sort([c1.id, c2.id])
      assert Enum.map(landed, & &1.body) |> Enum.sort() == ["first", "second"]
    end

    test "edit and soft_delete report the store's answer too", ctx do
      strict!(%{ctx.identity => Signing.encode_key(ctx.pub)})
      enforce!()
      opts = [signing_context: ctx.ctx]

      {:ok, c} = Comment.add(ctx.root, ctx.issue_id, %{body: "v1"}, ctx.store, opts)

      assert {:ok, edited} = Comment.edit(ctx.root, ctx.issue_id, c.id, "v2", ctx.store, opts)
      assert edited.body == "v2"
      assert [%{body: "v2"}] = Comment.list(ctx.root, ctx.issue_id, ctx.store)

      # UNSIGNED edit under the same posture: denied, and it must say so.
      assert {:error, {:comment_write_failed, :body_write, _}} =
               Comment.edit(ctx.root, ctx.issue_id, c.id, "v3", ctx.store)

      assert [%{body: "v2"}] = Comment.list(ctx.root, ctx.issue_id, ctx.store)

      assert {:error, {:comment_write_failed, :body_write, _}} =
               Comment.soft_delete(ctx.root, ctx.issue_id, c.id, ctx.store)

      assert [%{deleted: false}] = Comment.list(ctx.root, ctx.issue_id, ctx.store)

      assert {:ok, _} = Comment.soft_delete(ctx.root, ctx.issue_id, c.id, ctx.store, opts)
      assert [%{deleted: true}] = Comment.list(ctx.root, ctx.issue_id, ctx.store)
    end
  end

  describe "idempotency for the backfill (supplied id)" do
    setup ctx do
      strict!(%{ctx.identity => Signing.encode_key(ctx.pub)})
      enforce!()
      %{opts: [signing_context: ctx.ctx]}
    end

    test "a byte-identical re-add is a no-op, not a second comment", ctx do
      attrs = %{
        id: "c-fixed01",
        body: "same bytes",
        author: "a",
        created_at: "2026-01-01T00:00:00Z"
      }

      assert {:ok, %{id: "c-fixed01"}} =
               Comment.add(ctx.root, ctx.issue_id, attrs, ctx.store, ctx.opts)

      assert {:ok, :noop} = Comment.add(ctx.root, ctx.issue_id, attrs, ctx.store, ctx.opts)

      assert length(Comment.list(ctx.root, ctx.issue_id, ctx.store)) == 1
    end

    test "same id, different content is a NAMED refusal — never an overwrite", ctx do
      base = %{id: "c-fixed02", body: "original", created_at: "2026-01-01T00:00:00Z"}

      assert {:ok, _} = Comment.add(ctx.root, ctx.issue_id, base, ctx.store, ctx.opts)

      assert {:error, {:exists_with_different_content, "c-fixed02"}} =
               Comment.add(
                 ctx.root,
                 ctx.issue_id,
                 %{base | body: "rewritten"},
                 ctx.store,
                 ctx.opts
               )

      assert [%{body: "original"}] = Comment.list(ctx.root, ctx.issue_id, ctx.store)
    end

    test "a bd UUIDv7 comment id survives the round trip and is LISTABLE", ctx do
      # The shape the archive actually carries. Before CX-xmsd widened
      # `comment_filename?/1`, this landed a doc that `list/3` filtered
      # out — stored, referenced, and invisible.
      attrs = %{
        id: "019eb2d7-d95e-7184-a0d6-9de7a813d426",
        body: "from the bd archive",
        author: "Jes Wolfe!",
        created_at: "2026-06-10T18:42:00Z"
      }

      assert {:ok, _} = Comment.add(ctx.root, ctx.issue_id, attrs, ctx.store, ctx.opts)

      assert [%{id: "019eb2d7-d95e-7184-a0d6-9de7a813d426", body: "from the bd archive"}] =
               Comment.list(ctx.root, ctx.issue_id, ctx.store)

      assert {:ok, :noop} = Comment.add(ctx.root, ctx.issue_id, attrs, ctx.store, ctx.opts)
    end

    test "an id that list/3 could never show is refused before any write", ctx do
      assert {:error, {:unlistable_comment_id, "Not A Comment Id"}} =
               Comment.add(
                 ctx.root,
                 ctx.issue_id,
                 %{id: "Not A Comment Id", body: "x"},
                 ctx.store,
                 ctx.opts
               )

      assert Comment.list(ctx.root, ctx.issue_id, ctx.store) == []
    end
  end

  describe "the phantom guard: a failed entry-attach is named, and attaches nothing" do
    # The failure is forced with `:expect_parent` — the store's
    # strict-CAS option, which makes `create_chained_commit/5` refuse
    # with `{:error, :parent_moved}`. Deliberately NOT a trust denial:
    # the only way to deny the SECOND commit but not the first is to
    # flip the global gate env from inside the store process mid-call,
    # which would leak into any async test file running beside this
    # one. The store hands both refusals back in the same shape
    # (`{:error, reason}`) at the same call, so the boundary under test
    # is identical, and the property asserted — stage named, orphan
    # named, NOTHING attached — is what matters.
    #
    # `:expect_parent` is ignored by `create_commit/6`, so stage 1 (the
    # comment doc) lands and only stage 2 (the comments-dir chained
    # commit) is refused. That ordering is the point: an entry pointing
    # at an unstored doc must be impossible.
    test "the error names :entry_attach and the orphan, and the dir schema is untouched", ctx do
      strict!(%{ctx.identity => Signing.encode_key(ctx.pub)})
      enforce!()

      opts = [signing_context: ctx.ctx, expect_parent: "0000000000000000000000000000000000000000"]

      assert {:error, {:comment_write_failed, :entry_attach, detail}} =
               Comment.add(ctx.root, ctx.issue_id, %{id: "c-orphan1", body: "x"}, ctx.store, opts)

      assert %{reason: :parent_moved, orphan_doc_uuid: orphan} = detail
      assert is_binary(orphan)

      # The orphan really is in the store (that is why it is reported)...
      assert {:ok, _commit} = Commonplace.Store.CommitStore.latest_commit(ctx.store, orphan)

      # ...and nothing points at it.
      {:ok, issue_dir} =
        Commonplace.Bd.Workspace.issue_dir_uuid(ctx.root, ctx.issue_id, ctx.store)

      {:ok, issue_schema} = Commonplace.Bd.Schemas.load_dir_schema(issue_dir, ctx.store)
      {:ok, comments_entry} = Schema.get_entry(issue_schema, "comments")

      {:ok, comments_schema} =
        Commonplace.Bd.Schemas.load_dir_schema(comments_entry.node_id, ctx.store)

      assert :error = Schema.get_entry(comments_schema, "c-orphan1.json")
      assert Comment.list(ctx.root, ctx.issue_id, ctx.store) == []
    end
  end
end
