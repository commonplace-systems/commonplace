defmodule Commonplace.Process.SecretResolutionTest do
  use ExUnit.Case, async: false

  alias Commonplace.Store.SecretStore

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_secret_res_#{:rand.uniform(999999)}")
    File.mkdir_p!(dir)

    name = :"secret_res_test_#{:rand.uniform(999999)}"
    {:ok, store} = SecretStore.start_link(data_dir: dir, name: name)

    on_exit(fn ->
      if Process.alive?(store), do: (try do GenServer.stop(store) catch (:exit, _ -> :ok) end)
      File.rm_rf!(dir)
    end)

    %{store: store}
  end

  test "resolve_env replaces $secret: references with stored values", %{store: store} do
    SecretStore.set(store, "API_KEY", "sk-test-12345")

    env = %{"API_KEY" => "$secret:API_KEY", "PLAIN" => "hello"}
    assert {:ok, resolved} = SecretStore.resolve_env(store, env)
    assert resolved["API_KEY"] == "sk-test-12345"
    assert resolved["PLAIN"] == "hello"
  end

  test "resolve_env reports missing secrets", %{store: store} do
    env = %{"KEY" => "$secret:NONEXISTENT"}
    assert {:error, {:missing_secrets, ["NONEXISTENT"]}} = SecretStore.resolve_env(store, env)
  end

  test "resolve_env handles mixed secret and plain values", %{store: store} do
    SecretStore.set(store, "DB_PASS", "hunter2")

    env = %{
      "DB_PASSWORD" => "$secret:DB_PASS",
      "DB_HOST" => "localhost",
      "DB_PORT" => "5432"
    }

    assert {:ok, resolved} = SecretStore.resolve_env(store, env)
    assert resolved["DB_PASSWORD"] == "hunter2"
    assert resolved["DB_HOST"] == "localhost"
    assert resolved["DB_PORT"] == "5432"
  end
end
