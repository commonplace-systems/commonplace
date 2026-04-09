defmodule CommonplaceWebWeb.ViewActions do
  @moduledoc """
  Thin LiveView adapter over `Commonplace.ViewActionDispatch`.

  The core dispatcher lives in the `commonplace` app (no Phoenix
  deps) so both the wiki LiveView and the MCP meta-tool
  (`Commonplace.MCP.Tools.InvokeViewAction`) can share the same
  action-name pattern match + audit broadcast.

  This module translates dispatcher result intents into Phoenix
  LiveView socket mutations:

  * `{:ok, :ui_transition, %{action: "edit"}}` → `assign(socket, :mode, :edit)`
  * `{:ok, :ui_transition, %{action: "history"}}` → toggle `show_history`
  * `{:ok, :tree_mutation, %{action: "fork", short_uuid: short}}` →
    `put_flash(socket, :info, ...)`
  * `{:error, reason}` → propagated as-is for the caller to flash.
  """

  alias Commonplace.ViewActionDispatch

  import Phoenix.LiveView, only: [put_flash: 3]
  import Phoenix.Component, only: [assign: 3]

  @type context :: ViewActionDispatch.context()

  @doc """
  Dispatch a view action and translate the result into socket
  mutations. See `Commonplace.ViewActionDispatch` for the context
  map shape.
  """
  @spec dispatch(String.t(), context(), Phoenix.LiveView.Socket.t()) ::
          {:ok, Phoenix.LiveView.Socket.t()} | {:error, String.t()}
  def dispatch(action_name, %{} = context, socket) when is_binary(action_name) do
    case ViewActionDispatch.dispatch(action_name, context) do
      {:ok, :ui_transition, %{action: "edit"}} ->
        {:ok, assign(socket, :mode, :edit)}

      {:ok, :ui_transition, %{action: "history"}} ->
        current = socket.assigns[:show_history] || false
        {:ok, assign(socket, :show_history, not current)}

      {:ok, :tree_mutation, %{action: "fork", short_uuid: short}} ->
        socket =
          put_flash(
            socket,
            :info,
            "Forked view to new UUID #{short} (not yet attached to tree — phase 2b)"
          )

        {:ok, socket}

      {:ok, _class, _details} ->
        # Forward-compat: if the dispatcher grows a new result shape the
        # wiki LiveView doesn't know about yet, surface a neutral
        # acknowledgement rather than crashing.
        {:ok, put_flash(socket, :info, "Action '#{action_name}' completed")}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def dispatch(_other, _context, _socket) do
    {:error, "invalid action name"}
  end

  @doc false
  @deprecated "Use Commonplace.ViewActionDispatch.broadcast_audit/2 instead"
  def broadcast_audit(action_name, context) do
    ViewActionDispatch.broadcast_audit(action_name, context)
  end
end
