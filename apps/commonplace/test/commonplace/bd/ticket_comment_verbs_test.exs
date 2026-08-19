defmodule Commonplace.Bd.TicketCommentVerbsTest do
  @moduledoc """
  CX-xmsd, defect layers 2 and 3: the GATED comment surface
  (`ticket_comment`, `ticket_comments_import`) and the retirement of
  the ungated door (`Bd.Importer.import_comments_jsonl/4`).

  Layer 2 was the reporting: the old importer swallowed both parse
  failures and add failures (`_ -> acc`) and returned
  `{:ok, %{imported: count}}` — a count of its own ATTEMPTS. Layer 3
  was the field shape: `bd export` writes the body as `text`, the
  importer read `body`, so even a signed import would have landed 196
  empty comments.

  Every test that claims a write landed also counts the DESTINATION
  (`Comment.list/3`), per the ticket's parent principle: a success
  report is a claim by the writer about itself.

  Runs under Mode-B enforce with a pinned identity throughout, because
  a permissive posture would let an unsigned write land and make the
  signing-context threading untestable — the exact hole that hid this
  bug for a day.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Bd.{Comment, Importer, Issue, RetiredGraphError}
  alias Commonplace.Crypto.{Signing, SigningContext}
  alias Commonplace.Store.CommitStore
  alias Commonplace.Trust.AuditLog
  alias Commonplace.Tree.Schema
  alias Commonplace.ViewActionDispatch
  alias Yelixer.Encoding

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_bd_comment_verbs_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    n = :rand.uniform(1_000_000_000)
    store = :"tcv_store_#{n}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: dir,
       name: :"tcv_sup_#{n}",
       commit_store_name: store,
       trust_side_store_name: :"tcv_tss_#{n}",
       pending_imports_name: :"tcv_pi_#{n}"}
    )

    AuditLog.reset_rate_table()

    old_gate = Application.get_env(:commonplace, :local_write_gate)
    old_trust = Application.get_env(:commonplace, :trust)

    on_exit(fn ->
      if old_gate,
        do: Application.put_env(:commonplace, :local_write_gate, old_gate),
        else: Application.delete_env(:commonplace, :local_write_gate)

      if old_trust,
        do: Application.put_env(:commonplace, :trust, old_trust),
        else: Application.delete_env(:commonplace, :trust)

      File.rm_rf!(dir)
    end)

    Application.put_env(:commonplace, :local_write_gate, :off)
    Application.delete_env(:commonplace, :trust)

    root = UUID.uuid4()
    CommitStore.create_commit(store, root, Encoding.encode_update(Schema.new_schema()), nil)
    {:ok, issue, _} = Issue.create(root, %{title: "host"}, store)

    {pub, priv} = Signing.generate_keypair()
    identity = "cx-xmsd-verb-writer"
    ctx = %SigningContext{identity_uuid: identity, private_key: priv, public_key: pub}

    # Mode-B enforce, this identity pinned: the posture the migration
    # actually runs under.
    Application.put_env(:commonplace, :trust, %{
      accept_unsigned: false,
      trusted_identities: %{identity => Signing.encode_key(pub)}
    })

    Application.put_env(:commonplace, :local_write_gate, :enforce)

    %{store: store, root: root, ticket: issue.id, ctx: ctx}
  end

  defp dispatch(action, args, ctx, extra \\ %{}) do
    ViewActionDispatch.dispatch(
      action,
      Map.merge(
        %{
          args: args,
          root_uuid: ctx.root,
          store: ctx.store,
          signing_context: ctx.ctx,
          source: "test"
        },
        extra
      )
    )
  end

  describe "ticket_comment (single, gated)" do
    test "lands a signed comment under enforce — counted at the destination", ctx do
      assert {:ok, :tree_mutation, details} =
               dispatch("ticket_comment", %{"ticket" => ctx.ticket, "body" => "hello"}, ctx)

      assert details.action == "ticket_comment"
      assert details.op == :created
      assert details.comment.body == "hello"

      assert [stored] = Comment.list(ctx.root, ctx.ticket, ctx.store)
      assert stored.body == "hello"
      assert stored.id == details.comment.id
    end

    test "WITHOUT a signing context the verb reports the denial, and nothing lands", ctx do
      assert {:error, reason} =
               ViewActionDispatch.dispatch("ticket_comment", %{
                 args: %{"ticket" => ctx.ticket, "body" => "unsigned"},
                 root_uuid: ctx.root,
                 store: ctx.store,
                 source: "test"
               })

      assert reason =~ "comment_write_failed"
      assert Comment.list(ctx.root, ctx.ticket, ctx.store) == []
    end

    test "shape checks: body must be a non-empty string, ticket must load", ctx do
      assert {:error, r1} = dispatch("ticket_comment", %{"ticket" => ctx.ticket}, ctx)
      assert r1 =~ "body"

      assert {:error, r2} =
               dispatch("ticket_comment", %{"ticket" => ctx.ticket, "body" => 42}, ctx)

      assert r2 =~ "must be a string"

      assert {:error, r3} =
               dispatch("ticket_comment", %{"ticket" => "CX-nope", "body" => "x"}, ctx)

      assert r3 =~ "ticket not found"

      assert {:error, r4} = ViewActionDispatch.dispatch("ticket_comment", %{source: "test"})
      assert r4 =~ "ticket_comment requires args map"

      assert Comment.list(ctx.root, ctx.ticket, ctx.store) == []
    end

    test "author, id and created_at ride through, and a re-send is a no-op", ctx do
      args = %{
        "ticket" => ctx.ticket,
        "body" => "pinned",
        "author" => "alice",
        "id" => "c-pinned1",
        "created_at" => "2026-02-02T00:00:00Z"
      }

      assert {:ok, :tree_mutation, %{op: :created}} = dispatch("ticket_comment", args, ctx)
      assert {:ok, :tree_mutation, %{op: :noop}} = dispatch("ticket_comment", args, ctx)

      assert [stored] = Comment.list(ctx.root, ctx.ticket, ctx.store)
      assert stored.id == "c-pinned1"
      assert stored.author == "alice"
      assert stored.created_at == "2026-02-02T00:00:00Z"
    end
  end

  describe "ticket_comments_import: declared == landed + noop + refused" do
    # The bd wire shape, verbatim from a real export row: the body is
    # `text`, the id is a UUIDv7, and `issue_id` is carried but ignored.
    defp bd_comment(id, text) do
      %{
        "id" => id,
        "issue_id" => "CX-whatever",
        "author" => "Jes Wolfe!",
        "text" => text,
        "created_at" => "2026-06-10T18:42:00Z"
      }
    end

    test "a mixed batch accounts for every ARRIVING record, refusals named", ctx do
      records = [
        bd_comment("019eb2d7-d95e-7184-a0d6-9de7a813d426", "first from the archive"),
        # malformed: no body under either key
        %{"id" => "019eb2d7-0000-7184-a0d6-9de7a813d999", "author" => "nobody"},
        # malformed: not an object at all
        "just a string",
        # a second good one
        bd_comment("019eb2d7-d680-75ce-9a2f-7f2637675dea", "second from the archive")
      ]

      assert {:ok, :tree_mutation, r} =
               dispatch(
                 "ticket_comments_import",
                 %{"ticket" => ctx.ticket, "records" => records},
                 ctx
               )

      assert r.declared == 4, "the denominator is what ARRIVED, not what survived"
      assert length(r.landed) == 2
      assert r.noop == []
      assert length(r.refused) == 2
      assert r.unaccounted == []
      assert r.identity_holds?

      # Refusals are NAMED, not counted.
      reasons = Map.new(r.refused, fn x -> {x.id, x.reason} end)
      assert reasons["019eb2d7-0000-7184-a0d6-9de7a813d999"] =~ "missing_body"
      assert reasons["<comment #2: no id>"] =~ "malformed_record"

      # THE DESTINATION.
      landed = Comment.list(ctx.root, ctx.ticket, ctx.store)
      assert length(landed) == 2

      assert Enum.map(landed, & &1.body) |> Enum.sort() ==
               ["first from the archive", "second from the archive"]
    end

    test "re-running the same batch is all no-op, destination unchanged", ctx do
      records = [
        bd_comment("019eb2d7-d95e-7184-a0d6-9de7a813d426", "once"),
        bd_comment("019eb2d7-d680-75ce-9a2f-7f2637675dea", "twice")
      ]

      args = %{"ticket" => ctx.ticket, "records" => records}

      assert {:ok, :tree_mutation, first} = dispatch("ticket_comments_import", args, ctx)
      assert length(first.landed) == 2
      before = Comment.list(ctx.root, ctx.ticket, ctx.store)

      assert {:ok, :tree_mutation, second} = dispatch("ticket_comments_import", args, ctx)
      assert second.landed == []
      assert length(second.noop) == 2
      assert second.declared == 2
      assert second.unaccounted == []
      assert second.identity_holds?

      after_ = Comment.list(ctx.root, ctx.ticket, ctx.store)
      assert Enum.map(after_, & &1.id) == Enum.map(before, & &1.id)
      assert length(after_) == 2
    end

    test "a duplicate id inside ONE batch lands once and no-ops once", ctx do
      dup = bd_comment("019eb2d7-d95e-7184-a0d6-9de7a813d426", "same bytes twice")

      assert {:ok, :tree_mutation, r} =
               dispatch(
                 "ticket_comments_import",
                 %{"ticket" => ctx.ticket, "records" => [dup, dup]},
                 ctx
               )

      assert r.declared == 2
      assert length(r.landed) == 1
      assert length(r.noop) == 1
      assert r.identity_holds?
      assert length(Comment.list(ctx.root, ctx.ticket, ctx.store)) == 1
    end

    test "same id, DIFFERENT content is a named refusal — never an overwrite", ctx do
      first = bd_comment("019eb2d7-d95e-7184-a0d6-9de7a813d426", "the original text")
      rewritten = bd_comment("019eb2d7-d95e-7184-a0d6-9de7a813d426", "a rewrite")

      assert {:ok, :tree_mutation, _} =
               dispatch(
                 "ticket_comments_import",
                 %{"ticket" => ctx.ticket, "records" => [first]},
                 ctx
               )

      assert {:ok, :tree_mutation, r} =
               dispatch(
                 "ticket_comments_import",
                 %{"ticket" => ctx.ticket, "records" => [rewritten]},
                 ctx
               )

      assert [%{reason: reason}] = r.refused
      assert reason =~ "exists_with_different_content"
      assert [%{body: "the original text"}] = Comment.list(ctx.root, ctx.ticket, ctx.store)
    end

    test "LAYER 3: the archive's `text` becomes the body, non-empty", ctx do
      record = bd_comment("019eb2d7-aaaa-7184-a0d6-9de7a813d426", "DIRECTION GIVEN: in scope.")

      assert {:ok, :tree_mutation, r} =
               dispatch(
                 "ticket_comments_import",
                 %{"ticket" => ctx.ticket, "records" => [record]},
                 ctx
               )

      assert length(r.landed) == 1

      assert [stored] = Comment.list(ctx.root, ctx.ticket, ctx.store)
      assert stored.body == "DIRECTION GIVEN: in scope."
      assert stored.body != ""
      assert stored.author == "Jes Wolfe!"
      assert stored.created_at == "2026-06-10T18:42:00Z"
      assert stored.id == "019eb2d7-aaaa-7184-a0d6-9de7a813d426"
    end

    test "our own `body` key wins over `text` when both are present", ctx do
      record =
        bd_comment("019eb2d7-bbbb-7184-a0d6-9de7a813d426", "the archive text")
        |> Map.put("body", "our body")

      assert {:ok, :tree_mutation, _} =
               dispatch(
                 "ticket_comments_import",
                 %{"ticket" => ctx.ticket, "records" => [record]},
                 ctx
               )

      assert [%{body: "our body"}] = Comment.list(ctx.root, ctx.ticket, ctx.store)
    end

    test "shape checks: ticket must load, records must be a list", ctx do
      assert {:error, r1} =
               dispatch("ticket_comments_import", %{"ticket" => ctx.ticket}, ctx)

      assert r1 =~ "records"

      assert {:error, r2} =
               dispatch(
                 "ticket_comments_import",
                 %{"ticket" => "CX-nope", "records" => []},
                 ctx
               )

      assert r2 =~ "ticket not found"

      assert {:error, r3} = ViewActionDispatch.dispatch("ticket_comments_import", %{})
      assert r3 =~ "requires args map"
    end

    test "an EMPTY batch is a live zero, not a vacuous pass", ctx do
      assert {:ok, :tree_mutation, r} =
               dispatch("ticket_comments_import", %{"ticket" => ctx.ticket, "records" => []}, ctx)

      assert r.declared == 0
      assert r.landed == []
      assert r.identity_holds?
      assert Comment.list(ctx.root, ctx.ticket, ctx.store) == []
    end
  end

  describe "normalize_comment_record/1 (pure)" do
    test "carries the archive fields and refuses the unusable ones" do
      assert {:ok, attrs, "abc"} =
               Importer.normalize_comment_record(%{
                 "id" => "abc",
                 "text" => "body from text",
                 "author" => "a",
                 "created_at" => "t",
                 "reply_to" => "c-1"
               })

      assert attrs == %{
               id: "abc",
               body: "body from text",
               author: "a",
               created_at: "t",
               reply_to: "c-1"
             }

      # No id is legal — one gets minted.
      assert {:ok, %{body: "x"}, nil} = Importer.normalize_comment_record(%{"text" => "x"})

      # A present-but-unusable id is not: it would mint a different
      # comment on every re-run and defeat idempotency.
      assert {:error, {:unusable_id, 7}} =
               Importer.normalize_comment_record(%{"id" => 7, "text" => "x"})

      assert {:error, :missing_body} = Importer.normalize_comment_record(%{"id" => "a"})
      assert {:error, :empty_body} = Importer.normalize_comment_record(%{"text" => ""})
      assert {:error, :malformed_record} = Importer.normalize_comment_record("nope")
      assert {:error, :malformed_record} = Importer.normalize_comment_record(nil)
    end
  end

  describe "the ungated door is retired (CX-xmsd layer 2)" do
    test "import_comments_jsonl/4 raises and names its replacement", ctx do
      assert_raise RetiredGraphError, ~r/ticket_comments_import/, fn ->
        Importer.import_comments_jsonl(
          ctx.root,
          ctx.ticket,
          ~s({"id":"c-1","text":"x"}),
          ctx.store
        )
      end

      assert Comment.list(ctx.root, ctx.ticket, ctx.store) == []
    end

    test "the notice says WHY, not just that it is gone", ctx do
      err =
        assert_raise RetiredGraphError, fn ->
          Importer.import_comments_jsonl(ctx.root, ctx.ticket, "", ctx.store)
        end

      assert err.surface == "Commonplace.Bd.Importer.import_comments_jsonl/4"
      assert err.message =~ "RETIRED"
      assert err.message =~ "denied at the store gate"
      assert err.message =~ "DECLARED denominator"
      assert err.message =~ "CX-xmsd"
    end
  end
end
