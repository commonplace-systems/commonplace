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
end
