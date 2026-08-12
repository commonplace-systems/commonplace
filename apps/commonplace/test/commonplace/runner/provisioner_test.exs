defmodule Commonplace.Runner.ProvisionerTest do
  use ExUnit.Case, async: false

  alias Commonplace.Cell.Manifest
  alias Commonplace.Runner.{PodProfile, Provisioner}
  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.{DocBuilder, Schema}
  alias Commonplace.Workspace

  @cid String.duplicate("a", 64)

  setup do
    fixture_root =
      Path.join(System.tmp_dir!(), "cp_provisioner_#{System.unique_integer([:positive])}")

    source_repo = Path.join(fixture_root, "source")
    pods_root = Path.join(fixture_root, "pods")
    File.mkdir_p!(source_repo)
    File.mkdir_p!(pods_root)
    File.write!(Path.join(source_repo, "README.md"), "fixture checkout\n")

    git!(source_repo, ["init", "--quiet"])
    git!(source_repo, ["config", "user.email", "provisioner@example.invalid"])
    git!(source_repo, ["config", "user.name", "Provisioner Fixture"])
    git!(source_repo, ["add", "README.md"])
    git!(source_repo, ["commit", "--quiet", "-m", "fixture"])
    sha = git!(source_repo, ["rev-parse", "HEAD"])

    on_exit(fn -> File.rm_rf!(fixture_root) end)

    %{fixture_root: fixture_root, source_repo: source_repo, pods_root: pods_root, sha: sha}
  end

  test "birth provisions and verifies the pod-local world by effect", ctx do
    manifest = valid_manifest(%{root_entries: ["notes"]})

    assert {:ok, pod} =
             Provisioner.provision(manifest, profile(),
               pods_root: ctx.pods_root,
               repo: ctx.source_repo,
               sha: ctx.sha
             )

    assert pod.sha == ctx.sha
    assert pod.worker == :not_started
    refute Map.has_key?(pod, :pid)
    assert git!(pod.checkout_dir, ["rev-parse", "HEAD"]) == ctx.sha

    assert {:ok, declarations} = Provisioner.read_declarations(pod.data_dir)
    assert declarations.sync_scope == manifest.sync_scope
    assert declarations.sla == manifest.sla

    # The born world's posture must be durable on disk, not only asserted
    # in-process: an absent trust.json silently means permissive (CX-1ern).
    assert {:ok, trust_raw} = File.read(Path.join(pod.data_dir, "trust.json"))
    assert %{"accept_unsigned" => false} = Jason.decode!(trust_raw)

    with_store(pod.data_dir, fn store ->
      assert {:ok, :minimal} = Workspace.profile(pod.root_uuid, store)

      assert {:ok, %{case: :stored, manifest: %Manifest{id: "cell-provisioned"}}} =
               Manifest.read(pod.root_uuid, store)

      assert {:ok, root_doc} = DocBuilder.reconstruct_snapshot(store, pod.root_uuid)
      assert {:ok, %{name: "notes", type: :dir}} = Schema.get_entry(root_doc, "notes")
    end)
  end

  test "enforce-from-birth assertion refuses permissive and names the posture field" do
    permissive = %{
      accept_unsigned: true,
      local_write_gate: :enforce,
      local_read_gate: :enforce
    }

    assert {:error,
            {:invalid_manifest, "trust.accept_unsigned", "must be false at birth; got true"}} =
             Provisioner.assert_enforcing_posture(permissive)
  end

  test "enforce-from-birth assertion positive control accepts the enforcing posture" do
    enforcing = %{
      accept_unsigned: false,
      local_write_gate: :enforce,
      local_read_gate: :enforce
    }

    assert :ok = Provisioner.assert_enforcing_posture(enforcing)
  end

  test "sandbox spec constructs in all six standing masks and the profile shape", ctx do
    pod_home = Path.join(ctx.pods_root, "cell-provisioned")
    spec = Provisioner.sandbox_spec(profile(), pod_home)

    refute function_exported?(Provisioner, :sandbox_spec, 3),
           "callers must not have a constructor that accepts a mask list"

    assert spec.executable == "bwrap"
    assert spec.profile_sandbox == "beam-isolate"
    assert spec.workdir == Path.join(pod_home, "checkout")

    assert Enum.map(spec.masks, & &1.name) == [
             :node_signing_key,
             :secrets,
             :erlang_cookie,
             :ssh,
             :github_cli,
             :claude_channels
           ]

    for mask <- spec.masks do
      assert mask.operation in [:ro_bind_null, :tmpfs]
      assert mask.path in spec.argv
    end
  end

  test "absent sync scope refuses at birth with the field named", ctx do
    manifest = valid_manifest() |> Map.delete(:sync_scope)

    assert {:error, {:invalid_manifest, "sync_scope", "is required"}} =
             Provisioner.provision(manifest, profile(), provision_opts(ctx))
  end

  test "unknown workspace class refuses at birth with the field named", ctx do
    manifest = valid_manifest(%{workspace_class: "unknown"})

    assert {:error, {:invalid_manifest, "workspace_class", _reason}} =
             Provisioner.provision(manifest, profile(), provision_opts(ctx))
  end

  test "names-only hosting check refuses a missing service by field and service name", ctx do
    manifest =
      valid_manifest(%{
        environments: %{may_declare: true, requires_allowed: ["postgres", "redis"]}
      })

    assert {:error,
            {:invalid_manifest, "environments.requires_allowed",
             "service redis is not hosted by pod profile runner-local"}} =
             Provisioner.provision(manifest, profile(), provision_opts(ctx))
  end

  defp provision_opts(ctx) do
    [pods_root: ctx.pods_root, repo: ctx.source_repo, sha: ctx.sha]
  end

  defp valid_manifest(overrides \\ %{}) do
    Map.merge(
      %{
        id: "cell-provisioned",
        parent: "commonplace-factory",
        mission: "Exercise local pod provisioning",
        principal: "principal-a",
        workspace_class: "minimal",
        root_entries: [],
        authority: %{certs: [@cid], authors_code: false, scope_note: nil},
        sync_scope: %{
          rule: "git-tracked-set",
          excludes: [".beads"],
          binary_extensions: [".png"]
        },
        sla: %{tier: "durable", retention: "indefinite", note: "pod-local"},
        environments: %{may_declare: false, requires_allowed: ["postgres"]},
        stewards: ["principal-a"],
        auditors: ["principal-b"],
        escalate_to: "commonplace-factory",
        outputs: ["chits"],
        environment_faced: []
      },
      overrides
    )
  end

  defp profile do
    %PodProfile{
      id: "runner-local",
      harness: "commonplace-runner-v1",
      sandbox: "beam-isolate",
      services: %{"postgres" => "16.2"}
    }
  end

  defp with_store(data_dir, fun) do
    {:ok, store} = GenServer.start_link(CommitStore, data_dir: data_dir)

    try do
      fun.(store)
    after
      db = CommitStore.db_handle(store)
      GenServer.stop(store)
      CubDB.stop(db)
    end
  end

  defp git!(dir, args) do
    {output, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    String.trim(output)
  end
end
