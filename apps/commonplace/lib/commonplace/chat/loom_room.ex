defmodule Commonplace.Chat.LoomRoom do
  @moduledoc """
  CX-6sf2.1 (A1): the well-known `loom` chat room — the substrate side
  of "agents reach #loom via MCP tools, the room IS the channel".

  `#loom` (IRC-style) normalizes to the path-safe name `"loom"` — this
  is the ONE deviation from the bare channel name; `Rooms.validate_name/1`
  would actually accept a literal `"#loom"` (it only rejects empty
  names, a leading `.`/`_`, and embedded `/`), but `#` reads oddly as a
  Yjs path-doc entry name and every other room in the tree is a bare
  identifier (`general`, etc.) — `loom` keeps that convention. The IRC
  mirror (A2, not this bead) is expected to map `#loom` <-> `loom` at
  its edge.

  ## Lazy ensure, not boot-time creation

  `ensure/2` is called lazily on first `loom_send` / `loom_read` (CX-6sf2.1
  MCP tools), NOT eagerly at application boot. Reasons:

    * No new boot dependency — `Commonplace.Workspace.root_uuid/0` isn't
      guaranteed to resolve at boot in every deployment shape (CLI /
      tests start component supervisors before a workspace root file
      necessarily exists); a boot-time `ensure/2` would need its own
      retry/supervision story for a room that may go unused all
      session.
    * `Rooms.create/3` already does its own lazy idempotent
      bootstrapping (`TemplateBootstrap.ensure_template/2` runs inline
      on every `create/3` call) — this module's `ensure/2` is the same
      pattern one level up, so it fits the existing idiom rather than
      inventing a second (boot-supervisor-child) bootstrap mechanism.
    * Every other MCP tool in this app (`mud_send`, `presence_info`)
      already lazily spawns/ensures its backing resource on first call
      rather than at boot — consistent with that precedent.

  This module owns ONLY the "does the well-known room exist" concern.
  Per-message actions still go through `Commonplace.Chat.Actions`; raw
  message data shape through `Commonplace.Chat.Messages`. No second
  chat model — `ensure/2` is a thin lookup-or-create wrapper over
  `Commonplace.Chat.Rooms`.
  """

  alias Commonplace.Chat.Rooms

  @room_name "loom"

  @doc "The path-safe room name `#loom` normalizes to."
  def room_name, do: @room_name

  @doc """
  Idempotently ensure the `loom` room exists under `/chat/loom/` and
  return its sub-doc UUIDs (same shape as `Rooms.lookup/3` /
  `Rooms.create/3`).

  Looks up first; creates only on a `:not_found` miss. Tolerates a
  create-time `:exists` race (two callers ensuring concurrently) by
  falling back to a second lookup rather than erroring.
  """
  def ensure(root_uuid, opts \\ []) when is_binary(root_uuid) and is_list(opts) do
    case Rooms.lookup(root_uuid, @room_name, opts) do
      {:ok, room} ->
        {:ok, room}

      {:error, :not_found} ->
        case Rooms.create(root_uuid, @room_name, opts) do
          {:ok, room} -> {:ok, room}
          {:error, :exists} -> Rooms.lookup(root_uuid, @room_name, opts)
          other -> other
        end

      other ->
        other
    end
  end
end
