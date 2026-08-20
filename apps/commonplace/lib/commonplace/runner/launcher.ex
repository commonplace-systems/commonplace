defmodule Commonplace.Runner.Launcher do
  @moduledoc """
  Owns runner pod birth, execution, and reaping for CX-n6zc.

  This process is the first production caller of `Runner.Provisioner`. It must
  be started in a dedicated runner service whose systemd scope contains no
  live workspace serve, shell, or trading process. A worker inherits that
  runner-service scope; with `OOMPolicy=stop`, memory pressure can therefore
  stop the pod fleet and its launcher, but cannot stop an unrelated tmux or
  service scope. The launcher is deliberately not installed in
  `Commonplace.Application`, because that is the live-workspace serve.

  Startup requires the positive configuration declaration
  `dedicated_runner_service: true`. A launcher refuses at birth when that field
  is absent or has any other value.

  `pods_root` is exclusive to one launcher. An advisory lock enforces that
  ownership. On launcher startup, directories left by a prior runner process
  are stale: bubblewrap's `--die-with-parent` has already killed those PID
  namespaces, so startup removes the directories before accepting launches.
  Normal worker exit and explicit `reap/1` both remove the entire pod home,
  including its clone and `_build`.

  A live pod is addressed only through its captured `%PodHandle{}`. Reaping
  signals the captured outer bubblewrap PID and waits for its captured port.
  Bubblewrap then tears down the pod PID namespace, which makes the kernel
  terminate every process in that namespace as one unit. No process or argv
  pattern participates in the kill.
  """

  use GenServer

  require Logger

  alias Commonplace.Runner.{PodHandle, PodProfile, ProtoChitHarvest, Provisioner, RunRecipe}
  alias Commonplace.Store.CommitStoreClient

  @lock_file ".runner.lock"
  @output_tail_bytes 4096
  @quarantine_dir ".proto-chit-quarantine"

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts),
    do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  @spec launch(GenServer.server(), map(), map(), keyword()) ::
          {:ok, PodHandle.t()} | {:error, term()}
  def launch(server, manifest, profile, opts) when is_list(opts),
    do: GenServer.call(server, {:launch, manifest, profile, opts}, :infinity)

  @doc "Launch a pod whose invocation, environment, and placement come from a run recipe."
  @spec launch_recipe(GenServer.server(), map(), map(), RunRecipe.t() | map(), keyword()) ::
          {:ok, PodHandle.t()} | {:error, term()} | PodProfile.match_result()
  def launch_recipe(server, manifest, profile, recipe, opts) when is_list(opts),
    do: GenServer.call(server, {:launch_recipe, manifest, profile, recipe, opts}, :infinity)

  @spec reap(PodHandle.t()) :: :ok | {:error, :unknown_pod_handle}
  def reap(%PodHandle{launcher: launcher} = handle),
    do: GenServer.call(launcher, {:reap, handle}, :infinity)

  @spec alive?(PodHandle.t()) :: boolean()
  def alive?(%PodHandle{launcher: launcher} = handle),
    do: GenServer.call(launcher, {:alive?, handle})

  @impl true
  def init(opts) do
    with :ok <- require_dedicated_runner_service(opts),
         {:ok, pods_root} <- required_path(opts, :pods_root),
         :ok <- File.mkdir_p(pods_root),
         {:ok, lock} <- lock_root(pods_root),
         harvest = harvest_options(pods_root, opts),
         :ok <- reap_stale_homes(pods_root, harvest) do
      {:ok, %{pods_root: pods_root, lock: lock, pods: %{}, harvest: harvest}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:launch, manifest, profile, opts}, _from, state) do
    with {:ok, invocation} <- invocation(opts),
         provision_opts = Keyword.merge(opts, pods_root: state.pods_root),
         {:ok, pod} <- Provisioner.provision(manifest, profile, provision_opts),
         {:ok, port, os_pid} <- open_pod(pod.sandbox_spec, invocation) do
      ref = make_ref()

      handle = %PodHandle{
        launcher: self(),
        ref: ref,
        scope_pid: os_pid,
        pod_home: pod.pod_home
      }

      running = %{port: port, os_pid: os_pid, pod_home: pod.pod_home, output: ""}
      {:reply, {:ok, handle}, put_in(state.pods[ref], running)}
    else
      {:error, {:launch_failed, pod_home, reason}} ->
        _ = File.rm_rf(pod_home)
        {:reply, {:error, reason}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:launch_recipe, manifest, profile, recipe, opts}, _from, state) do
    with :ok <- RunRecipe.validate(recipe),
         {:ok, profile} <- PodProfile.validate(profile),
         :ok <- PodProfile.match_requires(recipe_value(recipe, :requires), profile),
         :ok <-
           environment_available?(
             recipe_value(recipe, :env),
             Provisioner.environment_names()
           ),
         provision_opts = Keyword.merge(opts, pods_root: state.pods_root),
         {:ok, pod} <- Provisioner.provision(manifest, profile, provision_opts),
         environment =
           resolve_environment(recipe_value(recipe, :env), pod.sandbox_spec.environment),
         invocation = recipe_invocation(recipe, environment),
         {:ok, port, os_pid} <- open_pod(pod.sandbox_spec, invocation) do
      ref = make_ref()

      handle = %PodHandle{
        launcher: self(),
        ref: ref,
        scope_pid: os_pid,
        pod_home: pod.pod_home
      }

      running = %{port: port, os_pid: os_pid, pod_home: pod.pod_home, output: ""}
      {:reply, {:ok, handle}, put_in(state.pods[ref], running)}
    else
      {:error, {:launch_failed, pod_home, reason}} ->
        _ = File.rm_rf(pod_home)
        {:reply, {:error, reason}, state}

      refusal_or_error ->
        {:reply, refusal_or_error, state}
    end
  end

  def handle_call({:reap, %PodHandle{ref: ref}}, _from, state) do
    case Map.pop(state.pods, ref) do
      {nil, _pods} ->
        {:reply, {:error, :unknown_pod_handle}, state}

      {%{port: port, os_pid: os_pid, pod_home: pod_home} = running, pods} ->
        case stop_namespace(port, os_pid) do
          :ok ->
            case harvest_and_remove(pod_home, state.harvest) do
              :ok -> {:reply, :ok, %{state | pods: pods}}
              {:error, _reason} = error -> {:reply, error, state}
            end

          {:error, _reason} = error ->
            {:stop, error, error, put_in(state.pods[ref], running)}
        end
    end
  end

  def handle_call({:alive?, %PodHandle{ref: ref}}, _from, state) do
    alive =
      case Map.get(state.pods, ref) do
        %{port: port} -> Port.info(port) != nil
        nil -> false
      end

    {:reply, alive, state}
  end

  @impl true
  def handle_info({port, {:data, output}}, state) do
    case find_ref(state.pods, port) do
      nil ->
        {:noreply, state}

      ref ->
        {:noreply, update_in(state.pods[ref].output, &append_tail(&1, output))}
    end
  end

  def handle_info({port, {:exit_status, status}}, state) do
    case pop_port(state.pods, port) do
      {nil, _pods} ->
        {:noreply, state}

      {%{pod_home: pod_home} = running, pods} ->
        _ = report_exit(pod_home, status, Map.get(running, :output, ""))

        case harvest_and_remove(pod_home, state.harvest) do
          :ok ->
            {:noreply, %{state | pods: pods}}

          {:error, reason} ->
            Logger.error(
              "runner pod harvest failed before automatic reap (pod_home=#{pod_home}): #{inspect(reason)}"
            )

            {:noreply, state}
        end
    end
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.pods, fn {_ref, %{port: port, os_pid: os_pid, pod_home: pod_home} = running} ->
      # A pod alive at launcher termination never exited on its own: the caller gave
      # up on it. exit-status reporting cannot fire for it (it is about to be killed,
      # not to exit), so this is the only place its captured output can surface.
      # A HANGING pod was previously as invisible as a failing one used to be.
      # Explicit `reap/1` stays silent -- it is the normal end of a healthy pod.
      Logger.error(
        "runner pod still running at launcher termination (pod_home=#{pod_home}); " <>
          "captured output tail: #{inspect(String.trim(Map.get(running, :output, "")))}"
      )

      _ = stop_namespace(port, os_pid)

      case harvest_and_remove(pod_home, state.harvest) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.error(
            "runner pod harvest failed at launcher termination; pod preserved " <>
              "(pod_home=#{pod_home}): #{inspect(reason)}"
          )
      end
    end)

    _ = Commonplace.Flock.unlock(state.lock)
    :ok
  end

  defp open_pod(spec, invocation) do
    with executable when is_binary(executable) <- System.find_executable(spec.executable) do
      invocation = pod_invocation(spec, invocation)

      port =
        Port.open(
          {:spawn_executable, executable},
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            {:args, spec.argv ++ invocation},
            {:env, port_environment(spec.environment)}
          ]
        )

      case Port.info(port, :os_pid) do
        {:os_pid, os_pid} -> {:ok, port, os_pid}
        nil -> {:error, {:launch_failed, Path.dirname(spec.workdir), :port_closed_during_launch}}
      end
    else
      nil -> {:error, {:launch_failed, Path.dirname(spec.workdir), :bubblewrap_not_found}}
    end
  rescue
    error -> {:error, {:launch_failed, Path.dirname(spec.workdir), Exception.message(error)}}
  end

  defp pod_invocation(%{relay: nil}, invocation), do: invocation

  defp pod_invocation(%{relay: relay, workdir: workdir}, invocation) do
    erl = System.find_executable("erl") || "erl"
    elixir_ebin = Application.app_dir(:elixir, "ebin")
    commonplace_ebin = Application.app_dir(:commonplace, "ebin")
    ready_path = Path.join(workdir, ".mediator-relay-ready")

    [
      "/bin/bash",
      "-c",
      relay_supervisor_script(),
      "mediator-relay-supervisor",
      erl,
      elixir_ebin,
      commonplace_ebin,
      relay.socket_path,
      Integer.to_string(relay.port),
      ready_path
      | invocation
    ]
  end

  defp relay_supervisor_script do
    """
    erl_bin="$1"
    elixir_ebin="$2"
    commonplace_ebin="$3"
    socket_path="$4"
    relay_port="$5"
    ready_path="$6"
    shift 6
    rm -f "$ready_path"
    "$erl_bin" -noshell -pa "$elixir_ebin" -pa "$commonplace_ebin" \
      -eval "application:ensure_all_started(elixir), \
        'Elixir.Commonplace.Runner.MediatorRelay':main_erl(init:get_plain_arguments())." \
      -extra \
      "$socket_path" "$relay_port" "$ready_path" &
    relay_pid=$!
    for _attempt in $(seq 1 100); do
      test -f "$ready_path" && break
      kill -0 "$relay_pid" 2>/dev/null || break
      sleep 0.01
    done
    if ! test -f "$ready_path"; then
      echo mediator_relay_start_failed >&2
      wait "$relay_pid"
      exit 70
    fi
    "$@" &
    payload_pid=$!
    wait -n -p finished_pid "$relay_pid" "$payload_pid"
    status=$?
    if test "$finished_pid" = "$relay_pid"; then
      echo mediator_relay_died >&2
      kill -TERM "$payload_pid" 2>/dev/null || true
      wait "$payload_pid" 2>/dev/null || true
      exit 70
    fi
    kill -TERM "$relay_pid" 2>/dev/null || true
    wait "$relay_pid" 2>/dev/null || true
    exit "$status"
    """
  end

  defp stop_namespace(port, os_pid) do
    if Port.info(port) == nil do
      :ok
    else
      monitor = :erlang.monitor(:port, port)
      signal(os_pid, "-TERM")

      if await_port_down(monitor, port, 2_000) do
        :ok
      else
        signal(os_pid, "-KILL")

        if await_port_down(monitor, port, 3_000) do
          :ok
        else
          :erlang.demonitor(monitor, [:flush])
          {:error, {:pod_namespace_survived, os_pid}}
        end
      end
    end
  end

  defp port_environment(environment) do
    environment
    |> Enum.sort()
    |> Enum.map(fn {name, value} -> {String.to_charlist(name), String.to_charlist(value)} end)
  end

  defp signal(os_pid, signal) do
    _ = System.cmd("kill", [signal, Integer.to_string(os_pid)], stderr_to_stdout: true)
    :ok
  end

  defp await_port_down(monitor, port, timeout) do
    receive do
      {:DOWN, ^monitor, :port, ^port, _reason} -> true
    after
      timeout -> false
    end
  end

  defp invocation(opts) do
    case Keyword.fetch(opts, :invocation) do
      {:ok, [executable | _] = invocation} when is_binary(executable) ->
        if Enum.all?(invocation, &is_binary/1),
          do: {:ok, invocation},
          else: {:error, {:invalid_invocation, :non_string_argument}}

      _ ->
        {:error, {:invalid_invocation, :required_nonempty_argv}}
    end
  end

  defp environment_available?(names, available_names) do
    missing = Enum.reject(names, &MapSet.member?(available_names, &1))

    case missing do
      [] ->
        :ok

      names ->
        {:refused,
         Enum.map(names, fn name ->
           "this placement does not supply declared environment variable #{name}"
         end)}
    end
  end

  defp resolve_environment(names, environment),
    do: Map.take(environment, names)

  defp recipe_invocation(recipe, environment) do
    assignments =
      environment
      |> Enum.sort()
      |> Enum.map(fn {name, value} -> "#{name}=#{value}" end)

    commands = recipe_value(recipe, :setup) ++ [recipe_value(recipe, :run)]
    ["/usr/bin/env", "-i"] ++ assignments ++ ["/bin/sh", "-eu", "-c", Enum.join(commands, "\n")]
  end

  defp recipe_value(recipe, field) do
    case Map.fetch(recipe, field) do
      {:ok, value} -> value
      :error -> Map.fetch!(recipe, Atom.to_string(field))
    end
  end

  defp required_path(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, path} when is_binary(path) and path != "" -> {:ok, Path.expand(path)}
      _ -> {:error, {:invalid_launcher, key}}
    end
  end

  defp require_dedicated_runner_service(opts) do
    case Keyword.fetch(opts, :dedicated_runner_service) do
      {:ok, true} -> :ok
      _ -> {:error, {:invalid_launcher, :dedicated_runner_service}}
    end
  end

  defp lock_root(pods_root) do
    lock_path = Path.join(pods_root, @lock_file)

    with :ok <- File.touch(lock_path),
         {:ok, lock} <- Commonplace.Flock.try_lock(lock_path, :exclusive) do
      {:ok, lock}
    end
  end

  defp reap_stale_homes(pods_root, harvest) do
    with {:ok, entries} <- File.ls(pods_root) do
      entries
      |> Enum.reject(&(&1 in [@lock_file, @quarantine_dir]))
      |> Enum.reduce_while(:ok, fn entry, :ok ->
        case harvest_and_remove(Path.join(pods_root, entry), harvest) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, {:stale_pod_harvest_failed, entry, reason}}}
        end
      end)
    end
  end

  defp harvest_options(pods_root, opts) do
    [
      store: Keyword.get(opts, :harvest_store, CommitStoreClient),
      quarantine_root: Path.join(pods_root, @quarantine_dir)
    ]
  end

  defp harvest_and_remove(pod_home, harvest) do
    with {:ok, _summary} <- ProtoChitHarvest.harvest(pod_home, harvest),
         :ok <- remove_pod_home(pod_home) do
      :ok
    end
  end

  defp remove_pod_home(pod_home) do
    case File.rm_rf(pod_home) do
      {:ok, _removed} -> :ok
      {:error, reason, path} -> {:error, {:pod_reap_failed, path, reason}}
    end
  end

  defp find_ref(pods, port) do
    case Enum.find(pods, fn {_ref, pod} -> pod.port == port end) do
      nil -> nil
      {ref, _pod} -> ref
    end
  end

  # A pod's stdout and stderr are merged by `:stderr_to_stdout` and were previously
  # discarded. They are the only channel through which bubblewrap can explain a
  # refusal, so the tail is retained -- bounded, because a chatty pod must not grow
  # a long-lived launcher's heap.
  defp append_tail(existing, chunk) do
    combined = existing <> chunk
    size = byte_size(combined)

    if size > @output_tail_bytes,
      do: binary_part(combined, size - @output_tail_bytes, @output_tail_bytes),
      else: combined
  end

  # A non-zero exit is the pod telling us why it could not run. Reporting it is the
  # difference between a diagnosis and `{:error, :timeout}`: the pod home is removed
  # immediately after, so anything not said here is unrecoverable.
  defp report_exit(_pod_home, 0, _output), do: :ok

  defp report_exit(pod_home, status, output) do
    Logger.error(
      "runner pod exited with status #{status} (pod_home=#{pod_home}); " <>
        "captured output tail: #{inspect(String.trim(output))}"
    )
  end

  defp pop_port(pods, port) do
    case Enum.find(pods, fn {_ref, pod} -> pod.port == port end) do
      nil -> {nil, pods}
      {ref, pod} -> {pod, Map.delete(pods, ref)}
    end
  end
end
