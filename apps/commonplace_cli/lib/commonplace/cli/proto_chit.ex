defmodule Commonplace.CLI.ProtoChit do
  @moduledoc """
  Internal command used by the worktree-local proto-chit git shim.

  Usage:
    commonplace proto-chit emit --repo DIR --state-dir DIR --event-log UUID
      [--real-git PATH] [--trace FILE]
      [--sync-exclude NAME]... [--declare-empty-sync-excludes] -- <git argv...>
    commonplace proto-chit annotate --repo DIR --event-log UUID
      --main-event-ref HEX --exit-status INTEGER [--real-git PATH] [--trace FILE]
      -- <git argv...>
    commonplace proto-chit log --event-log UUID [--limit N] [--json]
      Read-only chain walk, newest-first: event + pin + signer per entry.
      "signature present" is a presence rendering, never a verification.

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
    declare_empty_sync_excludes: :boolean,
    main_event_ref: :string,
    exit_status: :integer
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

  def run(data_dir, _relative_path, ["annotate" | args]) do
    with :ok <- Commonplace.CLI.ensure_started(data_dir),
         {opts, git_args, []} <- OptionParser.parse(args, strict: @switches),
         {:ok, repo} <- required(opts, :repo),
         {:ok, event_log_uuid} <- required(opts, :event_log),
         {:ok, main_event_ref} <- required(opts, :main_event_ref),
         {:ok, exit_status} <- required_non_negative_integer(opts, :exit_status),
         {:ok, signing_context} <- signing_context(),
         {:ok, result} <-
           Commonplace.ProtoChit.annotate(repo, main_event_ref, exit_status, git_args,
             event_log_uuid: event_log_uuid,
             real_git: Keyword.get(opts, :real_git, "/usr/bin/git"),
             trace_file: opts[:trace],
             signing_context: signing_context
           ) do
      IO.puts(:stderr, "proto-chit: tap fired #{result.event_ref}")
      0
    else
      {_opts, _args, invalid} -> fail({:invalid_options, invalid})
      {:error, reason} -> fail(reason)
      other -> fail(other)
    end
  end

  # A2 read surface: walk the punctuation chain newest-first and render
  # event + pin + signer. Read-only: no signing context is acquired and no
  # write path is touched. "signed" in the output is a PRESENCE rendering
  # of the enclosing commit's signature, not a verification — chain
  # verification belongs to the import gate and the harvest ingester.
  def run(data_dir, _relative_path, ["log" | args]) do
    with :ok <- Commonplace.CLI.ensure_started(data_dir),
         {opts, [], []} <-
           OptionParser.parse(args, strict: @switches ++ [limit: :integer, json: :boolean]),
         {:ok, event_log_uuid} <- required(opts, :event_log),
         {:ok, entries} <-
           Commonplace.ProtoChit.chain(event_log_uuid, limit: Keyword.get(opts, :limit, 20)) do
      render_chain(entries, Keyword.get(opts, :json, false))
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

  defp render_chain(entries, true) do
    IO.puts(Jason.encode!(entries))
  end

  defp render_chain(entries, false) do
    Enum.each(entries, fn entry ->
      event = entry.event

      IO.puts(
        "#{short(entry.event_ref)}  #{event["verb"]}  by #{event["author-principal"]}  #{signed_label(entry.signer)}"
      )

      IO.puts("    message: #{event["message"]}")
      IO.puts("    pin: #{render_pin(event["proto-pin"])}")
      IO.puts("    predecessors: #{render_predecessor(event["predecessor-ref"])}")
      IO.puts("    git-sha: #{event["git-sha"] || "null"}")

      Enum.each(entry.annotations, fn annotation ->
        a = annotation.event

        IO.puts(
          "    post-exec: exit #{a["exit-status"]}, sha #{a["resulting-git-sha"] || "null"}  #{signed_label(annotation.signer)}"
        )
      end)
    end)
  end

  defp signed_label(%{signed: true}), do: "[signature present]"
  defp signed_label(_), do: "[UNSIGNED]"

  defp render_pin(nil), do: "none"

  defp render_pin(%{"checkpoint" => %{"doc" => doc, "commit" => commit}} = pin) do
    entries = map_size(pin["entries"] || %{})
    exclusions = length(pin["exclusions"] || [])

    base = "checkpoint #{short(doc)}@#{short(commit)} (#{entries} entries"
    if exclusions > 0, do: base <> ", #{exclusions} exclusions)", else: base <> ")"
  end

  defp render_pin(_other), do: "unrecognized pin shape"

  defp render_predecessor(%{"branch" => branch, "event-refs" => refs} = predecessor) do
    unresolved = predecessor["unresolved"] || []
    shorts = refs |> Enum.map(&short/1) |> Enum.join(", ")
    base = "[#{shorts}] (branch #{branch})"
    if unresolved == [], do: base, else: base <> " unresolved: #{Enum.join(unresolved, ", ")}"
  end

  defp render_predecessor(_other), do: "unrecognized predecessor shape"

  defp short(hex) when is_binary(hex) and byte_size(hex) >= 12, do: binary_part(hex, 0, 12)
  defp short(other) when is_binary(other), do: other
  defp short(_), do: "?"

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

  defp required_non_negative_integer(opts, key) do
    case Keyword.get(opts, key) do
      value when is_integer(value) and value >= 0 -> {:ok, value}
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
