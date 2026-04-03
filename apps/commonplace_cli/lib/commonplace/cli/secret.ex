defmodule Commonplace.CLI.Secret do
  @moduledoc """
  CLI commands for managing secrets.

  Secrets are stored locally and never synced. They're injected into
  process environments when referenced as $secret:KEY_NAME.
  """

  alias Commonplace.Store.SecretStore

  def run(data_dir, _relative_path, args) do
    Commonplace.CLI.ensure_started(data_dir)

    case args do
      ["set", key_value] ->
        case String.split(key_value, "=", parts: 2) do
          [key, value] ->
            SecretStore.set(key, value)
            IO.puts("Secret set: #{key}")

          _ ->
            IO.puts(:stderr, "Usage: commonplace secret set KEY=VALUE")
            System.halt(1)
        end

      ["set", key, value] ->
        SecretStore.set(key, value)
        IO.puts("Secret set: #{key}")

      ["get", key] ->
        case SecretStore.get(key) do
          {:ok, value} ->
            IO.write(value)

          :not_found ->
            IO.puts(:stderr, "Secret not found: #{key}")
            System.halt(1)
        end

      ["list"] ->
        names = SecretStore.list()

        if names == [] do
          IO.puts("No secrets stored.")
        else
          Enum.each(names, &IO.puts/1)
        end

      ["delete", key] ->
        SecretStore.delete(key)
        IO.puts("Secret deleted: #{key}")

      [] ->
        print_usage()

      _ ->
        print_usage()
        System.halt(1)
    end
  end

  defp print_usage do
    IO.puts("""
    Usage: commonplace secret <command>

    Commands:
      set KEY=VALUE    Store a secret
      set KEY VALUE    Store a secret (alternate form)
      get KEY          Retrieve a secret value
      list             List all secret names
      delete KEY       Remove a secret
    """)
  end
end
