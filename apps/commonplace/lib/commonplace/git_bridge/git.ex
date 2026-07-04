defmodule Commonplace.GitBridge.Git do
  @moduledoc """
  Thin, non-raising wrapper around the `git` CLI for GitBridge.

  Every function returns a tagged tuple (`:ok` / `{:ok, _}` /
  `{:error, reason}`) and never raises — GitBridge's `Server` must stay
  alive across git failures (missing binary, unreachable remote,
  detached HEAD, etc.) and retry on the next tick rather than crash.
  """

  @doc """
  Ensure `repo_dir` exists and is a git repository, on `branch` if given.

  Creates `repo_dir` if missing, runs `git init` if there is no `.git`
  yet, and makes sure `branch` is the checked-out branch (checkout -b on
  a fresh init, or a rename via `-M` on an existing repo whose current
  branch differs).
  """
  @spec ensure_repo(String.t(), String.t() | nil) :: :ok | {:error, term()}
  def ensure_repo(repo_dir, branch \\ nil) do
    with :ok <- mkdir_p(repo_dir),
         {:ok, fresh?} <- ensure_git_dir(repo_dir),
         :ok <- ensure_branch(repo_dir, branch, fresh?) do
      :ok
    end
  end

  defp mkdir_p(dir) do
    case File.mkdir_p(dir) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_git_dir(repo_dir) do
    git_dir = Path.join(repo_dir, ".git")

    if File.dir?(git_dir) do
      {:ok, false}
    else
      case run(repo_dir, ["init"]) do
        {:ok, _} -> {:ok, true}
        error -> error
      end
    end
  end

  defp ensure_branch(_repo_dir, nil, _fresh?), do: :ok

  defp ensure_branch(repo_dir, branch, true) do
    case run(repo_dir, ["checkout", "-b", branch]) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp ensure_branch(repo_dir, branch, false) do
    case current_branch(repo_dir) do
      {:ok, ^branch} ->
        :ok

      {:ok, _other} ->
        case run(repo_dir, ["branch", "-M", branch]) do
          {:ok, _} -> :ok
          error -> error
        end

      {:error, _} ->
        # No commits yet (unborn HEAD) — checkout -b works here too.
        case run(repo_dir, ["checkout", "-b", branch]) do
          {:ok, _} -> :ok
          error -> error
        end
    end
  end

  defp current_branch(repo_dir) do
    case run(repo_dir, ["rev-parse", "--abbrev-ref", "HEAD"]) do
      {:ok, out} -> {:ok, String.trim(out)}
      error -> error
    end
  end

  @doc "Returns `{:ok, true | false}` — whether the working tree has uncommitted changes."
  @spec dirty?(String.t()) :: {:ok, boolean()} | {:error, term()}
  def dirty?(repo_dir) do
    case run(repo_dir, ["status", "--porcelain"]) do
      {:ok, out} -> {:ok, String.trim(out) != ""}
      error -> error
    end
  end

  @doc """
  Stage everything and commit under the `commonplace-bridge` author.

  `opts`:
    * `:authors` — `MapSet.t()` or list of signer_id strings; when
      non-empty, appended as a `Commonplace-Authors: a, b` trailer.
    * `:message` — override the default `"commonplace sync <ISO8601>"`.

  Returns `{:ok, commit_sha}` or `{:error, reason}`.
  """
  @spec commit_all(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def commit_all(repo_dir, opts \\ []) do
    authors = opts |> Keyword.get(:authors, []) |> Enum.to_list() |> Enum.reject(&is_nil/1) |> Enum.uniq() |> Enum.sort()

    message =
      Keyword.get_lazy(opts, :message, fn ->
        "commonplace sync #{DateTime.utc_now() |> DateTime.to_iso8601()}"
      end)

    full_message =
      case authors do
        [] -> message
        _ -> message <> "\n\nCommonplace-Authors: " <> Enum.join(authors, ", ")
      end

    with {:ok, _} <- run(repo_dir, ["add", "-A"]),
         {:ok, _} <-
           run(repo_dir, [
             "commit",
             "--author",
             "commonplace-bridge <bridge@commonplace.local>",
             "-m",
             full_message
           ]),
         {:ok, sha} <- run(repo_dir, ["rev-parse", "HEAD"]) do
      {:ok, String.trim(sha)}
    end
  end

  @doc "Add a remote — mainly a test convenience."
  @spec add_remote(String.t(), String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def add_remote(repo_dir, name, url) do
    run(repo_dir, ["remote", "add", name, url])
  end

  @doc """
  Push `branch` to `remote`. Never uses `--force`. No-op-safe: caller is
  responsible for deciding whether a remote is configured before calling.
  """
  @spec push(String.t(), String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def push(repo_dir, remote, branch) do
    run(repo_dir, ["push", remote, branch])
  end

  @doc "Returns `{:ok, tree_hash}` for `HEAD^{tree}`."
  @spec head_tree_hash(String.t()) :: {:ok, String.t()} | {:error, term()}
  def head_tree_hash(repo_dir) do
    case run(repo_dir, ["rev-parse", "HEAD^{tree}"]) do
      {:ok, out} -> {:ok, String.trim(out)}
      error -> error
    end
  end

  # --- Private ---

  defp run(repo_dir, args) do
    try do
      case System.cmd("git", args, cd: repo_dir, stderr_to_stdout: true) do
        {out, 0} -> {:ok, out}
        {out, _code} -> {:error, String.trim(out)}
      end
    rescue
      error -> {:error, Exception.message(error)}
    catch
      kind, reason -> {:error, {kind, reason}}
    end
  end
end
