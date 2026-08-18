defmodule Commonplace.ForkEnforceTest do
  @moduledoc """
  CX-ajdx: the wiki `fork` <action> was enforce-broken — it landed the
  fork genesis AND the root-schema attach UNSIGNED, so under
  `local_write_gate: :enforce` both were refused `:unsigned` and web fork
  failed. The fix threads the invoking session's `signing_context`
  (`signing_opts(context)`) through both writes, exactly like `pr_open`.

  Fixture mirrors `Commonplace.PrRefreshPreviewTest` — the `fork` handler
  talks to the default-named `CommitStore` via `CommitStoreClient` +
  `CommandRouter.fork/3`'s default `__MODULE__` server, so it needs the
  "root pointer file + running default CommitStore" fixture.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Crypto.{Signing, SigningContext}
  alias Commonplace.Store.CommitStore
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.{DocBuilder, Schema}
  alias Commonplace.ViewActionDispatch

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_fork_enforce_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    prior_data_dir = Application.get_env(:commonplace, :data_dir)
    prior_trust = Application.get_env(:commonplace, :trust)
    Application.put_env(:commonplace, :data_dir, dir)

    sup = Commonplace.Store.CommitStoreSupervisor
    _ = Supervisor.terminate_child(sup, Commonplace.Store.CommitStore)
    _ = Supervisor.delete_child(sup, Commonplace.Store.CommitStore)
    {:ok, _pid} = Supervisor.start_child(sup, {Commonplace.Store.CommitStore, data_dir: dir})

    Commonplace.Test.WorkspaceFixture.complete_workspace!(dir,
      store: Commonplace.Store.CommitStore
    )

    {pub, priv} = Signing.generate_keypair()
    identity = "test-fork-signer"
    sc = %SigningContext{identity_uuid: identity, private_key: priv, public_key: pub}

    # ENFORCE, with the fork signer pinned (root-write authority) so its
    # signed fork + attach land.
    Application.put_env(:commonplace, :trust, %{
      accept_unsigned: false,
      trusted_identities: %{identity => Signing.encode_key(pub)}
    })

    # Root doc must be signed under enforce.
    root_uuid = UUID.uuid4()
    root_update = Yelixer.Encoding.encode_update(Schema.new_schema())

    CommitStore.create_commit(Commonplace.Store.CommitStore, root_uuid, root_update, nil, %{},
      signing_context: sc
    )

    File.write!(Path.join(dir, "root"), root_uuid)

    on_exit(fn ->
      _ = Supervisor.terminate_child(sup, Commonplace.Store.CommitStore)
      _ = Supervisor.delete_child(sup, Commonplace.Store.CommitStore)
      restored_data_dir = prior_data_dir || "tmp/test_data"
      Application.put_env(:commonplace, :data_dir, restored_data_dir)

      case prior_trust do
        nil -> Application.delete_env(:commonplace, :trust)
        v -> Application.put_env(:commonplace, :trust, v)
      end

      File.rm_rf!(dir)

      {:ok, restored_pid} =
        Supervisor.start_child(sup, {Commonplace.Store.CommitStore, data_dir: restored_data_dir})

      assert Process.alive?(restored_pid)
      assert Process.whereis(Commonplace.Store.CommitStore) == restored_pid

      # sol/s-snapshot-fresh-s3: the store expands its data_dir at init (the
      # relative-path/cwd-split fix), so assert the EXPANDED path — the intent
      # is "the restored singleton points at this store", not a string form.
      assert CubDB.data_dir(CommitStore.db_handle(CommitStore)) ==
               Path.expand(Path.join(restored_data_dir, "commits"))
    end)

    %{root: root_uuid, sc: sc}
  end

  defp make_leaf(content, sc) do
    uuid = UUID.uuid4()
    doc = Commonplace.Document.ContentType.create(Yelixer.Doc.new(), :text, "doc.txt")
    doc = Commonplace.Document.ContentType.insert_text(doc, 0, content)
    update = Yelixer.Encoding.encode_update(doc)

    CommitStoreClient.create_commit(CommitStoreClient, uuid, update, nil, %{},
      signing_context: sc
    )

    uuid
  end

  test "CX-ajdx: a SIGNED fork lands under enforce (genesis + root attach)", %{sc: sc} do
    src = make_leaf("original wiki content", sc)

    context = %{view_uuid: src, signing_context: sc, source: "test"}

    assert {:ok, :tree_mutation, details} = ViewActionDispatch.dispatch("fork", context)
    assert details.action == "fork"
    assert is_binary(details.new_uuid)
    # the fork genesis actually landed (reconstructable) — proof it wasn't
    # refused :unsigned
    assert {:ok, doc} = DocBuilder.reconstruct_doc(CommitStoreClient, details.new_uuid)
    assert Commonplace.Document.ContentType.get_content(doc) =~ "original wiki content"
    # and it attached to root under enforce
    assert details.attached == true
  end

  test "CX-ajdx: the signed fork's attachment is reachable from the root schema under enforce",
       %{root: root, sc: sc} do
    src = make_leaf("original wiki content", sc)
    context = %{view_uuid: src, signing_context: sc, source: "test"}

    assert {:ok, :tree_mutation, details} = ViewActionDispatch.dispatch("fork", context)

    # The signed root-attach commit actually LANDED under enforce — the
    # fork-<uuid> entry is present in the reconstructed root schema (pre-fix
    # this attach was unsigned and refused).
    {:ok, root_doc} = DocBuilder.reconstruct_doc(CommitStoreClient, root)
    assert {:ok, entry} = Schema.get_entry(root_doc, details.attached_as)
    assert entry.node_id == details.new_uuid
  end
end
