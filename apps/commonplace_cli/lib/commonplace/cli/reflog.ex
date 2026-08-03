defmodule Commonplace.CLI.Reflog do
  @moduledoc """
  Reflog checkpoint listing, restore, checkout, and diff (CX-0t2r).

  Usage:
    commonplace reflog list [--owner name]
    commonplace reflog restore <checkpoint-commit-id> [--owner name] [--as name]
    commonplace reflog checkout <checkpoint-commit-id> <dest-dir> [--owner name] [--force]
    commonplace reflog diff <checkpoint-commit-id> [<other-checkpoint-id>] [--owner name]

  `list` enumerates checkpoints (newest first) recorded under
  `__reflog/<owner>/` for the workspace root.

  `restore` resolves one checkpoint (by its commit id, as printed by
  `list`) and materializes it as a fresh branch grafted onto the
  workspace root — the source tree is never mutated. NOTE: `restore`
  is currently REFUSED. Fresh-genesis branch materialization has no
  shared ancestry with the docs it was resolved from, so a later
  merge-back would silently find no common history. This is fixed by
  CX-0t2r stage 3 (fork-anchored materialization); until then there is
  no CLI bypass.

  `checkout` materializes a checkpoint to plain files on disk under
  `<dest-dir>` — zero store writes, no CRDT docs minted. Refuses to
  write into a directory that is inside a registered sync checkout, or
  into a non-empty directory without `--force`.

  `diff` compares a checkpoint against either the current live tree
  (default) or another checkpoint, printing a git-status-like listing.

  All checkout/restore/diff output is labelled "as seen by witness
  <owner> at <timestamp>" — a checkpoint reflects what its writer saw
  at serialization time, not a guarantee of invariant-safety.
  """

  alias Commonplace.CLI
  alias Commonplace.Reflog.Restore
  alias Commonplace.Store.CommitStoreClient

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

      ["checkout" | rest] ->
        run_checkout(data_dir, root, rest)

      ["diff" | rest] ->
        run_diff(root, rest)

      _ ->
        IO.puts(:stderr, @moduledoc)
        System.halt(1)
    end
  end

  defp run_list(root, args) do
    {opts, _rest, _} = OptionParser.parse(args, strict: [owner: :string])
    owner = Keyword.get(opts, :owner, "server")

    checkpoints = Restore.list_checkpoints(CommitStoreClient, root, owner)

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
    store = CommitStoreClient

    with {:ok, commit_id} <- decode_commit_id(commit_id_hex),
         {:ok, snapshot_uuid} <- Restore.root_snapshot_uuid(store, root, owner),
         {:ok, resolved} <- Restore.resolve(store, snapshot_uuid, commit_id) do
      restore_opts = if opts[:as], do: [as: opts[:as]], else: []

      case Restore.materialize_branch(store, resolved, root, restore_opts) do
        {:ok, %{root_entry: name, docs: count}} ->
          IO.puts("Restored checkpoint #{commit_id_hex} as #{name} (#{count} doc(s)).")

        {:error, {:awaiting_stage3_ancestry_rework, bead}} ->
          IO.puts(:stderr,
            "reflog restore is refused: branch materialization has no shared ancestry " <>
              "with the source docs, so a later merge-back would silently find no common " <>
              "history. Fixed by #{bead} stage 3 (fork-anchored materialization); no bypass " <>
              "is available from the CLI. Use 'reflog checkout <commit-id> <dest-dir>' to " <>
              "materialize this checkpoint to plain files instead."
          )

          System.halt(1)

        {:error, reason} ->
          IO.puts(:stderr, "Restore failed: #{inspect(reason)}")
          System.halt(1)
      end
    else
      :error ->
        IO.puts(:stderr, "No checkpoints found for owner #{inspect(owner)}.")
        System.halt(1)

      {:error, reason} ->
        IO.puts(:stderr, "Restore failed: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp run_checkout(data_dir, root, args) do
    {opts, rest, _} = OptionParser.parse(args, strict: [owner: :string, force: :boolean])
    owner = Keyword.get(opts, :owner, "server")
    force = Keyword.get(opts, :force, false)

    case rest do
      [commit_id_hex, dest_dir | _] ->
        do_checkout(data_dir, root, owner, commit_id_hex, dest_dir, force)

      _ ->
        IO.puts(:stderr, "Usage: commonplace reflog checkout <checkpoint-commit-id> <dest-dir> [--owner name] [--force]")
        System.halt(1)
    end
  end

  defp do_checkout(data_dir, root, owner, commit_id_hex, dest_dir, force) do
    store = CommitStoreClient
    config_path = Path.join(data_dir, "checkouts.json")

    with {:ok, commit_id} <- decode_commit_id(commit_id_hex),
         {:ok, snapshot_uuid} <- Restore.root_snapshot_uuid(store, root, owner),
         {:ok, resolved} <- Restore.resolve(store, snapshot_uuid, commit_id),
         {:ok, checkpoint_commit} <- CommitStoreClient.get_commit(store, commit_id) do
      materialize_opts = [
        config_path: config_path,
        force: force,
        owner: owner,
        at: checkpoint_commit.timestamp
      ]

      case Restore.materialize_dir(store, resolved, dest_dir, materialize_opts) do
        {:ok, %{files: n, dest: dest, witness: witness, at: at}} ->
          IO.puts(
            "Materialized #{n} file(s) to #{dest} — as seen by witness #{inspect(witness)} at #{DateTime.to_iso8601(at)}."
          )

        {:error, {:dest_inside_checkout, checkout}} ->
          IO.puts(:stderr,
            "Refusing: #{dest_dir} is inside registered checkout #{inspect(checkout.sync_dir)} " <>
              "(uuid #{checkout.uuid}). A reflog checkout must never touch a live sync tree."
          )

          System.halt(1)

        {:error, {:dest_not_empty, dir}} ->
          IO.puts(:stderr, "Refusing: #{dir} is non-empty. Pass --force to overwrite.")
          System.halt(1)

        {:error, reason} ->
          IO.puts(:stderr, "Checkout failed: #{inspect(reason)}")
          System.halt(1)
      end
    else
      :error ->
        IO.puts(:stderr, "No checkpoints found for owner #{inspect(owner)}.")
        System.halt(1)

      :none ->
        IO.puts(:stderr, "Checkpoint commit #{commit_id_hex} not found.")
        System.halt(1)

      {:error, reason} ->
        IO.puts(:stderr, "Checkout failed: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp run_diff(root, args) do
    {opts, rest, _} = OptionParser.parse(args, strict: [owner: :string])
    owner = Keyword.get(opts, :owner, "server")

    case rest do
      [commit_id_hex] ->
        do_diff(root, owner, commit_id_hex, nil)

      [commit_id_hex, other_commit_id_hex] ->
        do_diff(root, owner, commit_id_hex, other_commit_id_hex)

      _ ->
        IO.puts(:stderr, "Usage: commonplace reflog diff <checkpoint-commit-id> [<other-checkpoint-id>] [--owner name]")
        System.halt(1)
    end
  end

  defp do_diff(root, owner, commit_id_hex, other_commit_id_hex) do
    store = CommitStoreClient

    with {:ok, commit_id} <- decode_commit_id(commit_id_hex),
         {:ok, snapshot_uuid} <- Restore.root_snapshot_uuid(store, root, owner),
         {:ok, resolved} <- Restore.resolve(store, snapshot_uuid, commit_id),
         {:ok, checkpoint_commit} <- CommitStoreClient.get_commit(store, commit_id),
         {:ok, against} <- resolve_against(store, snapshot_uuid, other_commit_id_hex, root),
         {:ok, diff} <- Restore.diff(store, resolved, against) do
      label =
        case other_commit_id_hex do
          nil -> "current tree"
          other -> "checkpoint #{other}"
        end

      IO.puts(
        "Diff: checkpoint #{commit_id_hex} vs #{label} — as seen by witness #{inspect(owner)} at #{DateTime.to_iso8601(checkpoint_commit.timestamp)}.\n"
      )

      print_diff(diff)
    else
      :error ->
        IO.puts(:stderr, "No checkpoints found for owner #{inspect(owner)}.")
        System.halt(1)

      :none ->
        IO.puts(:stderr, "Checkpoint commit #{commit_id_hex} not found.")
        System.halt(1)

      {:error, reason} ->
        IO.puts(:stderr, "Diff failed: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp resolve_against(_store, _snapshot_uuid, nil, root), do: {:ok, {:current, root}}

  defp resolve_against(store, snapshot_uuid, other_commit_id_hex, _root) do
    with {:ok, other_commit_id} <- decode_commit_id(other_commit_id_hex),
         {:ok, other_resolved} <- Restore.resolve(store, snapshot_uuid, other_commit_id) do
      {:ok, {:checkpoint, other_resolved}}
    end
  end

  defp print_diff(%{added: added, removed: removed, changed: changed}) do
    if added == [] and removed == [] and changed == [] do
      IO.puts("  (no differences)")
    else
      Enum.each(removed, fn path -> IO.puts("  D  #{path}") end)

      Enum.each(changed, fn
        {path, :changed} -> IO.puts("  M  #{path}")
        {path, :replaced} -> IO.puts("  R  #{path}")
      end)

      Enum.each(added, fn path -> IO.puts("  A  #{path}") end)
    end
  end

  defp decode_commit_id(hex) do
    case Base.decode16(hex, case: :mixed) do
      {:ok, bin} -> {:ok, bin}
      :error -> {:error, {:invalid_commit_id, hex}}
    end
  end
end
