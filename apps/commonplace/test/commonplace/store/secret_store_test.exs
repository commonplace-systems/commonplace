defmodule Commonplace.Store.SecretStoreTest do
  use ExUnit.Case, async: false

  alias Commonplace.Store.SecretStore

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_secrets_#{:rand.uniform(999999)}")
    File.mkdir_p!(dir)
    {:ok, store} = SecretStore.start_link(data_dir: dir, name: :"secret_test_#{:rand.uniform(999999)}")

    on_exit(fn ->
      if Process.alive?(store), do: GenServer.stop(store)
      File.rm_rf!(dir)
    end)

    %{store: store}
  end

  test "set and get a secret", %{store: store} do
    assert :ok = SecretStore.set(store, "API_KEY", "sk-12345")
    assert {:ok, "sk-12345"} = SecretStore.get(store, "API_KEY")
  end

  test "get returns :not_found for missing secret", %{store: store} do
    assert :not_found = SecretStore.get(store, "MISSING")
  end

  test "set overwrites existing secret", %{store: store} do
    SecretStore.set(store, "KEY", "old")
    SecretStore.set(store, "KEY", "new")
    assert {:ok, "new"} = SecretStore.get(store, "KEY")
  end

  test "list returns sorted secret names", %{store: store} do
    SecretStore.set(store, "ZEBRA", "z")
    SecretStore.set(store, "ALPHA", "a")
    SecretStore.set(store, "MIDDLE", "m")
    assert SecretStore.list(store) == ["ALPHA", "MIDDLE", "ZEBRA"]
  end

  test "list returns empty list when no secrets", %{store: store} do
    assert SecretStore.list(store) == []
  end

  test "delete removes a secret", %{store: store} do
    SecretStore.set(store, "KEY", "value")
    assert :ok = SecretStore.delete(store, "KEY")
    assert :not_found = SecretStore.get(store, "KEY")
  end

  test "delete is idempotent", %{store: store} do
    assert :ok = SecretStore.delete(store, "NONEXISTENT")
  end

  test "resolve_env replaces $secret: references", %{store: store} do
    SecretStore.set(store, "API_KEY", "sk-12345")
    SecretStore.set(store, "DB_PASS", "hunter2")

    env = %{
      "API_KEY" => "$secret:API_KEY",
      "DB_PASSWORD" => "$secret:DB_PASS",
      "PLAIN_VAR" => "hello"
    }

    assert {:ok, resolved} = SecretStore.resolve_env(store, env)
    assert resolved["API_KEY"] == "sk-12345"
    assert resolved["DB_PASSWORD"] == "hunter2"
    assert resolved["PLAIN_VAR"] == "hello"
  end

  test "resolve_env returns error for missing secrets", %{store: store} do
    env = %{"KEY" => "$secret:MISSING"}
    assert {:error, {:missing_secrets, ["MISSING"]}} = SecretStore.resolve_env(store, env)
  end

  test "resolve_env with no secret refs passes through", %{store: store} do
    env = %{"A" => "1", "B" => "2"}
    assert {:ok, ^env} = SecretStore.resolve_env(store, env)
  end

  test "resolve_env with empty map", %{store: store} do
    assert {:ok, %{}} = SecretStore.resolve_env(store, %{})
  end
end
