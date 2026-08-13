defmodule Commonplace.Cell.ManifestTest do
  use ExUnit.Case, async: false

  alias Commonplace.Cell.Manifest
  alias Commonplace.Crypto.NodeIdentity
  alias Commonplace.Document.ContentType
  alias Commonplace.Store.{CommitStore, CommitStoreClient}
  alias Commonplace.Tree.{DocBuilder, Schema}
  alias Commonplace.Workspace

  @cid String.duplicate("a", 64)

  setup do
    data_dir =
      Path.join(System.tmp_dir!(), "cp_cell_manifest_#{System.unique_integer([:positive])}")

    checkout_dir = Path.join(data_dir, "checkout")
    File.mkdir_p!(checkout_dir)

    store = :"cell_manifest_store_#{System.unique_integer([:positive])}"
    start_supervised!({CommitStore, data_dir: data_dir, name: store})

    prior_data_dir = Application.get_env(:commonplace, :data_dir)
    Application.put_env(:commonplace, :data_dir, data_dir)

    on_exit(fn ->
      Application.put_env(:commonplace, :data_dir, prior_data_dir || "tmp/test_data")
      File.rm_rf!(data_dir)
    end)

    {:ok, signing_context} = NodeIdentity.signing_context()

    %{
      data_dir: data_dir,
      checkout_dir: checkout_dir,
      store: store,
      signing_context: signing_context
    }
  end

  test "a full manifest round-trips byte-stably" do
    manifest = valid_manifest()
    assert :ok = Manifest.validate(manifest)
    assert {:ok, encoded} = Manifest.encode(manifest)
    assert {:ok, decoded} = Manifest.decode(encoded)
    assert {:ok, ^encoded} = Manifest.encode(decoded)
  end

  test "validator refusals name the failing field" do
    cases = [
      {Map.delete(valid_manifest(), :mission), "mission"},
      {%{valid_manifest() | workspace_class: "unknown"}, "workspace_class"},
      {%{valid_manifest() | auditors: [valid_manifest().principal]}, "auditors"},
      {%{valid_manifest() | sla: %{tier: "best-effort", retention: nil, note: nil}}, "sla.tier"},
      {%{valid_manifest() | sla: %{tier: "ephemeral", retention: nil, note: nil}},
       "sla.retention"},
      {%{valid_manifest() | sla: %{tier: "compactable", retention: nil, note: nil}},
       "sla.retention"},
      {%{valid_manifest() | sync_scope: %{rule: "git-tracked-set", binary_extensions: []}},
       "sync_scope.excludes"},
      {%{
         valid_manifest()
         | authority: %{certs: ["not-a-cid"], authors_code: false, scope_note: nil}
       }, "authority.certs"}
    ]

    for {manifest, field} <- cases do
      assert {:error, {:invalid_manifest, ^field, _reason}} = Manifest.validate(manifest)
    end
  end

  test "all three SLA tiers retain their declared validation behavior" do
    assert :ok =
             Manifest.validate(%{
               valid_manifest()
               | sla: %{tier: "durable", retention: nil, note: nil}
             })

    assert :ok =
             Manifest.validate(%{
               valid_manifest()
               | sla: %{tier: "compactable", retention: "after-snapshot", note: nil}
             })

    assert :ok =
             Manifest.validate(%{
               valid_manifest()
               | sla: %{tier: "ephemeral", retention: "30 days", note: nil}
             })

    assert {:error, {:invalid_manifest, "sla.retention", reason}} =
             Manifest.validate(%{
               valid_manifest()
               | sla: %{tier: "ephemeral", retention: nil, note: nil}
             })

    assert reason == "is required for ephemeral SLA"
  end

  test "pin promotion and tier promises are observed answering both ways" do
    protected = %{pinned?: true, snapshot?: false, tip?: false, witnessed?: false}

    for tier <- ~w(durable compactable ephemeral) do
      assert Manifest.survives_sla?(tier, protected)
    end

    refute Manifest.survives_sla?("ephemeral", %{
             pinned?: false,
             snapshot?: false,
             tip?: false,
             witnessed?: false
           })
  end

  test "temporal read marks pre-field default and stored cases", ctx do
    pre_root = initialize!(ctx, :default)

    assert {:ok, %{case: :pre_field_default, workspace_class: :default}} =
             Manifest.read(pre_root, ctx.store)

    post_root = initialize!(ctx, :minimal)

    assert {:ok, _manifest} =
             Manifest.create(post_root, valid_manifest(), ctx.store,
               signing_context: ctx.signing_context
             )

    assert {:ok, %{case: :stored, manifest: %Manifest{id: "cell-test"}}} =
             Manifest.read(post_root, ctx.store)
  end

  test "backfill is confirmation-gated, re-read verified, and idempotent", ctx do
    root = initialize!(ctx, :minimal)

    assert {:error, :confirmation_required} =
             Manifest.backfill(root, valid_manifest(), ctx.store,
               signing_context: ctx.signing_context
             )

    assert {:ok, %{result: :backfilled, manifest: %Manifest{id: "cell-test"}}} =
             Manifest.backfill(root, valid_manifest(), ctx.store,
               confirm: true,
               signing_context: ctx.signing_context
             )

    {:ok, root_doc} = DocBuilder.reconstruct_snapshot(ctx.store, root)
    assert {:ok, entry} = Schema.get_entry(root_doc, "__cell.json")
    assert {:ok, manifest_doc} = DocBuilder.reconstruct_snapshot(ctx.store, entry.node_id)

    assert {:ok, %Manifest{id: "cell-test"}} =
             manifest_doc |> ContentType.get_content() |> Manifest.decode()

    {:ok, before_commit} = CommitStoreClient.latest_commit(ctx.store, entry.node_id)

    assert {:ok, %{result: :already_present, manifest: %Manifest{id: "cell-test"}}} =
             Manifest.backfill(root, valid_manifest(), ctx.store,
               confirm: true,
               signing_context: ctx.signing_context
             )

    assert {:ok, after_commit} = CommitStoreClient.latest_commit(ctx.store, entry.node_id)
    assert after_commit.id == before_commit.id
  end

  test "create and amend use the signed commit seams and re-read their effects", ctx do
    root = initialize!(ctx, :minimal)

    assert {:ok, %Manifest{mission: "Exercise the manifest contract"}} =
             Manifest.create(root, valid_manifest(), ctx.store,
               signing_context: ctx.signing_context
             )

    {:ok, root_doc} = DocBuilder.reconstruct_snapshot(ctx.store, root)
    assert {:ok, entry} = Schema.get_entry(root_doc, "__cell.json")
    assert {:ok, root_commit} = CommitStoreClient.latest_commit(ctx.store, root)
    assert {:ok, create_commit} = CommitStoreClient.latest_commit(ctx.store, entry.node_id)
    assert root_commit.signature != nil
    assert create_commit.signature != nil

    amended = %{valid_manifest() | mission: "Exercise the amended manifest contract"}

    assert {:ok, %Manifest{mission: "Exercise the amended manifest contract"}} =
             Manifest.amend(root, amended, ctx.store, signing_context: ctx.signing_context)

    assert {:ok, amend_commit} = CommitStoreClient.latest_commit(ctx.store, entry.node_id)
    assert amend_commit.id != create_commit.id
    assert amend_commit.signature != nil

    assert {:ok,
            %{
              case: :stored,
              manifest: %Manifest{mission: "Exercise the amended manifest contract"}
            }} = Manifest.read(root, ctx.store)
  end

  defp initialize!(ctx, profile) do
    checkout_dir =
      Path.join(ctx.checkout_dir, "#{profile}-#{System.unique_integer([:positive])}")

    File.mkdir_p!(checkout_dir)

    {:ok, initialized} =
      Workspace.initialize(ctx.data_dir,
        store: ctx.store,
        checkout_dir: checkout_dir,
        profile: profile
      )

    initialized.root_uuid
  end

  defp valid_manifest do
    %{
      id: "cell-test",
      parent: "commonplace-factory",
      mission: "Exercise the manifest contract",
      principal: "principal-a",
      workspace_class: "minimal",
      root_entries: [],
      authority: %{certs: [@cid], authors_code: false, scope_note: nil},
      sync_scope: %{rule: "git-tracked-set", excludes: [".beads"], binary_extensions: []},
      sla: %{tier: "durable", retention: "indefinite", note: nil},
      environments: %{may_declare: false, requires_allowed: []},
      stewards: ["principal-a"],
      auditors: ["principal-b"],
      escalate_to: "commonplace-factory",
      outputs: ["chits"],
      environment_faced: []
    }
  end
end
