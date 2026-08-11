defmodule Commonplace.CLI.Bd do
  @moduledoc """
  Beads-on-Commonplace CLI: `commonplace bd <subcommand>`.

  A beads-style issue tracker implemented *on the commonplace substrate*:
  issues, deps, labels, and comments are stored as CRDT documents in the
  workspace tree (under a `bd` dir, lazily created via
  `Commonplace.Bd.Workspace.ensure_bd_dir/2`), so they sync, branch, and
  merge like any other doc — that is what distinguishes it from the
  external `bd` tool whose surface it mirrors. This module is only the
  CLI frontend; each subcommand dispatches to the `Commonplace.Bd.*`
  modules (`Issue`, `Dep`, `Label`, `Comment`, `Ready`, `Importer`).

  Spec: /home/jes/commonplace-plan/docs/beads-on-commonplace.md §9.3.

  P1 subcommands: create, show, update, close, list, ready, blocked,
  comment, dep, label, import. Mirrors the `bd` CLI shape so muscle
  memory transfers.
  """

  alias Commonplace.Bd.{Comment, Dep, Importer, Issue, Label, Ready, Workspace}
  alias Commonplace.Bd.CLI, as: BdQuery
  alias Commonplace.Bd.RetiredGraphError
  alias Commonplace.CLI
  alias Commonplace.Crypto.NodeIdentity
  alias Commonplace.Store.CommitStoreClient

  def run(data_dir, _relative_path, args) do
    CLI.ensure_started(data_dir)
    root = CLI.root_uuid(data_dir)

    if is_nil(root) do
      IO.puts(:stderr, "No root UUID — run 'commonplace init' first.")
      System.halt(1)
    end

    _ = Workspace.ensure_bd_dir(root, CommitStoreClient)

    result =
      case args do
        ["create" | rest] ->
          cmd_create(root, rest)

        ["show", id] ->
          cmd_show(root, id)

        ["update", id | rest] ->
          cmd_update(root, id, rest)

        ["close", id | rest] ->
          cmd_close(root, id, rest)

        ["list" | rest] ->
          cmd_list(root, rest)

        ["ready"] ->
          cmd_ready(root)

        ["blocked"] ->
          cmd_blocked(root)

        ["comment", "add", id | rest] ->
          cmd_comment_add(root, id, rest)

        ["comment", "list", id] ->
          cmd_comment_list(root, id)

        ["comment", "edit", id, comment_id | rest] ->
          cmd_comment_edit(root, id, comment_id, rest)

        ["comment", "delete", id, comment_id] ->
          cmd_comment_delete(root, id, comment_id)

        ["dep", "add", from, to | rest] ->
          cmd_dep_add(root, from, to, rest)

        ["dep", "remove", from, to | rest] ->
          cmd_dep_remove(root, from, to, rest)

        ["dep", "list"] ->
          cmd_dep_list(root)

        ["label", "create", name | rest] ->
          cmd_label_create(root, name, rest)

        ["label", "list"] ->
          cmd_label_list(root)

        ["label", "assign", id, name] ->
          cmd_label_assign(root, id, name)

        ["label", "unassign", id, name] ->
          cmd_label_unassign(root, id, name)

        ["import", "issues", path] ->
          cmd_import_issues(root, path)

        ["import", "deps", path] ->
          cmd_import_deps(root, path)

        _ ->
          IO.puts(:stderr, usage())
          System.halt(1)
      end

    # A retired verb printed its notice; the exit code has to agree
    # with it, or a script keeps treating the call as a success.
    if result == :retired, do: System.halt(1)
    result
  end

  ## Subcommand handlers

  defp cmd_create(root, rest) do
    {opts, args, _} =
      OptionParser.parse(rest,
        strict: [
          title: :string,
          description: :string,
          status: :string,
          priority: :string,
          type: :string,
          owner: :string
        ]
      )

    title =
      cond do
        opts[:title] -> opts[:title]
        args != [] -> Enum.join(args, " ")
        true -> ""
      end

    if title == "" do
      IO.puts(:stderr, "Title required: pass --title or as positional arg.")
      System.halt(1)
    end

    attrs = %{title: title}

    attrs =
      if opts[:description], do: Map.put(attrs, :description, opts[:description]), else: attrs

    attrs = if opts[:status], do: Map.put(attrs, :status, opts[:status]), else: attrs
    attrs = if opts[:priority], do: Map.put(attrs, :priority, opts[:priority]), else: attrs
    attrs = if opts[:type], do: Map.put(attrs, :type, opts[:type]), else: attrs
    attrs = if opts[:owner], do: Map.put(attrs, :owner, opts[:owner]), else: attrs

    case Issue.create(root, attrs) do
      {:ok, issue, _dir} -> IO.puts("Created #{issue.id}: #{issue.title}")
      {:error, reason} -> error_exit("Create failed", reason)
    end
  end

  defp cmd_show(root, id) do
    case Issue.show(root, id) do
      {:ok, issue} ->
        IO.puts("#{issue.id}: #{issue.title}")
        IO.puts("  status:   #{issue.status}")
        IO.puts("  priority: #{issue.priority}")
        IO.puts("  type:     #{issue.type}")
        if issue.owner, do: IO.puts("  owner:    #{issue.owner}")
        if issue.labels != [], do: IO.puts("  labels:   #{Enum.join(issue.labels, ", ")}")

        case Issue.description(root, id) do
          {:ok, body} when body != "" -> IO.puts("\n#{body}")
          _ -> :ok
        end

      {:error, :not_found} ->
        IO.puts(:stderr, "Issue not found: #{id}")
        System.halt(1)
    end
  end

  defp cmd_update(root, id, rest) do
    {opts, _, _} =
      OptionParser.parse(rest,
        strict: [
          title: :string,
          status: :string,
          reason: :string,
          priority: :string,
          type: :string,
          owner: :string
        ]
      )

    attrs = opts |> Keyword.drop([:reason]) |> Enum.into(%{})

    if attrs == %{} do
      IO.puts(:stderr, "No update flags provided.")
      System.halt(1)
    end

    with {:ok, signing_context} <- status_signing_context(attrs),
         {:ok, issue} <- update_ticket(root, id, attrs, opts[:reason], signing_context) do
      IO.puts("Updated #{issue.id}")
    else
      {:error, reason} -> error_exit("Update failed", reason)
    end
  end

  defp status_signing_context(%{status: _status}), do: NodeIdentity.signing_context()
  defp status_signing_context(_attrs), do: {:ok, nil}

  @doc """
  Applies the legacy `bd update` field bag. If it includes `:status`,
  that field is removed from the generic update and routed through
  `ticket_set_status`; there is no permissive CLI-only status door.

  Public for the CLI single-door regression test. Production callers
  resolve the node signing context in `cmd_update/3`; tests inject a
  fixture context and store.
  """
  def update_ticket(root, id, attrs, reason, signing_context, store \\ CommitStoreClient)
      when is_map(attrs) do
    {status, ordinary_attrs} = Map.pop(attrs, :status)

    with :ok <- maybe_set_status(root, id, status, reason, signing_context, store),
         {:ok, issue} <- maybe_update_ordinary_fields(root, id, ordinary_attrs, store) do
      {:ok, issue}
    end
  end

  defp maybe_set_status(_root, _id, nil, _reason, _signing_context, _store), do: :ok

  defp maybe_set_status(root, id, status, reason, signing_context, store) do
    case BdQuery.set_status(root, id, status, reason, signing_context, store) do
      {:ok, _status} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_update_ordinary_fields(root, id, attrs, store) when map_size(attrs) == 0,
    do: Issue.show(root, id, store)

  defp maybe_update_ordinary_fields(root, id, attrs, store) do
    case Issue.update(root, id, attrs, store) do
      {:ok, issue} -> {:ok, issue}
      {:error, reason} -> {:error, reason}
    end
  end

  defp cmd_close(root, id, rest) do
    {opts, _, _} = OptionParser.parse(rest, strict: [reason: :string])

    case Issue.close(root, id, reason: opts[:reason]) do
      {:ok, _} -> IO.puts("Closed #{id}")
      {:error, reason} -> error_exit("Close failed", reason)
    end
  end

  defp cmd_list(root, rest) do
    {opts, _, _} =
      OptionParser.parse(rest,
        strict: [status: :string, priority: :string, label: :string, owner: :string]
      )

    Ready.list_all(root)
    |> filter_issues(opts)
    |> render_issue_list()
  end

  @doc """
  `bd ready` — serves the LIVE `needs` graph (CX-hrbn).

  Was `Commonplace.Bd.Ready.ready/2`, a walk over the `blocks` edges in
  `/bd/deps.json`. Nothing has written that graph since the
  tix-authority cutover on 2026-08-05, so it now answers from the same
  Frontier-backed path as `Commonplace.Bd.CLI.ready/2` — one
  implementation, not a second copy of the walk.

  Two visible consequences, both intended:

    * The rows are the Frontier display shape (`○ id  pri  type
      title`, priority-sorted), not the old issue-list line.
    * The semantics differ. A ticket whose prerequisite cannot be
      resolved is BLOCKED here; the old `blocks` walk called it ready.
  """
  def cmd_ready(root, store \\ CommitStoreClient) do
    BdQuery.ready(root, store) |> render_rows()
  end

  @doc """
  `bd blocked` — the live-`needs` counterpart of `cmd_ready/2`. See its
  note on the shape and semantics change.
  """
  def cmd_blocked(root, store \\ CommitStoreClient) do
    BdQuery.blocked(root, store) |> render_rows()
  end

  defp cmd_comment_add(root, id, rest) do
    {opts, args, _} =
      OptionParser.parse(rest, strict: [body: :string, author: :string, reply_to: :string])

    body = opts[:body] || Enum.join(args, " ")

    if body == "" do
      IO.puts(:stderr, "Comment body required.")
      System.halt(1)
    end

    attrs =
      %{body: body, author: opts[:author]}
      |> maybe_put(:reply_to, opts[:reply_to])

    case Comment.add(root, id, attrs) do
      {:ok, comment} -> IO.puts("Added #{comment.id} to #{id}")
      {:error, reason} -> error_exit("Comment add failed", reason)
    end
  end

  defp cmd_comment_list(root, id) do
    Comment.list(root, id)
    |> Enum.each(fn c ->
      del = if c.deleted, do: " (deleted)", else: ""
      IO.puts("#{c.id}#{del} #{c.author || ""} #{c.created_at || ""}")
      IO.puts("  #{String.replace(c.body, "\n", "\n  ")}")
    end)
  end

  defp cmd_comment_edit(root, issue_id, comment_id, rest) do
    {opts, args, _} = OptionParser.parse(rest, strict: [body: :string])
    body = opts[:body] || Enum.join(args, " ")

    if body == "" do
      IO.puts(:stderr, "New body required.")
      System.halt(1)
    end

    case Comment.edit(root, issue_id, comment_id, body) do
      {:ok, _} -> IO.puts("Edited #{comment_id}")
      {:error, reason} -> error_exit("Comment edit failed", reason)
    end
  end

  defp cmd_comment_delete(root, issue_id, comment_id) do
    case Comment.soft_delete(root, issue_id, comment_id) do
      {:ok, _} -> IO.puts("Soft-deleted #{comment_id}")
      {:error, reason} -> error_exit("Comment delete failed", reason)
    end
  end

  # The three `bd dep` verbs all sat on `/bd/deps.json`, retired at the
  # 2026-08-05 cutover (CX-hrbn). They still call into `Dep` and let
  # the refusal come back out, rather than printing a copy of the
  # notice: one source of truth for the text, and the CLI's refusal
  # path is the library's refusal path, exercised end to end.

  @doc "`bd dep add` — RETIRED; surfaces the notice and exits 1."
  def cmd_dep_add(root, from, to, rest, store \\ CommitStoreClient) do
    {opts, _, _} = OptionParser.parse(rest, strict: [kind: :string])
    kind = opts[:kind] || "blocks"

    retired(fn -> Dep.add(root, from, to, kind, %{}, store) end)
  end

  @doc "`bd dep remove` — RETIRED; surfaces the notice and exits 1."
  def cmd_dep_remove(root, from, to, rest, store \\ CommitStoreClient) do
    {opts, _, _} = OptionParser.parse(rest, strict: [kind: :string])
    kind = opts[:kind] || "blocks"

    retired(fn -> Dep.remove(root, from, to, kind, store) end)
  end

  @doc "`bd dep list` — RETIRED; surfaces the notice and exits 1."
  def cmd_dep_list(root, store \\ CommitStoreClient) do
    retired(fn -> Dep.list(root, store) end)
  end

  defp cmd_label_create(root, name, rest) do
    {opts, _, _} = OptionParser.parse(rest, strict: [color: :string, description: :string])

    attrs =
      %{}
      |> maybe_put(:color, opts[:color])
      |> maybe_put(:description, opts[:description])

    case Label.create(root, name, attrs) do
      {:ok, label, _} -> IO.puts("Created label #{label.name}")
      err -> error_exit("Label create failed", err)
    end
  end

  defp cmd_label_list(root) do
    Label.list(root)
    |> Enum.each(fn l ->
      IO.puts("#{l.name}#{if l.color, do: " (#{l.color})", else: ""}: #{l.description}")
    end)
  end

  defp cmd_label_assign(root, id, name) do
    case Label.assign(root, id, name) do
      {:ok, _} -> IO.puts("Assigned #{name} to #{id}")
      err -> error_exit("Label assign failed", err)
    end
  end

  defp cmd_label_unassign(root, id, name) do
    case Label.unassign(root, id, name) do
      {:ok, _} -> IO.puts("Unassigned #{name} from #{id}")
      err -> error_exit("Label unassign failed", err)
    end
  end

  defp cmd_import_issues(root, path) do
    case File.read(path) do
      {:ok, text} ->
        case Importer.import_issues_jsonl(root, text) do
          {:ok, %{imported: i, updated: u, errors: errs}} ->
            IO.puts("Imported #{i}, updated #{u}, errors #{length(errs)}")

            Enum.each(errs, fn {idx, reason} ->
              IO.puts(:stderr, "  line #{idx}: #{inspect(reason)}")
            end)
        end

      {:error, reason} ->
        error_exit("Read failed: #{path}", reason)
    end
  end

  @doc "`bd import deps` — RETIRED; surfaces the notice and exits 1."
  def cmd_import_deps(root, path, store \\ CommitStoreClient) do
    case File.read(path) do
      {:ok, text} ->
        retired(fn -> Importer.import_deps_jsonl(root, text, store) end)

      {:error, reason} ->
        error_exit("Read failed: #{path}", reason)
    end
  end

  ## Helpers

  # Runs a call into a retired `/bd/deps.json` surface and turns its
  # raise into the user-facing notice. Returns `:retired` so `run/3`
  # exits non-zero — a retired verb must not look like it worked.
  defp retired(fun) do
    fun.()
    :ok
  rescue
    e in RetiredGraphError ->
      IO.puts(:stderr, Exception.message(e))
      :retired
  end

  defp render_rows([]), do: IO.puts("(no tickets)")
  defp render_rows(rows), do: IO.puts(BdQuery.render(rows))

  defp render_issue_list([]), do: IO.puts("(no issues)")

  defp render_issue_list(issues) do
    Enum.each(issues, fn i ->
      labels = if i.labels == [], do: "", else: " [#{Enum.join(i.labels, ", ")}]"
      IO.puts("#{i.id} #{i.priority} #{i.status} #{i.type}#{labels} — #{i.title}")
    end)
  end

  defp filter_issues(issues, opts) do
    Enum.filter(issues, fn i ->
      Enum.all?(opts, fn
        {:status, v} -> i.status == v
        {:priority, v} -> i.priority == v
        {:label, v} -> v in i.labels
        {:owner, v} -> i.owner == v
        _ -> true
      end)
    end)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, val), do: Map.put(map, key, val)

  defp error_exit(prefix, reason) do
    IO.puts(:stderr, "#{prefix}: #{inspect(reason)}")
    System.halt(1)
  end

  defp usage do
    """
    Usage: commonplace bd <subcommand>

    Issues:
      bd create [--title T] [--description D] [--priority p0..p3] [--type T] [--owner O]
      bd show <id>
      bd update <id> [--title T] [--status S --reason R] [--priority P] [--type T] [--owner O]
      bd close <id> [--reason R]
      bd list [--status S] [--priority P] [--label L] [--owner O]
      bd ready      tickets whose every prerequisite is satisfied
      bd blocked    open tickets with an unsatisfied prerequisite

      ready/blocked read the LIVE `needs` graph carried on each ticket.
      Before the 2026-08-05 tix cutover they walked `blocks` edges in
      /bd/deps.json, which nothing writes any more. The answers differ:
      a ticket needing something that cannot be resolved (missing, or
      in another repo) is BLOCKED now, where the old walk called it
      ready.

    Comments:
      bd comment add <id> [--body B] [--author A] [--reply-to C]
      bd comment list <id>
      bd comment edit <id> <comment_id> [--body B]
      bd comment delete <id> <comment_id>

    Dependencies (RETIRED — these exit 1 with a pointer):
      bd dep add <from> <to> [--kind K]
      bd dep remove <from> <to> [--kind K]
      bd dep list

      They edited /bd/deps.json, retired at the 2026-08-05 cutover.
      Prerequisites live on the ticket now, as `needs`.

    Labels:
      bd label create <name> [--color C] [--description D]
      bd label list
      bd label assign <id> <name>
      bd label unassign <id> <name>

    Import:
      bd import issues <path.jsonl>
      bd import deps <path.jsonl>   RETIRED — put the edges on the
                                    issue records as `needs` and use
                                    `bd import issues` instead.
    """
  end
end
