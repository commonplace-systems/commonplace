defmodule Commonplace.Runner.ProvisionerTest do
  use ExUnit.Case, async: false

  alias Commonplace.Cell.Manifest
  alias Commonplace.Crypto.Signing
  alias Commonplace.Runner.{PodProfile, Provisioner}
  alias Commonplace.Store.{CommitStoreClient, Supervisor}
  alias Commonplace.Tree.{DocBuilder, Schema}
  alias Commonplace.Trust.Capability
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
    principal_uuid = UUID.uuid4()
    {principal_pubkey, principal_private_key} = Signing.generate_keypair()

    on_exit(fn -> File.rm_rf!(fixture_root) end)

    %{
      fixture_root: fixture_root,
      source_repo: source_repo,
      pods_root: pods_root,
      sha: sha,
      principal_uuid: principal_uuid,
      principal_pubkey: principal_pubkey,
      principal_private_key: principal_private_key
    }
  end

  test "birth provisions and verifies the pod-local world by effect", ctx do
    manifest = valid_manifest(ctx, %{root_entries: ["notes"]})

    assert {:ok, pod} =
             Provisioner.provision(manifest, profile(),
               pods_root: ctx.pods_root,
               repo: ctx.source_repo,
               sha: ctx.sha,
               principal_pubkey: ctx.principal_pubkey
             )

    assert pod.sha == ctx.sha
    assert pod.worker == :ready
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

      assert {:ok,
              %{
                case: :stored,
                manifest: %Manifest{
                  id: "cell-provisioned",
                  authority: %{certs: [cert_cid], authors_code: false}
                }
              }} =
               Manifest.read(pod.root_uuid, store)

      assert {:ok, cid} = Base.decode16(cert_cid, case: :lower)
      assert {:ok, cert} = CommitStoreClient.get_capability(store, cid)
      assert cert.id == cid
      assert cert.audience == {ctx.principal_uuid, ctx.principal_pubkey}
      assert cert.claim.verbs == [:write]
      assert cert.claim.scope == {:subtree, pod.root_uuid}
      assert cert.claim.caveats == %{not_before: nil, not_after: nil}

      # Shape alone cannot prove the cert BINDS: the id must match the bytes
      # and the signature must verify against the issuer key. The S4 pins
      # supply the other half — any valid cert of this shape authorizes per
      # the pinned policy.
      assert :ok = Capability.verify_id(cert)
      assert :ok = Capability.verify_sig(cert)

      assert {:ok, root_doc} = DocBuilder.reconstruct_snapshot(store, pod.root_uuid)
      assert {:ok, %{name: "notes", type: :dir}} = Schema.get_entry(root_doc, "notes")
    end)
  end

  test "authors_code birth stores the actual w+x certificate CID", ctx do
    manifest = valid_manifest(ctx, %{authority: authority(true)})

    assert {:ok, pod} =
             Provisioner.provision(manifest, profile(), provision_opts(ctx))

    with_store(pod.data_dir, fn store ->
      assert {:ok, %{case: :stored, manifest: %Manifest{authority: %{certs: [cert_cid]}}}} =
               Manifest.read(pod.root_uuid, store)

      assert {:ok, cid} = Base.decode16(cert_cid, case: :lower)
      assert {:ok, cert} = CommitStoreClient.get_capability(store, cid)
      assert cert.id == cid
      assert cert.audience == {ctx.principal_uuid, ctx.principal_pubkey}
      assert cert.claim.verbs == [:execute, :write]
      assert cert.claim.scope == {:subtree, pod.root_uuid}
      assert cert.claim.caveats == %{not_before: nil, not_after: nil}
      assert :ok = Capability.verify_id(cert)
      assert :ok = Capability.verify_sig(cert)
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

  test "sandbox spec constructs in the standing masks and the profile shape", ctx do
    pod_home = Path.join(ctx.pods_root, "cell-provisioned")
    spec = Provisioner.sandbox_spec(profile(), pod_home)

    refute function_exported?(Provisioner, :sandbox_spec, 3),
           "callers must not have a constructor that accepts a mask list"

    assert spec.executable == "bwrap"
    assert spec.profile_sandbox == "beam-isolate"
    assert spec.workdir == Path.join(pod_home, "checkout")
    assert "--unshare-all" in spec.argv
    assert "--clearenv" in spec.argv
    assert ["--proc", "/proc"] in Enum.chunk_every(spec.argv, 2, 1, :discard)
    assert map_size(spec.environment) == 5

    assert Enum.map(spec.masks, & &1.name) == [
             :node_signing_key,
             :secrets,
             :erlang_cookie,
             :ssh,
             :github_cli,
             :claude_channels,
             :user_runtime_ipc
           ]

    # The three /tmp socket masks are gone because `--tmpfs /tmp` in the base subsumes
    # them. Assert the ORDER, not just the presence: the pod's own binds may live under
    # /tmp, so a tmpfs applied after them would cover the pod's data directory instead
    # of the host's channels.
    tmp_at =
      Enum.find_index(Enum.chunk_every(spec.argv, 2, 1, :discard), &(&1 == ["--tmpfs", "/tmp"]))

    first_bind = Enum.find_index(spec.argv, &(&1 == "--bind"))
    assert tmp_at, "the base must empty /tmp wholesale"
    assert tmp_at < first_bind, "/tmp must be emptied BEFORE the pod's binds land under it"

    for mask <- spec.masks do
      assert mask.operation in [:ro_bind_null, :tmpfs]
      assert mask.path in spec.argv
    end
  end

  test "a real provisioned pod has exactly the pod-contract environment names", ctx do
    assert {:ok, pod} =
             Provisioner.provision(valid_manifest(ctx), profile(), provision_opts(ctx))

    assert pod.sandbox_spec.environment |> Map.keys() |> MapSet.new() ==
             Provisioner.environment_names()
  end

  test "birth has no node-global application-env mutation seam" do
    source_path = Path.expand("../../../lib/commonplace/runner/provisioner.ex", __DIR__)
    source = File.read!(source_path)

    assert String.length(source) > 0, "the scanned provisioner corpus must be non-empty"
    refute source =~ "with_workspace_env"
    refute Regex.match?(~r/Application\.(?:put_env|delete_env)/, source)

    positive_control = "Application.put_env(:commonplace, :data_dir, pod_data_dir)"
    assert Regex.match?(~r/Application\.(?:put_env|delete_env)/, positive_control)
  end

  test "absent sync scope refuses at birth with the field named", ctx do
    manifest = valid_manifest(ctx) |> Map.delete(:sync_scope)

    assert {:error, {:invalid_manifest, "sync_scope", "is required"}} =
             Provisioner.provision(manifest, profile(), provision_opts(ctx))
  end

  test "unknown workspace class refuses at birth with the field named", ctx do
    manifest = valid_manifest(ctx, %{workspace_class: "unknown"})

    assert {:error, {:invalid_manifest, "workspace_class", _reason}} =
             Provisioner.provision(manifest, profile(), provision_opts(ctx))
  end

  test "names-only hosting check refuses a missing service by field and service name", ctx do
    manifest =
      valid_manifest(ctx, %{
        environments: %{may_declare: true, requires_allowed: ["postgres", "redis"]}
      })

    assert {:error,
            {:invalid_manifest, "environments.requires_allowed",
             "service redis is not hosted by pod profile runner-local"}} =
             Provisioner.provision(manifest, profile(), provision_opts(ctx))
  end

  test "fresh birth refuses pre-listed authority certs by field name", ctx do
    manifest = valid_manifest(ctx, %{authority: %{authority(false) | certs: [@cid]}})

    assert {:error, {:invalid_manifest, "authority.certs", _reason}} =
             Provisioner.provision(manifest, profile(), provision_opts(ctx))
  end

  test "fresh birth refuses a missing principal public key by field name", ctx do
    manifest = valid_manifest(ctx)
    opts = Keyword.delete(provision_opts(ctx), :principal_pubkey)

    assert {:error, {:invalid_manifest, "principal", "public key not provided to provisioning"}} =
             Provisioner.provision(manifest, profile(), opts)
  end

  test "fresh birth refuses a non-UUID principal by field name", ctx do
    manifest =
      valid_manifest(ctx, %{
        principal: "principal-a",
        stewards: ["principal-a"]
      })

    assert {:error, {:invalid_manifest, "principal", _reason}} =
             Provisioner.provision(manifest, profile(), provision_opts(ctx))
  end

  defp provision_opts(ctx) do
    [
      pods_root: ctx.pods_root,
      repo: ctx.source_repo,
      sha: ctx.sha,
      principal_pubkey: ctx.principal_pubkey
    ]
  end

  defp valid_manifest(ctx, overrides \\ %{}) do
    Map.merge(
      %{
        id: "cell-provisioned",
        parent: "commonplace-factory",
        mission: "Exercise local pod provisioning",
        principal: ctx.principal_uuid,
        workspace_class: "minimal",
        root_entries: [],
        authority: authority(false),
        sync_scope: %{
          rule: "git-tracked-set",
          excludes: [".beads"],
          binary_extensions: [".png"]
        },
        sla: %{tier: "durable", retention: "indefinite", note: "pod-local"},
        environments: %{may_declare: false, requires_allowed: ["postgres"]},
        stewards: [ctx.principal_uuid],
        auditors: [UUID.uuid4()],
        escalate_to: "commonplace-factory",
        outputs: ["chits"],
        environment_faced: []
      },
      overrides
    )
  end

  defp authority(authors_code) do
    %{certs: [], authors_code: authors_code, scope_note: nil}
  end

  # The spec carries the profile's declared posture, and "none" means the argv
  # NEVER re-shares the network: --unshare-all present, --share-net absent. The
  # absence assertion is the enforcement -- it is what a future posture must
  # deliberately break when it arrives with its mechanism.
  test "network posture none: spec carries it and the argv re-shares nothing", ctx do
    pod_home = Path.join(ctx.pods_root, "cell-network-none")
    spec = Provisioner.sandbox_spec(profile(), pod_home)

    assert spec.network == "none"
    assert "--unshare-all" in spec.argv
    refute "--share-net" in spec.argv
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
    nonce = make_ref()
    supervisor = {:global, {__MODULE__, :supervisor, nonce}}
    store = {:global, {__MODULE__, :commit_store, nonce}}

    {:ok, supervisor_pid} =
      Supervisor.start_link(
        data_dir: data_dir,
        name: supervisor,
        commit_store_name: store,
        trust_side_store_name: {:global, {__MODULE__, :trust_side_store, nonce}},
        pending_imports_name: {:global, {__MODULE__, :pending_imports, nonce}}
      )

    try do
      fun.(store)
    after
      Elixir.Supervisor.stop(supervisor_pid)
    end
  end

  defp git!(dir, args) do
    {output, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    String.trim(output)
  end

  test "ro_bind_source binds a source read-only over a path" do
    argv =
      Provisioner.mask_argv_for_test(%{
        operation: :ro_bind_source,
        source: "/opt/guard/bd-guard.sh",
        path: "/usr/local/bin/bd"
      })

    assert argv == ["--ro-bind", "/opt/guard/bd-guard.sh", "/usr/local/bin/bd"]
  end

  test "sandbox_spec_ro_root: the base binds ALL of / read-only" do
    # ⛔ THIS TEST GUARDS AN ARGUMENT, NOT A BEHAVIOUR.
    #
    # `:ro_bind_source` is safe ONLY because every host path is already readable
    # inside the sandbox, so redirecting a name exposes nothing new. That premise
    # is `--ro-bind / /` in the base argv. If the base ever becomes selective,
    # the premise dies and `:ro_bind_source` silently becomes a GRANT.
    #
    # So this fails on purpose at the moment the argument stops holding, rather
    # than leaving the reasoning in a comment nobody re-derives.
    spec = Provisioner.sandbox_spec(profile(), "/tmp/pod-ro-root-premise")

    assert ["--ro-bind", "/", "/"] in Enum.chunk_every(spec.argv, 3, 1, :discard),
           "the base no longer binds all of / read-only — :ro_bind_source is now a GRANT " <>
             "and must be re-reviewed before this test is changed"
  end
end
