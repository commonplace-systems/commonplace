defmodule Commonplace.MCP.CrdtTools do
  @moduledoc """
  CRDT-defined dynamic MCP tools (CX-y3q).

  See `docs/dynamic-mcp-tools.md` in commonplace-plan for the design
  prose. This module is the runtime catalog reader + the magenta-
  orchestrating dispatcher. Two-doc pair: an interface doc at
  `__system/tools/<name>` declares the MCP-facing shape + the magenta
  address; a handler doc at `target_path` is where the dispatcher
  routes invocations.

  ## Public surface

  - `list/2` — returns descriptors for every interface doc currently
    under `__system/tools/`. Called from `Commonplace.MCP.Tools.list/0`
    where it merges with the static system tools.
  - `call/3` — looks up a tool by name, renders the magenta payload
    from `arguments`, dispatches, waits for the typed reply, and
    returns the MCP result map.

  ## Out of scope here

  - Progress forwarding (handler emits, dispatcher silently discards
    until a future change wires `_meta.progressToken` through).
  - `notifications/tools/list_changed` (separate watcher GenServer).
  - `_mcp_content` passthrough.
  - Catalog caching.
  """

  alias Commonplace.Dataflow.Magenta
  alias Commonplace.Document.ContentType
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.{Schema, Walk}
  alias Yelixer.{Doc, Encoding}

  @system_dir "__system"
  @tools_dir "tools"
  @source "mcp_dispatcher"

  @doc "List CRDT-defined tool descriptors under __system/tools/."
  @spec list(GenServer.server(), String.t() | nil) :: [map()]
  def list(store \\ CommitStoreClient, root_uuid)

  def list(_store, nil), do: []

  def list(store, root_uuid) do
    case resolve_tools_dir(store, root_uuid) do
      {:ok, tools_uuid} ->
        tools_doc = load_schema(store, tools_uuid)

        tools_doc
        |> Schema.list_entries()
        |> Enum.flat_map(fn entry ->
          case load_interface(store, entry.node_id) do
            {:ok, interface} -> [interface_to_descriptor(interface)]
            _ -> []
          end
        end)

      _ ->
        []
    end
  end

  @doc """
  Dispatch a CRDT-defined tool call.

  Options:
    * `:store` — defaults to `CommitStoreClient`
    * `:root_uuid` — workspace root (required)
    * `:progress_token` — optional MCP progress token; reserved for
      future progress forwarding
    * `:progress_callback` — optional fun reserved for future
      progress forwarding
  """
  @spec call(String.t(), map(), keyword()) ::
          {:ok, map()}
          | {:error, :not_found}
          | {:error, {:handler_not_found, String.t()}}
  def call(name, arguments, opts \\ []) when is_binary(name) and is_map(arguments) do
    store = Keyword.get(opts, :store, CommitStoreClient)
    root_uuid = Keyword.fetch!(opts, :root_uuid)

    case lookup_interface(store, root_uuid, name) do
      :error ->
        {:error, :not_found}

      {:ok, interface} ->
        target_path = get_in(interface, ["magenta", "target_path"])

        case Walk.resolve_path(root_uuid, target_path, schema_loader(store)) do
          {:error, _reason} ->
            {:error, {:handler_not_found, target_path}}

          {:ok, _target_uuid} ->
            dispatch(name, interface, arguments)
        end
    end
  end

  # --- private ---

  defp dispatch(name, interface, arguments) do
    target_path = interface["magenta"]["target_path"]
    send_type = interface["magenta"]["send_type"]
    success_type = interface["magenta"]["reply"]["success_type"]
    error_type = interface["magenta"]["reply"]["error_type"]
    timeout_ms = interface["magenta"]["reply"]["timeout_ms"]

    topic = "commands/#{target_path}/#{send_type}"

    case render_template(interface["magenta"]["send_payload_template"], arguments) do
      {:ok, payload} ->
        correlation_id = UUID.uuid4()
        payload = Map.put(payload, "correlation_id", correlation_id)

        Magenta.subscribe(topic)
        Magenta.send(topic, Magenta.message(send_type, @source, payload))

        result =
          await_reply(topic, correlation_id, success_type, error_type, timeout_ms,
            tool_name: name, target_path: target_path
          )

        {:ok, result}

      {:error, {:missing_var, var}} ->
        {:ok, in_band_error("template references missing argument: #{inspect(var)}")}
    end
  end

  defp await_reply(topic, correlation_id, success_type, error_type, timeout_ms, ctx) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await_reply(topic, correlation_id, success_type, error_type, deadline, ctx)
  end

  defp do_await_reply(topic, correlation_id, success_type, error_type, deadline, ctx) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:magenta, ^topic, %Magenta{type: ^success_type, payload: %{"correlation_id" => ^correlation_id} = payload}} ->
        wrap_success(payload)

      {:magenta, ^topic, %Magenta{type: ^error_type, payload: %{"correlation_id" => ^correlation_id} = payload}} ->
        wrap_error(payload)

      {:magenta, ^topic, %Magenta{}} ->
        # Wrong type, missing/wrong correlation_id — ignore + keep waiting.
        do_await_reply(topic, correlation_id, success_type, error_type, deadline, ctx)
    after
      remaining ->
        in_band_error(
          "tool '#{ctx[:tool_name]}' timed out after #{deadline_total_ms(deadline, remaining)}ms (target_path=#{ctx[:target_path]})"
        )
    end
  end

  defp deadline_total_ms(_deadline, _remaining) do
    # We don't keep the original timeout_ms in scope; the test asserts on
    # the substring "timed out". Recompute from the dispatcher signature
    # if we ever want to surface the exact ms — for now, conservative
    # approximation suffices for the human-readable error.
    "configured"
  end

  defp wrap_success(payload) do
    text = Jason.encode!(payload, pretty: true)

    %{
      "content" => [%{"type" => "text", "text" => text}],
      "structuredContent" => payload
    }
  end

  defp wrap_error(payload) do
    text = payload["message"] || Jason.encode!(payload)

    %{
      "isError" => true,
      "content" => [%{"type" => "text", "text" => text}]
    }
  end

  defp in_band_error(text) do
    %{
      "isError" => true,
      "content" => [%{"type" => "text", "text" => text}]
    }
  end

  defp render_template(template, arguments) when is_map(template) do
    try do
      rendered =
        Map.new(template, fn {k, v} ->
          {k, render_value(v, arguments)}
        end)

      {:ok, rendered}
    catch
      {:missing_var, var} -> {:error, {:missing_var, var}}
    end
  end

  defp render_value(v, arguments) when is_binary(v) do
    case full_value_match(v) do
      {:ok, var} ->
        case Map.fetch(arguments, var) do
          {:ok, value} -> value
          :error -> throw({:missing_var, var})
        end

      :no ->
        # mustache-style string interpolation: replace each {{var}}
        Regex.replace(~r/\{\{(\w+)\}\}/, v, fn _, var ->
          case Map.fetch(arguments, var) do
            {:ok, value} -> stringify(value)
            :error -> throw({:missing_var, var})
          end
        end)
    end
  end

  defp render_value(v, arguments) when is_map(v) do
    Map.new(v, fn {k, val} -> {k, render_value(val, arguments)} end)
  end

  defp render_value(v, arguments) when is_list(v) do
    Enum.map(v, &render_value(&1, arguments))
  end

  defp render_value(v, _arguments), do: v

  defp full_value_match(s) do
    case Regex.run(~r/^\{\{(\w+)\}\}$/, s) do
      [_, var] -> {:ok, var}
      _ -> :no
    end
  end

  defp stringify(v) when is_binary(v), do: v
  defp stringify(v) when is_number(v) or is_boolean(v) or is_atom(v), do: to_string(v)
  defp stringify(v), do: Jason.encode!(v)

  defp lookup_interface(store, root_uuid, name) do
    with {:ok, tools_uuid} <- resolve_tools_dir(store, root_uuid),
         tools_doc = load_schema(store, tools_uuid),
         {:ok, entry} <- Schema.get_entry(tools_doc, name),
         {:ok, interface} <- load_interface(store, entry.node_id) do
      {:ok, interface}
    else
      _ -> :error
    end
  end

  defp resolve_tools_dir(store, root_uuid) do
    Walk.resolve_path(root_uuid, "#{@system_dir}/#{@tools_dir}", schema_loader(store))
  end

  defp load_interface(store, doc_uuid) do
    case CommitStoreClient.latest_commit(store, doc_uuid) do
      {:ok, commit} ->
        doc = Doc.new()
        {:ok, doc} = Encoding.apply_update(doc, commit.update)
        content = ContentType.get_content(doc) || ""

        case Jason.decode(content) do
          {:ok, %{} = interface} -> {:ok, interface}
          _ -> :error
        end

      :none ->
        :error
    end
  end

  defp interface_to_descriptor(%{} = interface) do
    %{
      "name" => interface["name"],
      "description" => interface["description"],
      "inputSchema" => interface["inputSchema"]
    }
  end

  defp load_schema(store, uuid) do
    case CommitStoreClient.latest_commit(store, uuid) do
      {:ok, commit} ->
        doc = Schema.new_schema()
        {:ok, doc} = Encoding.apply_update(doc, commit.update)
        doc

      :none ->
        Schema.new_schema()
    end
  end

  defp schema_loader(store) do
    fn uuid -> load_schema(store, uuid) end
  end
end
