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

  alias Commonplace.Runner.{PodHandle, PodProfile, Provisioner, RunRecipe}

  @lock_file ".runner.lock"

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
    with {:ok, pods_root} <- required_path(opts, :pods_root),
         :ok <- File.mkdir_p(pods_root),
         {:ok, lock} <- lock_root(pods_root),
         :ok <- reap_stale_homes(pods_root) do
      {:ok, %{pods_root: pods_root, lock: lock, pods: %{}}}
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

      running = %{port: port, os_pid: os_pid, pod_home: pod.pod_home}
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
             Provisioner.sandbox_spec(profile, state.pods_root).environment
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

      running = %{port: port, os_pid: os_pid, pod_home: pod.pod_home}
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
            :ok = remove_pod_home(pod_home)
            {:reply, :ok, %{state | pods: pods}}

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
  def handle_info({port, {:data, _output}}, state) do
    if pod_port?(state.pods, port), do: {:noreply, state}, else: {:noreply, state}
  end

  def handle_info({port, {:exit_status, _status}}, state) do
    case pop_port(state.pods, port) do
      {nil, _pods} ->
        {:noreply, state}

      {%{pod_home: pod_home}, pods} ->
        :ok = remove_pod_home(pod_home)
        {:noreply, %{state | pods: pods}}
    end
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.pods, fn {_ref, %{port: port, os_pid: os_pid, pod_home: pod_home}} ->
      _ = stop_namespace(port, os_pid)
      _ = File.rm_rf(pod_home)
    end)

    _ = Commonplace.Sync.Flock.unlock(state.lock)
    :ok
  end

  defp open_pod(spec, invocation) do
    with executable when is_binary(executable) <- System.find_executable(spec.executable) do
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

  defp environment_available?(names, environment) do
    missing = Enum.reject(names, &Map.has_key?(environment, &1))

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

  # `Map.fetch!` and not `Map.take`: the availability check above ran against
  # `sandbox_spec(profile, pods_root)` while this resolves against the REAL
  # pod's spec. Those are two different objects, and they agree only because
  # the environment key set is a fixed literal independent of `pod_home`. A
  # total function here would drop a declared variable SILENTLY if that ever
  # lapses; this makes the disagreement loud. It does not remove it — one
  # check against one object is a provisioning-order question, still open.
  defp resolve_environment(names, environment),
    do: Map.new(names, fn name -> {name, Map.fetch!(environment, name)} end)

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

  defp lock_root(pods_root) do
    lock_path = Path.join(pods_root, @lock_file)

    with :ok <- File.touch(lock_path),
         {:ok, lock} <- Commonplace.Sync.Flock.try_lock(lock_path, :exclusive) do
      {:ok, lock}
    end
  end

  defp reap_stale_homes(pods_root) do
    with {:ok, entries} <- File.ls(pods_root) do
      entries
      |> Enum.reject(&(&1 == @lock_file))
      |> Enum.each(fn entry -> File.rm_rf(Path.join(pods_root, entry)) end)

      :ok
    end
  end

  defp remove_pod_home(pod_home) do
    case File.rm_rf(pod_home) do
      {:ok, _removed} -> :ok
      {:error, reason, path} -> {:error, {:pod_reap_failed, path, reason}}
    end
  end

  defp pod_port?(pods, port), do: Enum.any?(pods, fn {_ref, pod} -> pod.port == port end)

  defp pop_port(pods, port) do
    case Enum.find(pods, fn {_ref, pod} -> pod.port == port end) do
      nil -> {nil, pods}
      {ref, pod} -> {pod, Map.delete(pods, ref)}
    end
  end
end
