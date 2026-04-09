defmodule CommonplaceWebWeb.ViewActions do
  @moduledoc """
  Dispatches view action invocations from the wiki LiveView.

  Per `docs/views.md` (Views Pass A, CX-vaw), view `<action>` elements
  render as `phx-click="view_action"` buttons. The wiki LiveView catches
  the event and forwards it here. Every invocation broadcasts a
  magenta audit event on the `view_actions` topic before handling, so
  the audit trail property of views is preserved even for UI-local
  actions that don't round-trip through CommandRouter.

  ## Action classes

  * **UI-local actions** (`edit`, `history`) — handled inline by
    mutating the socket assigns. Do not touch the commit store.
  * **Tree-mutating actions** (`fork`) — forwarded to
    `Commonplace.CommandRouter`, which owns tree mutations and emits
    its own command.initiated/completed magenta events.

  ## Audit context

  Every dispatch emits `{:magenta, "view_actions", %Magenta{}}` with
  payload `{view_path, action, target, args, signer_id, ts}`. The
  `signer_id` is a placeholder (`"wiki-user@local"`) in this pass —
  real identity propagation from LiveView sessions lands in a later
  pass alongside signed-commit wiring.

  ## Return shape

  * `{:ok, updated_socket}` on success — the socket may have flash
    messages, assign changes, or `push_patch` effects applied.
  * `{:error, reason}` on failure — the caller should `put_flash/3`
    the reason.
  """

  alias Commonplace.CommandRouter
  alias Commonplace.Dataflow.Magenta

  import Phoenix.LiveView, only: [put_flash: 3]
  import Phoenix.Component, only: [assign: 3]

  @type context :: %{
          view_path: String.t(),
          view_uuid: String.t() | nil,
          target: String.t() | nil,
          args: map(),
          signer_id: String.t()
        }

  @doc """
  Dispatch a view action by name. See module doc for context map shape
  and return values.
  """
  @spec dispatch(String.t(), context(), Phoenix.LiveView.Socket.t()) ::
          {:ok, Phoenix.LiveView.Socket.t()} | {:error, String.t()}
  def dispatch(action_name, %{} = context, socket) when is_binary(action_name) do
    broadcast_audit(action_name, context)

    case action_name do
      "edit" -> handle_edit(socket)
      "history" -> handle_history(socket)
      "fork" -> handle_fork(context, socket)
      other -> {:error, "unknown view action: #{other}"}
    end
  end

  def dispatch(_other, _context, _socket) do
    {:error, "invalid action name"}
  end

  # --- Audit broadcast ---

  @doc false
  def broadcast_audit(action_name, %{} = context) do
    payload = %{
      "view_path" => Map.get(context, :view_path),
      "view_uuid" => Map.get(context, :view_uuid),
      "action" => action_name,
      "target" => Map.get(context, :target),
      "args" => Map.get(context, :args, %{}),
      "signer_id" => Map.get(context, :signer_id)
    }

    msg = Magenta.message("view_action_invoked", "wiki_live", payload)
    Magenta.send("view_actions", msg)
  end

  # --- UI-local handlers ---

  defp handle_edit(socket) do
    if socket.assigns[:page_uuid] do
      {:ok, assign(socket, :mode, :edit)}
    else
      {:error, "cannot edit: no page loaded"}
    end
  end

  defp handle_history(socket) do
    current = socket.assigns[:show_history] || false
    {:ok, assign(socket, :show_history, not current)}
  end

  # --- Tree-mutating handlers ---

  defp handle_fork(%{view_uuid: uuid}, socket) when is_binary(uuid) do
    case CommandRouter.fork(uuid) do
      {:ok, new_uuid} when is_binary(new_uuid) ->
        short = String.slice(new_uuid, 0, 8)

        socket =
          put_flash(
            socket,
            :info,
            "Forked view to new UUID #{short} (not yet attached to tree — phase 2b)"
          )

        {:ok, socket}

      {:error, reason} ->
        {:error, "fork failed: #{inspect(reason)}"}
    end
  end

  defp handle_fork(_context, _socket) do
    {:error, "cannot fork: no view UUID in context"}
  end
end
