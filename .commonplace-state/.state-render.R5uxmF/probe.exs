[output_path, serve_node_string] = System.argv() |> Enum.reject(&(&1 == "--"))
serve_node = String.to_atom(serve_node_string)
:application.set_env(:kernel, :prevent_overlapping_partitions, false)
:application.set_env(:kernel, :inet_dist_use_interface, {127, 0, 0, 1})
probe = :"state_render_probe_#{:erlang.unique_integer([:positive])}@#{System.get_env("STATE_RENDER_HOST", "commonplace")}"
fail = fn message -> IO.puts(:stderr, "state-render: serve read failed — #{message}"); System.halt(2) end
read = fn module, function, arguments, timeout ->
  try do
    :erpc.call(serve_node, module, function, arguments, timeout)
  catch
    kind, reason -> fail.("#{inspect(module)}.#{function}/#{length(arguments)} #{kind}: #{inspect(reason)}")
  end
end
case Node.start(probe, :shortnames) do
  {:ok, _} -> :ok
  {:error, reason} -> fail.("could not start probe: #{inspect(reason)}")
end
unless Node.connect(serve_node), do: fail.("Node.connect returned false (pang)")
root = case read.(Commonplace.Workspace, :root_uuid, [], 15_000) do
  {:ok, value} -> value
  other -> fail.("root_uuid returned #{inspect(other)}")
end
client = Commonplace.Store.CommitStoreClient
ready = read.(Commonplace.Bd.CLI, :ready, [root, client], 120_000)
blocked = read.(Commonplace.Bd.CLI, :blocked, [root, client], 120_000)
issues = read.(Commonplace.Bd.Issue, :list, [root, client], 120_000) |> Enum.map(fn {issue, _} -> issue end)
header = %{kind: "state-render-input", as_of: DateTime.utc_now() |> DateTime.to_iso8601(), ready_ids: Enum.map(ready, & &1.id), blocked_ids: Enum.map(blocked, & &1.id)}
rows = Enum.map(issues, fn issue ->
  description = case read.(Commonplace.Bd.Issue, :description, [root, issue.id, client], 30_000) do {:ok, value} -> value; _ -> "" end
  comments = read.(Commonplace.Bd.Comment, :list, [root, issue.id, client], 30_000)
  issue |> Map.from_struct() |> Map.put(:description, description) |> Map.put(:comments, Enum.map(comments, &Map.from_struct/1))
end)
bytes = Enum.map_join([header | rows], "\n", &Jason.encode!/1) <> "\n"
File.write!(output_path, bytes)
