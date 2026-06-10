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
  alias Commonplace.CLI
  alias Commonplace.Store.CommitStoreClient

  def run(data_dir, _relative_path, args) do
    CLI.ensure_started(data_dir)
    root = CLI.root_uuid(data_dir)

    if is_nil(root) do
      IO.puts(:stderr, "No root UUID — run 'commonplace init' first.")
      System.halt(1)
    end

    _ = Workspace.ensure_bd_dir(root, CommitStoreClient)

    case args do
      ["create" | rest] -> cmd_create(root, rest)
      ["show", id] -> cmd_show(root, id)
      ["update", id | rest] -> cmd_update(root, id, rest)
      ["close", id | rest] -> cmd_close(root, id, rest)
      ["list" | rest] -> cmd_list(root, rest)
      ["ready"] -> cmd_ready(root)
      ["blocked"] -> cmd_blocked(root)
      ["comment", "add", id | rest] -> cmd_comment_add(root, id, rest)
      ["comment", "list", id] -> cmd_comment_list(root, id)
      ["comment", "edit", id, comment_id | rest] -> cmd_comment_edit(root, id, comment_id, rest)
      ["comment", "delete", id, comment_id] -> cmd_comment_delete(root, id, comment_id)
      ["dep", "add", from, to | rest] -> cmd_dep_add(root, from, to, rest)
      ["dep", "remove", from, to | rest] -> cmd_dep_remove(root, from, to, rest)
      ["dep", "list"] -> cmd_dep_list(root)
      ["label", "create", name | rest] -> cmd_label_create(root, name, rest)
      ["label", "list"] -> cmd_label_list(root)
      ["label", "assign", id, name] -> cmd_label_assign(root, id, name)
      ["label", "unassign", id, name] -> cmd_label_unassign(root, id, name)
      ["import", "issues", path] -> cmd_import_issues(root, path)
      ["import", "deps", path] -> cmd_import_deps(root, path)
      _ ->
        IO.puts(:stderr, usage())
        System.halt(1)
    end
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
    attrs = if opts[:description], do: Map.put(attrs, :description, opts[:description]), else: attrs
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
          priority: :string,
          type: :string,
          owner: :string
        ]
      )

    attrs = Enum.into(opts, %{})

    if attrs == %{} do
      IO.puts(:stderr, "No update flags provided.")
      System.halt(1)
    end

    case Issue.update(root, id, attrs) do
      {:ok, issue} -> IO.puts("Updated #{issue.id}")
      {:error, reason} -> error_exit("Update failed", reason)
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

  defp cmd_ready(root) do
    Ready.ready(root) |> render_issue_list()
  end

  defp cmd_blocked(root) do
    Ready.blocked(root) |> render_issue_list()
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

  defp cmd_dep_add(root, from, to, rest) do
    {opts, _, _} = OptionParser.parse(rest, strict: [kind: :string])
    kind = opts[:kind] || "blocks"

    case Dep.add(root, from, to, kind) do
      {:ok, _} -> IO.puts("Added edge #{from} -[#{kind}]-> #{to}")
      err -> error_exit("Dep add failed", err)
    end
  end

  defp cmd_dep_remove(root, from, to, rest) do
    {opts, _, _} = OptionParser.parse(rest, strict: [kind: :string])
    kind = opts[:kind] || "blocks"

    Dep.remove(root, from, to, kind)
    IO.puts("Removed edge #{from} -[#{kind}]-> #{to}")
  end

  defp cmd_dep_list(root) do
    Dep.list(root)
    |> Enum.each(fn e -> IO.puts("#{e.from} -[#{e.kind}]-> #{e.to}") end)
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
    |> Enum.each(fn l -> IO.puts("#{l.name}#{if l.color, do: " (#{l.color})", else: ""}: #{l.description}") end)
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
            Enum.each(errs, fn {idx, reason} -> IO.puts(:stderr, "  line #{idx}: #{inspect(reason)}") end)
        end

      {:error, reason} ->
        error_exit("Read failed: #{path}", reason)
    end
  end

  defp cmd_import_deps(root, path) do
    case File.read(path) do
      {:ok, text} ->
        {:ok, %{imported: n}} = Importer.import_deps_jsonl(root, text)
        IO.puts("Imported #{n} edges")

      {:error, reason} ->
        error_exit("Read failed: #{path}", reason)
    end
  end

  ## Helpers

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
      bd update <id> [--title T] [--status S] [--priority P] [--type T] [--owner O]
      bd close <id> [--reason R]
      bd list [--status S] [--priority P] [--label L] [--owner O]
      bd ready
      bd blocked

    Comments:
      bd comment add <id> [--body B] [--author A] [--reply-to C]
      bd comment list <id>
      bd comment edit <id> <comment_id> [--body B]
      bd comment delete <id> <comment_id>

    Dependencies:
      bd dep add <from> <to> [--kind K]
      bd dep remove <from> <to> [--kind K]
      bd dep list

    Labels:
      bd label create <name> [--color C] [--description D]
      bd label list
      bd label assign <id> <name>
      bd label unassign <id> <name>

    Import:
      bd import issues <path.jsonl>
      bd import deps <path.jsonl>
    """
  end
end
