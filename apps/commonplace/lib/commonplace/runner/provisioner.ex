defmodule Commonplace.Runner.Provisioner do
  @moduledoc """
  Provisions and verifies a local runner pod for CX-d59r.

  A pod lives below the caller's runner-owned `:pods_root`, in a directory
  named for the validated manifest id. It contains `checkout/`, a detached
  local clone at the requested SHA; `workspace/.commonplace/`, the pod-local
  store; and `home/`, the home directory represented in the sandbox spec.

  This module constructs a bwrap invocation as data. The standing credential
  and live-process channel masks are owned by `sandbox_spec/2`; callers cannot
  omit or replace them.

  Provision-time service matching is deliberately names-only:
  `environments.requires_allowed` must be a subset of the pod profile's
  service keys. Version matching remains instance-time work for a later round.

  The validated manifest is the ratified input; its provenance is the
  provisioning caller's responsibility. At birth, the runner mints the one
  authority cert named by `authors_code` against the pod-local store and writes
  the actual stored CID into the born manifest. Birth certs deliberately have
  no expiry in this round.

  Birth passes the pod-local store and trust posture explicitly. Provisioning
  therefore does not repoint node-global application configuration.
  """

  alias Commonplace.CertMint
  alias Commonplace.Cell.Manifest
  alias Commonplace.Crypto.NodeIdentity
  alias Commonplace.Runner.PodProfile
  alias Commonplace.Store.{Commit, CommitStoreClient}
  alias Commonplace.Store.Supervisor, as: StoreSupervisor
  alias Commonplace.Tree.{DocBuilder, Schema}
  alias Commonplace.Workspace
  alias Commonplace.Workspace.RootWritePolicy
  alias Yelixer.Encoding

  @declarations_file "runner-storage.json"
  @trust_file "trust.json"
  @environment_contract %{
    "COMMONPLACE_DATA_DIR" => :data_dir,
    "HOME" => :home_dir,
    "LANG" => {:literal, "C.UTF-8"},
    "LC_ALL" => {:literal, "C.UTF-8"},
    "PATH" => {:literal, "/usr/local/bin:/usr/bin:/bin"}
  }

  @type posture :: %{
          required(:accept_unsigned) => boolean(),
          required(:local_write_gate) => atom(),
          required(:local_read_gate) => atom()
        }

  @doc "Provision a fresh local pod and return only inert data about it."
  @spec provision(Manifest.t() | map(), PodProfile.t() | map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def provision(manifest, profile, opts) when is_list(opts) do
    with {:ok, manifest} <- validated_manifest(manifest),
         {:ok, profile} <- PodProfile.validate(profile),
         :ok <- safe_pod_id(manifest.id),
         :ok <- supported_sandbox(profile),
         :ok <- names_only_hosting_check(manifest, profile),
         {:ok, principal_pubkey} <- birth_authority_input(manifest, opts),
         {:ok, paths} <- provision_paths(manifest, opts) do
      build_pod(manifest, profile, paths, principal_pubkey)
    end
  end

  @doc "Return the environment-name set guaranteed by the pod contract."
  @spec environment_names() :: MapSet.t(String.t())
  def environment_names, do: @environment_contract |> Map.keys() |> MapSet.new()

  @doc """
  Construct the one safe bwrap specification for a pod.

  There is intentionally no masks argument. The credential floor is part of
  construction, not a convention a caller must remember.
  """
  @spec sandbox_spec(PodProfile.t(), Path.t()) :: map()
  def sandbox_spec(%PodProfile{} = profile, pod_home) when is_binary(pod_home) do
    checkout_dir = Path.join(pod_home, "checkout")
    data_dir = Path.join([pod_home, "workspace", ".commonplace"])
    home_dir = Path.join(pod_home, "home")
    uid = File.stat!("/proc/self").uid

    environment =
      environment_names()
      |> Map.new(fn name ->
        source = Map.get(@environment_contract, name)
        {name, environment_value(source, data_dir, home_dir)}
      end)

    masks = [
      %{
        name: :node_signing_key,
        operation: :ro_bind_null,
        path: Path.join(data_dir, "node_signing_key")
      },
      %{name: :secrets, operation: :tmpfs, path: Path.join(data_dir, "secrets")},
      %{
        name: :erlang_cookie,
        operation: :ro_bind_null,
        path: Path.join(home_dir, ".erlang.cookie")
      },
      %{name: :ssh, operation: :tmpfs, path: Path.join(home_dir, ".ssh")},
      %{name: :github_cli, operation: :tmpfs, path: Path.join(home_dir, ".config/gh")},
      %{name: :claude_channels, operation: :tmpfs, path: Path.join(home_dir, ".claude/channels")},
      %{name: :user_runtime_ipc, operation: :tmpfs, path: "/run/user/#{uid}"}
    ]

    argv =
      [
        "--die-with-parent",
        "--new-session",
        "--unshare-all",
        "--clearenv",
        "--ro-bind",
        "/",
        "/",
        "--dev",
        "/dev",
        "--proc",
        "/proc",
        # `/tmp` is emptied wholesale, and it must happen HERE -- before the pod's own
        # binds, which may live under `/tmp` and would otherwise be covered by it.
        #
        # This replaces per-socket masks for `/tmp/tmux-<uid>`, `/tmp/claude-chat` and
        # `/tmp/tsx-<uid>`. Those enumerated a parent they could mask outright, which
        # was wrong twice over:
        #
        #   FRAGILE     `--tmpfs <path>` needs its mount point to EXIST, and under
        #               `--ro-bind / /` bwrap cannot mkdir one. Those directories exist
        #               on a developer box only because a tmux or a chat socket happens
        #               to be running. On a machine without them the pod died with
        #               "bwrap: Can't mkdir /tmp/tmux-1001: Read-only file system" --
        #               i.e. the fence depended on ambient state nothing declared.
        #   INCOMPLETE  an enumeration hides only what someone remembered. Emptying the
        #               parent hides every present and future channel under it.
        "--tmpfs",
        "/tmp",
        "--bind",
        checkout_dir,
        checkout_dir,
        "--bind",
        data_dir,
        data_dir,
        "--bind",
        home_dir,
        home_dir
      ] ++
        Enum.flat_map(masks, &mask_argv/1) ++
        Enum.flat_map(environment, fn {name, value} -> ["--setenv", name, value] end) ++
        ["--chdir", checkout_dir]

    %{
      executable: "bwrap",
      argv: argv,
      binds: [
        %{source: checkout_dir, target: checkout_dir, mode: :read_write},
        %{source: data_dir, target: data_dir, mode: :read_write},
        %{source: home_dir, target: home_dir, mode: :read_write}
      ],
      masks: masks,
      environment: environment,
      profile_sandbox: profile.sandbox,
      workdir: checkout_dir
    }
  end

  defp environment_value(:data_dir, data_dir, _home_dir), do: data_dir
  defp environment_value(:home_dir, _data_dir, home_dir), do: home_dir
  defp environment_value({:literal, value}, _data_dir, _home_dir), do: value

  @doc "Assert the resolved posture required at the end of workspace birth."
  @spec assert_enforcing_posture(posture()) :: :ok | {:error, term()}
  def assert_enforcing_posture(posture) when is_map(posture) do
    with :ok <- posture_field(posture, :accept_unsigned, false, "trust.accept_unsigned"),
         :ok <- posture_field(posture, :local_write_gate, :enforce, "trust.local_write_gate"),
         :ok <- posture_field(posture, :local_read_gate, :enforce, "trust.local_read_gate") do
      :ok
    end
  end

  @doc "Read back the pod-local sync-scope and SLA storage declaration."
  @spec read_declarations(Path.t()) :: {:ok, map()} | {:error, term()}
  def read_declarations(data_dir) when is_binary(data_dir) do
    with {:ok, contents} <- File.read(Path.join(data_dir, @declarations_file)),
         {:ok, document} <- Jason.decode(contents),
         %{"sync_scope" => sync_scope, "sla" => sla} <- document do
      {:ok,
       %{
         sync_scope: %{
           rule: sync_scope["rule"],
           excludes: sync_scope["excludes"],
           binary_extensions: sync_scope["binary_extensions"]
         },
         sla: %{
           tier: sla["tier"],
           retention: sla["retention"],
           note: sla["note"]
         }
       }}
    else
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_runner_storage_declaration}
    end
  end

  defp build_pod(manifest, profile, paths, principal_pubkey) do
    case File.mkdir(paths.pod_home) do
      :ok ->
        result = do_build_pod(manifest, profile, paths, principal_pubkey)

        if match?({:error, _reason}, result) do
          File.rm_rf(paths.pod_home)
        end

        result

      {:error, :eexist} ->
        invalid("id", "pod home already exists for #{manifest.id}")

      {:error, reason} ->
        invalid("id", "pod home could not be created: #{inspect(reason)}")
    end
  end

  defp do_build_pod(manifest, profile, paths, principal_pubkey) do
    with :ok <- mkdir_p(paths.data_dir, "workspace"),
         :ok <- mkdir_p(paths.home_dir, "sandbox.home"),
         :ok <- checkout(paths.repo, paths.sha, paths.checkout_dir),
         :ok <- write_birth_declarations(paths.data_dir, manifest),
         {:ok, born} <- birth_workspace(paths, manifest, principal_pubkey),
         {:ok, declarations} <- read_declarations(paths.data_dir),
         :ok <- verify_declarations(declarations, manifest) do
      {:ok,
       %{
         pod_home: paths.pod_home,
         checkout_dir: paths.checkout_dir,
         data_dir: paths.data_dir,
         root_uuid: born.root_uuid,
         sha: paths.sha,
         sandbox_spec: sandbox_spec(profile, paths.pod_home),
         worker: :ready
       }}
    end
  end

  defp birth_workspace(paths, manifest, principal_pubkey) do
    names = store_names()

    with {:ok, supervisor} <-
           StoreSupervisor.start_link(
             data_dir: paths.data_dir,
             name: names.supervisor,
             commit_store_name: names.store,
             trust_side_store_name: names.trust_side_store,
             pending_imports_name: names.pending_imports,
             local_write_gate: :enforce
           ) do
      try do
        initialize_and_verify(names.store, paths, manifest, principal_pubkey)
      after
        Supervisor.stop(supervisor)
      end
    end
  end

  defp initialize_and_verify(store, paths, manifest, principal_pubkey) do
    profile = workspace_profile(manifest.workspace_class)

    with {:ok, signing_context} <- NodeIdentity.signing_context(paths.data_dir),
         {:ok, initialized} <-
           Workspace.initialize(paths.data_dir,
             store: store,
             checkout_dir: paths.checkout_dir,
             profile: profile,
             signing_context: signing_context
           ) do
      try do
        with :ok <- assert_enforcing_posture(resolved_posture(paths.data_dir)),
             :ok <-
               amend_root_entries(
                 initialized.root_uuid,
                 manifest,
                 store,
                 paths.data_dir,
                 signing_context
               ),
             {:ok, born_manifest} <-
               mint_birth_authority(
                 initialized.root_uuid,
                 manifest,
                 principal_pubkey,
                 store,
                 signing_context
               ),
             {:ok, _stored} <-
               Manifest.create(initialized.root_uuid, born_manifest, store,
                 signing_context: signing_context
               ),
             {:ok, %{case: :stored}} <- Manifest.read(initialized.root_uuid, store) do
          {:ok, %{root_uuid: initialized.root_uuid}}
        else
          {:error, {:invalid_manifest, _field, _reason}} = error -> error
          {:error, reason} -> invalid("manifest", "workspace birth failed: #{inspect(reason)}")
        end
      after
        GenServer.stop(initialized.checkout_registry)
      end
    else
      {:error, reason} ->
        invalid("workspace_class", "workspace initialization failed: #{inspect(reason)}")
    end
  end

  defp mint_birth_authority(root_uuid, manifest, principal_pubkey, store, signing_context) do
    verbs = birth_verbs(manifest)

    with {:ok, minted} <-
           CertMint.mint(":" <> root_uuid, verbs, manifest.principal, nil,
             issuer_context: signing_context,
             store: store,
             root_uuid: root_uuid,
             audience_resolver: fn audience_uuid ->
               if audience_uuid == manifest.principal,
                 do: {:ok, principal_pubkey},
                 else: {:error, :unexpected_birth_audience}
             end
           ),
         {:ok, stored} <- CommitStoreClient.get_capability(store, minted.id),
         :ok <-
           verify_birth_certificate(
             stored,
             manifest.principal,
             principal_pubkey,
             root_uuid,
             verbs
           ) do
      actual_cid = Base.encode16(stored.id, case: :lower)
      {:ok, put_in(manifest.authority.certs, [actual_cid])}
    else
      {:error, {:invalid_manifest, _field, _reason}} = error -> error
      {:error, reason} -> invalid("authority.certs", "birth mint failed: #{inspect(reason)}")
      :none -> invalid("authority.certs", "minted certificate was absent from the pod store")
    end
  end

  defp birth_verbs(%Manifest{authority: %{authors_code: true}}),
    do: [:write, :execute]

  defp birth_verbs(%Manifest{authority: %{authors_code: false}}), do: [:write]

  defp verify_birth_certificate(cert, principal, pubkey, root_uuid, verbs) do
    expected_verbs = Enum.sort(verbs)

    if cert.audience == {principal, pubkey} and cert.claim.verbs == expected_verbs and
         cert.claim.scope == {:subtree, root_uuid} and
         cert.claim.caveats == %{not_before: nil, not_after: nil} do
      :ok
    else
      invalid("authority.certs", "stored birth certificate does not bind the ratified authority")
    end
  end

  defp amend_root_entries(root_uuid, manifest, store, data_dir, signing_context) do
    Enum.reduce_while(manifest.root_entries, :ok, fn entry, :ok ->
      case add_root_entry(root_uuid, entry, store, data_dir, signing_context) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp add_root_entry(root_uuid, entry, store, data_dir, signing_context) do
    with :ok <- safe_root_entry(entry),
         :ok <- RootWritePolicy.check_new_entry(root_uuid, entry, store, data_dir),
         {:ok, root_doc} <- DocBuilder.reconstruct_snapshot(store, root_uuid) do
      case Schema.get_entry(root_doc, entry) do
        {:ok, _existing} ->
          :ok

        :error ->
          child_uuid = UUID.uuid4()
          child_update = Schema.new_schema() |> Encoding.encode_update()

          with %Commit{} <-
                 CommitStoreClient.create_commit(
                   store,
                   child_uuid,
                   child_update,
                   nil,
                   %{},
                   signing_context: signing_context
                 ),
               updated = Schema.add_directory(root_doc, entry, child_uuid),
               %Commit{} <-
                 CommitStoreClient.create_chained_commit(
                   store,
                   root_uuid,
                   Encoding.encode_update(updated),
                   %{},
                   signing_context: signing_context
                 ) do
            :ok
          else
            {:error, reason} ->
              invalid("root_entries", "could not add #{entry}: #{inspect(reason)}")
          end
      end
    else
      {:error, {:invalid_manifest, _field, _reason}} = error -> error
      {:error, reason} -> invalid("root_entries", "could not add #{entry}: #{inspect(reason)}")
      :none -> invalid("root_entries", "root schema is absent while adding #{entry}")
    end
  end

  defp write_birth_declarations(data_dir, manifest) do
    storage = %{
      "version" => 1,
      "sync_scope" => manifest.sync_scope,
      "sla" => manifest.sla
    }

    trust = %{"accept_unsigned" => false, "trusted_identities" => %{}}

    with :ok <- write_json(Path.join(data_dir, @declarations_file), storage, "sync_scope"),
         :ok <- write_json(Path.join(data_dir, @trust_file), trust, "trust.accept_unsigned") do
      :ok
    end
  end

  defp write_json(path, document, field) do
    case File.write(path, Jason.encode!(document)) do
      :ok -> :ok
      {:error, reason} -> invalid(field, "could not write declaration: #{inspect(reason)}")
    end
  end

  defp verify_declarations(declarations, manifest) do
    cond do
      declarations.sync_scope != manifest.sync_scope ->
        invalid("sync_scope", "born workspace declaration does not match manifest")

      declarations.sla != manifest.sla ->
        invalid("sla.tier", "born workspace storage declaration does not match manifest")

      true ->
        :ok
    end
  end

  defp checkout(repo, sha, checkout_dir) do
    with {_, 0} <-
           System.cmd("git", ["clone", "--quiet", "--local", "--no-checkout", repo, checkout_dir],
             stderr_to_stdout: true
           ),
         {_, 0} <-
           System.cmd("git", ["checkout", "--quiet", "--detach", sha],
             cd: checkout_dir,
             stderr_to_stdout: true
           ),
         {actual, 0} <-
           System.cmd("git", ["rev-parse", "HEAD"], cd: checkout_dir, stderr_to_stdout: true),
         true <- String.trim(actual) == sha do
      :ok
    else
      false ->
        invalid("checkout.sha", "checkout did not resolve to requested SHA #{sha}")

      {output, _status} ->
        invalid("checkout.sha", "local checkout failed: #{String.trim(output)}")
    end
  end

  defp validated_manifest(manifest) do
    with :ok <- Manifest.validate(manifest),
         {:ok, encoded} <- Manifest.encode(manifest),
         {:ok, decoded} <- Manifest.decode(encoded) do
      {:ok, decoded}
    end
  end

  defp names_only_hosting_check(manifest, profile) do
    hosted = Map.keys(profile.services) |> MapSet.new()

    missing =
      manifest.environments.requires_allowed
      |> Enum.sort()
      |> Enum.find(&(not MapSet.member?(hosted, &1)))

    if missing do
      invalid(
        "environments.requires_allowed",
        "service #{missing} is not hosted by pod profile #{profile.id}"
      )
    else
      :ok
    end
  end

  defp birth_authority_input(manifest, opts) do
    with :ok <- empty_birth_certs(manifest.authority.certs),
         :ok <- uuid_principal(manifest.principal),
         {:ok, pubkey} <- principal_pubkey(opts) do
      {:ok, pubkey}
    end
  end

  defp empty_birth_certs([]), do: :ok

  defp empty_birth_certs(_certs) do
    invalid("authority.certs", "must be empty for a fresh world")
  end

  defp uuid_principal(principal) do
    if is_binary(principal) and
         Regex.match?(
           ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i,
           principal
         ) do
      :ok
    else
      invalid("principal", "must be a UUID for birth authority")
    end
  end

  defp principal_pubkey(opts) do
    case Keyword.fetch(opts, :principal_pubkey) do
      {:ok, pubkey} when is_binary(pubkey) -> {:ok, pubkey}
      {:ok, _invalid} -> invalid("principal", "public key provided to provisioning is invalid")
      :error -> invalid("principal", "public key not provided to provisioning")
    end
  end

  defp provision_paths(manifest, opts) do
    with {:ok, pods_root} <- required_path(opts, :pods_root),
         {:ok, repo} <- required_path(opts, :repo),
         {:ok, sha} <- required_path(opts, :sha),
         :ok <- mkdir_p(pods_root, "pods_root") do
      pod_home = Path.join(pods_root, manifest.id)

      {:ok,
       %{
         pod_home: pod_home,
         checkout_dir: Path.join(pod_home, "checkout"),
         data_dir: Path.join([pod_home, "workspace", ".commonplace"]),
         home_dir: Path.join(pod_home, "home"),
         repo: repo,
         sha: sha
       }}
    end
  end

  defp required_path(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _ -> invalid("provision.#{key}", "is required")
    end
  end

  defp safe_pod_id(id) do
    if id not in [".", ".."] and Path.basename(id) == id do
      :ok
    else
      invalid("id", "must be a single path-safe pod name")
    end
  end

  defp safe_root_entry(entry) do
    cond do
      entry in ["", ".", ".."] or Path.basename(entry) != entry ->
        invalid("root_entries", "entry #{inspect(entry)} must be one path-safe name")

      Path.extname(entry) != "" ->
        invalid(
          "root_entries",
          "entry #{entry} needs content-document machinery not present at birth"
        )

      true ->
        :ok
    end
  end

  defp supported_sandbox(%PodProfile{sandbox: "beam-isolate"}), do: :ok

  defp supported_sandbox(%PodProfile{sandbox: sandbox}) do
    {:error, {:invalid_profile, "sandbox", "unsupported local sandbox #{inspect(sandbox)}"}}
  end

  defp workspace_profile("default"), do: :default
  defp workspace_profile("minimal"), do: :minimal

  defp resolved_posture(data_dir) do
    %{
      accept_unsigned: Commonplace.Trust.config(data_dir).accept_unsigned,
      local_write_gate: :enforce,
      local_read_gate: :enforce
    }
  end

  defp posture_field(posture, key, expected, field) do
    actual = Map.get(posture, key)

    if actual == expected,
      do: :ok,
      else: invalid(field, "must be #{inspect(expected)} at birth; got #{inspect(actual)}")
  end

  @doc false
  # Test-only accessor: mask_argv/1 is private and the operation set is the
  # security-relevant surface, so it is exercised directly rather than inferred
  # from a full spec.
  def mask_argv_for_test(mask), do: mask_argv(mask)

  defp mask_argv(%{operation: :ro_bind_null, path: path}),
    do: ["--ro-bind", "/dev/null", path]

  defp mask_argv(%{operation: :tmpfs, path: path}), do: ["--tmpfs", path]

  # `:ro_bind_source` — bind SOURCE read-only over PATH.
  #
  # WHY THIS IS NOT A CAPABILITY INCREASE, AND WHAT THAT DEPENDS ON.
  #
  # The other two operations can only ever REMOVE access: `:ro_bind_null` binds
  # /dev/null over a path, `:tmpfs` blanks a directory. This one REDIRECTS A
  # NAME, which sounds like it can grant. Under this sandbox it cannot, for one
  # reason and one reason only:
  #
  #   THE BASE IS `--ro-bind / /` — EVERY HOST PATH IS ALREADY READABLE INSIDE.
  #
  # So binding X over Y exposes nothing that was not already exposed, and
  # `--ro-bind` forces read-only so it cannot grant a write either. It changes
  # what a NAME RESOLVES TO, nothing more.
  #
  # ⛔ THAT ARGUMENT IS LOAD-BEARING AND IT IS ABOUT THE BASE, NOT ABOUT THIS
  # CLAUSE. If `sandbox_spec/2` ever stops binding all of `/` read-only — moving
  # to a selective allowlist, say — THIS OPERATION BECOMES A GRANT and must be
  # re-reviewed. `sandbox_spec_ro_root_test` fails on purpose if that happens.
  #
  # It exists because the Sol wrapper's eleventh mask entry is a SUBSTITUTION
  # (a guard script bound over a binary) and this spec could not express it, so
  # the two mask lists could not converge. They are the same list maintained
  # twice and had already diverged by exactly that one item.
  defp mask_argv(%{operation: :ro_bind_source, source: source, path: path})
       when is_binary(source) and is_binary(path),
       do: ["--ro-bind", source, path]

  defp mkdir_p(path, field) do
    case File.mkdir_p(path) do
      :ok -> :ok
      {:error, reason} -> invalid(field, "could not create directory: #{inspect(reason)}")
    end
  end

  defp store_names do
    nonce = make_ref()

    %{
      supervisor: {:global, {__MODULE__, :supervisor, nonce}},
      store: {:global, {__MODULE__, :commit_store, nonce}},
      trust_side_store: {:global, {__MODULE__, :trust_side_store, nonce}},
      pending_imports: {:global, {__MODULE__, :pending_imports, nonce}}
    }
  end

  defp invalid(field, reason), do: {:error, {:invalid_manifest, field, reason}}
end
