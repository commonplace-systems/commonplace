defmodule Commonplace.MUD.SessionViewRegistry do
  @moduledoc """
  CX-i9j3 (UI Inc-1 increment 4): serve-side, IN-MEMORY pointer from a
  player's stable `identity_uuid` to the uuid of their `SessionView`
  view-doc, so a browser reconnect (LiveView remount on the same
  identity) can `Commonplace.MUD.SessionView.load/2` the SAME view-doc
  instead of `SessionView.new/3` minting a fresh, empty one.

  ## Scope: reconnect-durable, NOT restart-durable

  This is a plain supervised `Agent` holding a `%{identity_uuid =>
  view_uuid}` map in process memory. It survives any number of
  LiveView reconnects/remounts for the life of the serve BEAM, but a
  serve restart (deploy, crash, `commonplace serve` bounce) drops the
  map entirely — the NEXT mount after a restart falls back to
  `SessionView.new/3` (a fresh transcript), same as increment 3's
  behavior. Making the identity->view_uuid pointer itself tree-durable
  (e.g. stashed under the player's home room, or a small committed doc)
  is a LATER increment; this one only covers the everyday case (a
  browser tab loses its websocket and reconnects) without requiring
  any new committed state.

  ## API

    - `get/1` — `identity_uuid -> view_uuid | nil`.
    - `put/2` — record `identity_uuid -> view_uuid` (last write wins;
      a player only ever has one live view_uuid at a time under normal
      use).
  """

  use Agent

  @doc "Start the registry, empty. Named `__MODULE__` — one per node."
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  @doc "Look up the remembered view_uuid for `identity_uuid`, or `nil` if none."
  @spec get(String.t()) :: String.t() | nil
  def get(identity_uuid) when is_binary(identity_uuid) do
    Agent.get(__MODULE__, &Map.get(&1, identity_uuid))
  end

  @doc "Remember `view_uuid` as the current view for `identity_uuid`."
  @spec put(String.t(), String.t()) :: :ok
  def put(identity_uuid, view_uuid) when is_binary(identity_uuid) and is_binary(view_uuid) do
    Agent.update(__MODULE__, &Map.put(&1, identity_uuid, view_uuid))
  end
end
