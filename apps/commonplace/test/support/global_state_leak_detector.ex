defmodule Commonplace.Test.GlobalStateLeakDetector do
  @moduledoc """
  ExUnit formatter that reports every test which leaks watched global state.

  The formatter snapshots state on `:test_started` and again on
  `:test_finished`. The suite runs with `max_cases: 1`, configured in
  `test_helper.exs`, so another test cannot mutate the globals between those
  two observations and receive the blame.

  This watched set is deliberately a hypothesis, not a claim that it covers
  every possible source of cross-test contamination.
  """

  use GenServer

  @result_key {__MODULE__, :result}
  @app_env_keys [:data_dir, :trust, :local_write_gate]
  @public_key_artifact "node_signing_public_keys.json"

  @type snapshot :: map()

  @impl true
  def init(_opts) do
    :persistent_term.put(@result_key, :clean)
    {:ok, %{entries: %{}, divergences: []}}
  end

  @impl true
  def handle_cast({:test_started, test}, state) do
    {:noreply, put_in(state.entries[test_id(test)], snapshot())}
  end

  def handle_cast({:test_finished, test}, state) do
    id = test_id(test)
    {entry, entries} = Map.pop(state.entries, id)

    state =
      if is_map(entry) do
        record_divergence(state, test, entry, snapshot())
      else
        state
      end

    {:noreply, %{state | entries: entries}}
  end

  def handle_cast(_event, state), do: {:noreply, state}

  @doc "Returns the five values watched by the permanent detector."
  @spec snapshot() :: snapshot()
  def snapshot do
    data_dir = Application.get_env(:commonplace, :data_dir, "data")
    artifact_path = data_dir |> Path.join(@public_key_artifact) |> Path.expand()

    app_env =
      Map.new(@app_env_keys, fn key ->
        {{:application_env, :commonplace, key}, Application.fetch_env(:commonplace, key)}
      end)

    Map.merge(app_env, %{
      {:file_exists, :node_signing_public_key_artifact} => %{
        path: artifact_path,
        exists?: File.exists?(artifact_path)
      },
      {:file_content_sha256, :node_signing_public_key_artifact} =>
        file_content_sha256(artifact_path)
    })
  end

  @doc "Turns detected divergences into a failing suite after formatters flush."
  @spec assert_clean!(map()) :: :ok
  def assert_clean!(_suite_result) do
    case :persistent_term.get(@result_key, :detector_did_not_start) do
      :clean ->
        IO.puts("GLOBAL STATE LEAK DETECTOR: no divergence in the five watched values")
        :ok

      {:divergences, divergences} ->
        raise ExUnit.AssertionError, message: divergences_message(divergences)

      :detector_did_not_start ->
        raise ExUnit.AssertionError,
          message: "GLOBAL STATE LEAK DETECTOR DID NOT START; watched-state result is unknown"
    end
  end

  defp record_divergence(state, test, entry, exit) do
    changed =
      entry
      |> Map.keys()
      |> Enum.filter(&(Map.fetch!(entry, &1) != Map.fetch!(exit, &1)))
      |> Map.new(&{&1, %{entry: Map.fetch!(entry, &1), exit: Map.fetch!(exit, &1)}})

    if changed == %{} do
      state
    else
      divergence = %{test: test_name(test), changed: changed}
      divergences = state.divergences ++ [divergence]
      :persistent_term.put(@result_key, {:divergences, divergences})
      IO.puts(divergence_message(divergence))
      %{state | divergences: divergences}
    end
  end

  defp file_content_sha256(path) do
    case File.read(path) do
      {:ok, content} ->
        content
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.encode16(case: :lower)

      {:error, reason} ->
        {:unavailable, reason}
    end
  end

  defp divergences_message(divergences) do
    [
      "GLOBAL STATE LEAK DETECTOR FOUND #{length(divergences)} DIVERGENCE(S):"
      | Enum.map(divergences, &divergence_message/1)
    ]
    |> Enum.join("\n")
  end

  defp divergence_message(divergence) do
    "GLOBAL STATE DIVERGENCE DETECTED: #{divergence.test}; changed=#{inspect(divergence.changed, pretty: true)}"
  end

  defp test_id(test), do: {test.module, test.name, test.parameters}

  defp test_name(test) do
    "#{inspect(test.module)} — #{Atom.to_string(test.name)}"
  end
end
