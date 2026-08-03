defmodule Commonplace.CLI.Reflog do
  @moduledoc """
  Reflog checkpoint listing and restore (CX-0t2r).

  Usage:
    commonplace reflog list [--owner name]
    commonplace reflog restore <checkpoint-commit-id> [--owner name] [--as name]

  `list` enumerates checkpoints (newest first) recorded under
  `__reflog/<owner>/` for the workspace root. `restore` resolves one
  checkpoint (by its commit id, as printed by `list`) and materializes
  it as a fresh branch grafted onto the workspace root — the source
  tree is never mutated.
  """

  alias Commonplace.CLI
  alias Commonplace.Reflog.Restore

  def run(data_dir, _relative_path, args) do
    CLI.ensure_started(data_dir)
    root = CLI.root_uuid(data_dir)

    unless root do
      IO.puts(:stderr, "Not a commonplace workspace. Run 'commonplace init' first.")
      System.halt(1)
    end

    case args do
      ["list" | rest] ->
        run_list(root, rest)

      ["restore" | rest] ->
        run_restore(root, rest)

      _ ->
        IO.puts(:stderr, @moduledoc)
        System.halt(1)
    end
  end

  defp run_list(root, args) do
    {opts, _rest, _} = OptionParser.parse(args, strict: [owner: :string])
    owner = Keyword.get(opts, :owner, "server")

    checkpoints = Restore.list_checkpoints(Commonplace.Store.CommitStoreClient, root, owner)

    if checkpoints == [] do
      IO.puts("No checkpoints found for owner #{inspect(owner)}.")
    else
      IO.puts("Checkpoints for owner #{inspect(owner)} (newest first):\n")

      Enum.each(checkpoints, fn {commit_id, timestamp, signer_id} ->
        id_hex = Base.encode16(commit_id, case: :lower)
        signer = signer_id || "(unsigned)"
        IO.puts("  #{id_hex}  #{DateTime.to_iso8601(timestamp)}  signer:#{signer}")
      end)
    end
  end

  defp run_restore(root, args) do
    {opts, rest, _} = OptionParser.parse(args, strict: [owner: :string, as: :string])
    owner = Keyword.get(opts, :owner, "server")

    case rest do
      [commit_id_hex | _] ->
        do_restore(root, owner, commit_id_hex, opts)

      [] ->
        IO.puts(:stderr, "Usage: commonplace reflog restore <checkpoint-commit-id> [--owner name] [--as name]")
        System.halt(1)
    end
  end

  defp do_restore(root, owner, commit_id_hex, opts) do
    store = Commonplace.Store.CommitStoreClient

    with {:ok, commit_id} <- decode_commit_id(commit_id_hex),
         {:ok, snapshot_uuid} <- Restore.root_snapshot_uuid(store, root, owner),
         {:ok, resolved} <- Restore.resolve(store, snapshot_uuid, commit_id) do
      restore_opts = if opts[:as], do: [as: opts[:as]], else: []

      {:ok, %{root_entry: name, docs: count}} =
        Restore.materialize_branch(store, resolved, root, restore_opts)

      IO.puts("Restored checkpoint #{commit_id_hex} as #{name} (#{count} doc(s)).")
    else
      :error ->
        IO.puts(:stderr, "No checkpoints found for owner #{inspect(owner)}.")
        System.halt(1)

      {:error, reason} ->
        IO.puts(:stderr, "Restore failed: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp decode_commit_id(hex) do
    case Base.decode16(hex, case: :mixed) do
      {:ok, bin} -> {:ok, bin}
      :error -> {:error, {:invalid_commit_id, hex}}
    end
  end
end
