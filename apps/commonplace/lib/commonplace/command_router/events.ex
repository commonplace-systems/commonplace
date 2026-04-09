defmodule Commonplace.CommandRouter.Events do
  @moduledoc """
  Pure lifecycle wrapper for command-router verbs.

  `run/3` broadcasts `command.initiated` on the `__commands` magenta topic,
  runs the body, and then broadcasts `command.completed` or `command.failed`
  depending on the outcome. It catches raised exceptions / exits / throws
  from the body so a buggy verb can't take down the router.

  ## Body return shapes

    * `{:ok, reply_value}`                   — success. `reply_value` is both
                                                returned to the caller and
                                                recorded in the audit event.

    * `{:ok, reply_value, audit_payload}`    — success with a separate audit
                                                view. `reply_value` is returned
                                                to the caller; `audit_payload`
                                                is what goes into the
                                                `result` field of the
                                                `command.completed` event.

    * `{:error, reason}`                     — failure. `reason` is returned
                                                to the caller and stringified
                                                into the `command.failed`
                                                event's `reason` field.

  A raised exception / exit / thrown value is converted to an error tuple
  automatically.
  """

  alias Commonplace.Dataflow.Magenta

  @command_topic "__commands"

  @type verb :: String.t()
  @type args :: map()
  @type reply_value :: any()
  @type audit_payload :: any()
  @type body_result ::
          {:ok, reply_value()}
          | {:ok, reply_value(), audit_payload()}
          | {:error, any()}

  @spec run(verb(), args(), (-> body_result())) :: {:ok, reply_value()} | {:error, any()}
  def run(verb, args, body) when is_binary(verb) and is_map(args) and is_function(body, 0) do
    command_id = UUID.uuid4()
    start_ms = System.monotonic_time(:millisecond)

    broadcast("command.initiated", %{
      "verb" => verb,
      "args" => args,
      "command_id" => command_id
    })

    case safely(body) do
      {:ok, reply_value, audit_payload} ->
        broadcast_completed(verb, args, command_id, audit_payload, start_ms)
        {:ok, reply_value}

      {:ok, reply_value} ->
        broadcast_completed(verb, args, command_id, reply_value, start_ms)
        {:ok, reply_value}

      {:error, reason} ->
        broadcast_failed(verb, args, command_id, reason, start_ms)
        {:error, reason}
    end
  end

  # Run the body, catching any unexpected crashes and converting them to
  # {:error, reason} tuples. Pass-through for normal {:ok, ...} / {:error, ...}
  # returns.
  defp safely(body) do
    try do
      case body.() do
        {:ok, _} = ok -> ok
        {:ok, _, _} = ok -> ok
        {:error, _} = err -> err
        other -> {:error, "unexpected body return: #{inspect(other)}"}
      end
    rescue
      e -> {:error, Exception.message(e)}
    catch
      :exit, reason -> {:error, "exit: #{inspect(reason)}"}
      :throw, thrown -> {:error, "throw: #{inspect(thrown)}"}
    end
  end

  defp broadcast_completed(verb, args, command_id, result, start_ms) do
    broadcast("command.completed", %{
      "verb" => verb,
      "args" => args,
      "command_id" => command_id,
      "result" => result,
      "duration_ms" => System.monotonic_time(:millisecond) - start_ms
    })
  end

  defp broadcast_failed(verb, args, command_id, reason, start_ms) do
    broadcast("command.failed", %{
      "verb" => verb,
      "args" => args,
      "command_id" => command_id,
      "reason" => stringify_reason(reason),
      "duration_ms" => System.monotonic_time(:millisecond) - start_ms
    })
  end

  defp broadcast(type, payload) do
    msg = Magenta.message(type, "command-router", payload)
    Magenta.send(@command_topic, msg)
  end

  defp stringify_reason(reason) when is_binary(reason), do: reason
  defp stringify_reason(reason), do: inspect(reason)
end
