defmodule Commonplace.Runner.Provisioner do
  @moduledoc """
  Provisions and verifies a local runner pod for CX-gkxa.

  A pod lives below the caller's runner-owned `:pods_root`, in a directory
  named for the validated manifest id. It contains `checkout/`, a detached
  local clone at the requested SHA; `workspace/.commonplace/`, the pod-local
  store; and `home/`, the home directory represented in the sandbox spec.

  This round constructs a bwrap invocation as data. It does not execute that
  invocation or launch a worker. The six standing credential masks are owned
  by `sandbox_spec/2`; callers cannot omit or replace them.

  Provision-time service matching is deliberately names-only:
  `environments.requires_allowed` must be a subset of the pod profile's
  service keys. Version matching remains instance-time work for a later round.

  Birth runs inside a node-global scope: `provision/3` temporarily repoints
  `:commonplace` application env (`:data_dir`, `:trust`, both gates) at the
  pod-local store, because trust resolution and the root-write policy read
  config rather than taking a store argument. On a node serving a live
  workspace, concurrent operations during that window would read the pod's
  store. Do NOT call this on such a node; S33 replaces this seam before a
  runner process hosts births.
  """

  alias Commonplace.Cell.Manifest
  alias Commonplace.Crypto.NodeIdentity
  alias Commonplace.Runner.PodProfile
  alias Commonplace.Store.{Commit, CommitStore, CommitStoreClient}
  alias Commonplace.Tree.{DocBuilder, Schema}
  alias Commonplace.Workspace
  alias Commonplace.Workspace.RootWritePolicy
  alias Yelixer.Encoding

  @declarations_file "runner-storage.json"
  @trust_file "trust.json"

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
         {:ok, paths} <- provision_paths(manifest, opts) do
      build_pod(manifest, profile, paths)
    end
  end

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
      %{name: :claude_channels, operation: :tmpfs, path: Path.join(home_dir, ".claude/channels")}
    ]

    argv =
      [
        "--die-with-parent",
        "--new-session",
        "--unshare-all",
        "--ro-bind",
        checkout_dir,
        checkout_dir,
        "--bind",
        data_dir,
        data_dir,
        "--bind",
        home_dir,
        home_dir
      ] ++ Enum.flat_map(masks, &mask_argv/1) ++ ["--chdir", checkout_dir]

    %{
      executable: "bwrap",
      argv: argv,
      binds: [
        %{source: checkout_dir, target: checkout_dir, mode: :read_only},
        %{source: data_dir, target: data_dir, mode: :read_write},
        %{source: home_dir, target: home_dir, mode: :read_write}
      ],
      masks: masks,
      profile_sandbox: profile.sandbox,
      workdir: checkout_dir
    }
  end

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

  defp build_pod(manifest, profile, paths) do
    case File.mkdir(paths.pod_home) do
      :ok ->
        result = do_build_pod(manifest, profile, paths)

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

  defp do_build_pod(manifest, profile, paths) do
    with :ok <- mkdir_p(paths.data_dir, "workspace"),
         :ok <- mkdir_p(paths.home_dir, "sandbox.home"),
         :ok <- checkout(paths.repo, paths.sha, paths.checkout_dir),
         :ok <- write_birth_declarations(paths.data_dir, manifest),
         {:ok, born} <- birth_workspace(paths, manifest),
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
         worker: :not_started
       }}
    end
  end

  defp birth_workspace(paths, manifest) do
    with_workspace_env(paths.data_dir, fn ->
      with {:ok, store} <- GenServer.start_link(CommitStore, data_dir: paths.data_dir) do
        try do
          initialize_and_verify(store, paths, manifest)
        after
          stop_store(store)
        end
      end
    end)
  end

  defp initialize_and_verify(store, paths, manifest) do
    profile = workspace_profile(manifest.workspace_class)

    case Workspace.initialize(paths.data_dir,
           store: store,
           checkout_dir: paths.checkout_dir,
           profile: profile
         ) do
      {:ok, initialized} ->
        try do
          with :ok <- assert_enforcing_posture(resolved_posture()),
               {:ok, signing_context} <- NodeIdentity.signing_context(),
               :ok <-
                 amend_root_entries(
                   initialized.root_uuid,
                   manifest,
                   store,
                   paths.data_dir,
                   signing_context
                 ),
               # CX-gkxa intentionally does not mint authority certs. S33 inserts
               # manifest schema section 4 step 2 at this marked point.
               {:ok, _stored} <-
                 Manifest.create(initialized.root_uuid, manifest, store,
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

      {:error, reason} ->
        invalid("workspace_class", "workspace initialization failed: #{inspect(reason)}")
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
          "entry #{entry} needs content-document machinery not present in CX-gkxa"
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

  defp resolved_posture do
    Commonplace.Trust.posture()
    |> Map.take([:accept_unsigned, :local_write_gate, :local_read_gate])
  end

  defp posture_field(posture, key, expected, field) do
    actual = Map.get(posture, key)

    if actual == expected,
      do: :ok,
      else: invalid(field, "must be #{inspect(expected)} at birth; got #{inspect(actual)}")
  end

  defp mask_argv(%{operation: :ro_bind_null, path: path}),
    do: ["--ro-bind", "/dev/null", path]

  defp mask_argv(%{operation: :tmpfs, path: path}), do: ["--tmpfs", path]

  defp mkdir_p(path, field) do
    case File.mkdir_p(path) do
      :ok -> :ok
      {:error, reason} -> invalid(field, "could not create directory: #{inspect(reason)}")
    end
  end

  defp stop_store(store) do
    db = CommitStore.db_handle(store)
    GenServer.stop(store)
    CubDB.stop(db)
  end

  defp with_workspace_env(data_dir, fun) do
    keys = [:data_dir, :trust, :local_write_gate, :local_read_gate]
    prior = Map.new(keys, &{&1, Application.fetch_env(:commonplace, &1)})

    Application.put_env(:commonplace, :data_dir, data_dir)
    Application.delete_env(:commonplace, :trust)
    Application.put_env(:commonplace, :local_write_gate, :enforce)
    Application.put_env(:commonplace, :local_read_gate, :enforce)

    try do
      fun.()
    after
      Enum.each(prior, fn
        {key, {:ok, value}} -> Application.put_env(:commonplace, key, value)
        {key, :error} -> Application.delete_env(:commonplace, key)
      end)
    end
  end

  defp invalid(field, reason), do: {:error, {:invalid_manifest, field, reason}}
end
