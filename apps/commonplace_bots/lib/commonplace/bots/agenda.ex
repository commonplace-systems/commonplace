defmodule Commonplace.Bots.Agenda do
  @moduledoc """
  Camillo slice C3b/C3d — the per-bot **agenda** (the bot's "desk").

  A native-agent bot that wakes on a heartbeat (see
  `Commonplace.Bots.Dispatcher`'s autonomous-tick source) needs somewhere to
  keep the work it means to get to: pending consolidations, unfiled pins,
  candidate associations. That place is now `home/agenda/` — a ZONED NOTE-META
  dir UNDER the bot's home (C3d), the sibling of `home/memory/`.

  ## Why under the home (lands under enforce)

  The agenda was a `agenda.jsonl` in the entity dir — OUTSIDE the bot's cert
  scope, so an append was denied under `local_write_gate: :enforce`. As a zoned
  child of the home it inherits the home zone-stamp, so the bot's
  `{:subtree, home}[:write]` cert covers every append. The log is the `"entries"`
  array of the dir's `__note.json`; appends are a zone-preserving RMW push
  (`NoteDoc.append_entry` → `World.merge_meta`, never a struct round-trip —
  CX-cl65). Every write is signed by the bot's OWN key (the `ctx` creds).

  The desk axes stay apart:

    * `home/memory/` — what the bot has learned / wants to recall.
    * `home/agenda/` — what the bot still means to *do*.

  ## API (ctx-based)

  `ctx` is the bot's resolved MUD acting context (`Commonplace.Bots.MudContext`
  or the `Commonplace.Bots.Citizen` build ctx) — it carries `home_room_uuid`,
  `store`, and the bot's signing creds. A `nil` ctx (unprovisioned bot) reads
  empty and refuses appends gracefully — never a crash.

    * `ensure_dir/1` — the `home/agenda` note dir uuid (get-or-create).
    * `read/1`  — the pending items, oldest-first (`[]` if none / no ctx).
    * `append/2` — append one item (bot-signed), stamping `"ts"` if omitted.
  """

  alias Commonplace.Bots.NoteDoc

  @agenda_dir "agenda"
  @empty_entries ~s({"entries":[]})

  @doc "Get-or-create the bot's `home/agenda` note dir; `{:ok, uuid}` or error."
  @spec ensure_dir(map() | nil) :: {:ok, String.t()} | {:error, term()}
  def ensure_dir(%{home_room_uuid: home} = ctx) when is_binary(home) do
    NoteDoc.ensure_zoned_dir(home, @agenda_dir, @empty_entries, ctx)
  end

  def ensure_dir(_ctx), do: {:error, :no_mud_ctx}

  @doc "Read the pending agenda items — oldest-first. `[]` when none / no ctx."
  @spec read(map() | nil) :: [map()]
  def read(%{} = ctx) do
    case ensure_dir(ctx) do
      {:ok, uuid} -> NoteDoc.read_entries(uuid, ctx)
      _ -> []
    end
  end

  def read(_ctx), do: []

  @doc """
  Append one item (a free-form map) to the agenda, bot-signed.

  `"ts"` is stamped here if the caller omitted it. Ensures the dir exists first
  (get-or-create) so a first-ever append is safe.
  """
  @spec append(map(), map() | nil) :: :ok | {:error, term()}
  def append(item, %{} = ctx) when is_map(item) do
    item =
      Map.put_new_lazy(item, "ts", fn -> DateTime.utc_now() |> DateTime.to_iso8601() end)

    with {:ok, uuid} <- ensure_dir(ctx) do
      NoteDoc.append_entry(uuid, item, ctx)
    end
  end

  def append(_item, _ctx), do: {:error, :no_mud_ctx}
end
