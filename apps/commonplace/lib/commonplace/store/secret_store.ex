defmodule Commonplace.Store.SecretStore do
  @moduledoc """
  Local CubDB-backed storage for secrets.

  Secrets are node-local, never synced via CRDTs or PubSub.
  Used to inject keypairs and API tokens into process environments.
  """

  use GenServer

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Store a secret. Overwrites if it already exists."
  def set(server \\ __MODULE__, name, value) when is_binary(name) and is_binary(value) do
    GenServer.call(server, {:set, name, value})
  end

  @doc "Retrieve a secret by name. Returns {:ok, value} or :not_found."
  def get(server \\ __MODULE__, name) when is_binary(name) do
    GenServer.call(server, {:get, name})
  end

  @doc "List all secret names (not values)."
  def list(server \\ __MODULE__) do
    GenServer.call(server, :list)
  end

  @doc "Delete a secret. Returns :ok even if it didn't exist."
  def delete(server \\ __MODULE__, name) when is_binary(name) do
    GenServer.call(server, {:delete, name})
  end

  @doc """
  Resolve secret references in an env map.

  Values matching the pattern "$secret:KEY_NAME" are replaced with the
  secret's value from the store. Non-matching values pass through unchanged.
  Returns {:ok, resolved_map} or {:error, {:missing_secrets, [name, ...]}}.
  """
  def resolve_env(server \\ __MODULE__, env) when is_map(env) do
    GenServer.call(server, {:resolve_env, env})
  end

  # --- GenServer callbacks ---

  @impl true
  def init(opts) do
    data_dir = Keyword.fetch!(opts, :data_dir)
    path = Path.join(data_dir, "secrets")
    File.mkdir_p!(path)

    {:ok, db} = CubDB.start_link(data_dir: path, auto_compact: true)
    {:ok, %{db: db}}
  end

  @impl true
  def handle_call({:set, name, value}, _from, state) do
    CubDB.put(state.db, {:secret, name}, value)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:get, name}, _from, state) do
    case CubDB.get(state.db, {:secret, name}) do
      nil -> {:reply, :not_found, state}
      value -> {:reply, {:ok, value}, state}
    end
  end

  @impl true
  def handle_call(:list, _from, state) do
    names =
      CubDB.select(state.db)
      |> Stream.filter(fn {{type, _}, _} -> type == :secret end)
      |> Enum.map(fn {{:secret, name}, _} -> name end)
      |> Enum.sort()

    {:reply, names, state}
  end

  @impl true
  def handle_call({:delete, name}, _from, state) do
    CubDB.delete(state.db, {:secret, name})
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:resolve_env, env}, _from, state) do
    {resolved, missing} =
      Enum.reduce(env, {%{}, []}, fn {key, value}, {acc, missing} ->
        case parse_secret_ref(value) do
          {:secret, secret_name} ->
            case CubDB.get(state.db, {:secret, secret_name}) do
              nil -> {Map.put(acc, key, value), [secret_name | missing]}
              secret_value -> {Map.put(acc, key, secret_value), missing}
            end

          :literal ->
            {Map.put(acc, key, value), missing}
        end
      end)

    case missing do
      [] -> {:reply, {:ok, resolved}, state}
      names -> {:reply, {:error, {:missing_secrets, Enum.reverse(names)}}, state}
    end
  end

  defp parse_secret_ref("$secret:" <> name), do: {:secret, name}
  defp parse_secret_ref(_), do: :literal
end
