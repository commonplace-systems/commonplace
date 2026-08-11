defmodule Commonplace.CLI.ProtoChit do
  @moduledoc """
  Internal command used by the worktree-local proto-chit git shim.

  Usage:
    commonplace proto-chit emit --repo DIR --state-dir DIR --event-log UUID
      [--real-git PATH] [--trace FILE]
      [--sync-exclude NAME]... [--declare-empty-sync-excludes] -- <git argv...>

  `--sync-exclude` is repeatable. The names given are APPENDED to the emitter's
  own default exclusions (`.git`, `.commonplace`, ...) — an operator cannot drop
  that protection, only add to it. At least one scope declaration is required;
  `--declare-empty-sync-excludes` explicitly selects defaults-only scope.
  """

  alias Commonplace.Crypto.SigningContext
  alias Commonplace.Store.SecretStore

  @switches [
    repo: :string,
    state_dir: :string,
    event_log: :string,
    real_git: :string,
    trace: :string,
    sync_exclude: :keep,
    declare_empty_sync_excludes: :boolean
  ]

  # Mirrors `@sync_excludes` in `Commonplace.ProtoChit`. Operator-supplied names
  # are appended to this set, never substituted for it, so no invocation can
  # sync `.git` or `.commonplace` into the substrate by accident.
  @default_sync_excludes [".git", ".commonplace", "_build", "deps"]

  def run(data_dir, _relative_path, ["emit" | args]) do
    with :ok <- Commonplace.CLI.ensure_started(data_dir),
         {opts, git_args, []} <- OptionParser.parse(args, strict: @switches),
         {:ok, repo} <- required(opts, :repo),
         {:ok, state_dir} <- required(opts, :state_dir),
         {:ok, event_log_uuid} <- required(opts, :event_log),
         {:ok, root_uuid} <- root_uuid(data_dir),
         {:ok, signing_context} <- signing_context(),
         {:ok, result} <-
           Commonplace.ProtoChit.emit(
             repo,
             git_args,
             emit_opts(opts, root_uuid, event_log_uuid, state_dir, signing_context)
           ) do
      IO.puts(:stderr, "proto-chit: tap fired #{result.event_ref}")
      0
    else
      {_opts, _args, invalid} -> fail({:invalid_options, invalid})
      {:error, reason} -> fail(reason)
      other -> fail(other)
    end
  end

  def run(_data_dir, _relative_path, _args) do
    IO.puts(:stderr, @moduledoc)
    1
  end

  defp root_uuid(data_dir) do
    case Commonplace.CLI.root_uuid(data_dir) do
      nil -> {:error, :workspace_has_no_root}
      root -> {:ok, root}
    end
  end

  defp sync_excludes(opts) do
    extra =
      opts
      |> Keyword.get_values(:sync_exclude)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    Enum.uniq(@default_sync_excludes ++ extra)
  end

  defp emit_opts(opts, root_uuid, event_log_uuid, state_dir, signing_context) do
    emit_opts = [
      root_uuid: root_uuid,
      event_log_uuid: event_log_uuid,
      state_dir: state_dir,
      real_git: Keyword.get(opts, :real_git, "/usr/bin/git"),
      trace_file: opts[:trace],
      signing_context: signing_context
    ]

    if sync_scope_declared?(opts) do
      Keyword.put(emit_opts, :sync_excludes, sync_excludes(opts))
    else
      emit_opts
    end
  end

  defp sync_scope_declared?(opts) do
    Keyword.has_key?(opts, :sync_exclude) or
      Keyword.get(opts, :declare_empty_sync_excludes, false)
  end

  defp required(opts, key) do
    case Keyword.get(opts, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing_option, key}}
    end
  end

  defp signing_context do
    with {:ok, encoded_private_key} <- SecretStore.get("signing_key:default"),
         {:ok, private_key} <- Base.decode64(encoded_private_key),
         {:ok, encoded_public_key} <- SecretStore.get("signing_pub:default"),
         {:ok, public_key} <- Base.decode64(encoded_public_key),
         {:ok, identity_uuid} <- SecretStore.get("signing_identity") do
      {:ok,
       %SigningContext{
         identity_uuid: identity_uuid,
         private_key: private_key,
         public_key: public_key
       }}
    else
      _ -> {:error, :no_signing_context}
    end
  end

  defp fail(reason) do
    IO.puts(:stderr, "proto-chit: emission failed: #{inspect(reason)}")
    1
  end
end
