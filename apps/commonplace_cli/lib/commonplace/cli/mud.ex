defmodule Commonplace.CLI.Mud do
  @moduledoc """
  MUD client subcommand: `commonplace mud connect <name>`.

  Ensures the workspace is started (connecting to a running serve if
  available), seeds the v0 world on first use, spawns a local
  PlayerSession actor, and bridges stdin/stdout to it.

  Multiple `mud connect` invocations from different terminals share the
  serve daemon's CommitStore (via remote routing) and Phoenix PubSub
  (via cluster pg), so they see each other's events.
  """

  alias Commonplace.CLI
  alias Commonplace.MUD.{Bootstrap, PlayerSession}
  alias Commonplace.Store.CommitStoreClient

  def run(data_dir, _relative_path, args) do
    case args do
      ["connect", name] -> connect(data_dir, name)
      ["connect"] ->
        IO.puts(:stderr, "Usage: commonplace mud connect <name>")
        System.halt(1)
      _ ->
        IO.puts(:stderr, "Usage: commonplace mud connect <name>")
        System.halt(1)
    end
  end

  defp connect(data_dir, name) do
    if not valid_player_name?(name) do
      IO.puts(:stderr, "Player name must be lowercase letters/digits/_- only.")
      System.halt(1)
    end

    CLI.ensure_started(data_dir)

    root = CLI.root_uuid(data_dir)

    if is_nil(root) do
      IO.puts(:stderr, "No root UUID — run 'commonplace init' first.")
      System.halt(1)
    end

    {:ok, :ready} = Bootstrap.seed(root, CommitStoreClient)

    {:ok, session} =
      PlayerSession.start_link(
        player_name: name,
        root_uuid: root,
        store: CommitStoreClient,
        output_fn: &output_line/1,
        owner_pid: self()
      )

    Process.flag(:trap_exit, true)
    ref = Process.monitor(session)
    loop(session, ref)
  end

  defp loop(session, ref) do
    receive do
      {:DOWN, ^ref, :process, ^session, _reason} ->
        :ok

      {:player_session_quit, ^session} ->
        :ok
    after
      0 -> :ok
    end

    case IO.gets("> ") do
      :eof ->
        PlayerSession.stop(session)

      {:error, _} ->
        PlayerSession.stop(session)

      line when is_binary(line) ->
        line = String.trim_trailing(line, "\n")
        PlayerSession.input(session, line)

        receive do
          {:DOWN, ^ref, :process, ^session, _reason} -> :ok
          {:player_session_quit, ^session} -> :ok
        after
          50 -> loop(session, ref)
        end
    end
  end

  defp output_line(text) when is_binary(text), do: IO.puts(text)

  defp valid_player_name?(name) do
    Regex.match?(~r/\A[a-z0-9_-]+\z/, name)
  end
end
