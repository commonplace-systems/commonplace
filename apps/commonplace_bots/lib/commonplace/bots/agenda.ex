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
      Entry-keyed DEDUPE (CX-93rv): every existing entry is, in this v0
      schema, a pending item — there is no `"done"`/status field anywhere in
      the agenda note-meta, so "an existing PENDING entry" here just means
      "any existing entry." Appending a `"text"` that exactly matches an
      already-present entry's `"text"` is a no-op returning `:ok` (idempotent
      seed) instead of stacking a duplicate line. This fixes CX-93rv: a
      re-armed provision ceremony re-running the agenda-seed step used to
      double the first errand every time.

  ## `Agenda.replace/2` vs `Agenda.append/2`

  `replace/2` overwrites the ENTIRE `"entries"` list — it's what the
  `update_agenda` tool now calls (see that module's moduledoc for why: the
  tool's purpose turned out to be "rewrite what's on the desk right now," not
  "add one more line to a log that never shrinks" — the live agenda drifting
  to 6 duplicate/stale entries with no way back down is exactly the append-only
  shape's failure mode). `append/2` remains the log-growing primitive other
  callers (provision seeding, tests) use.
  """

  require Logger

  alias Commonplace.Bots.NoteDoc
  alias Commonplace.MUD.World

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

  CX-93rv DEDUPE: if `item["text"]` exactly matches an existing entry's
  `"text"`, this is a no-op — `:ok` is returned without a write (logged at
  `:debug`). Every entry in this v0 schema is implicitly pending (there is no
  status field to distinguish a "done" item from a live one), so "duplicate of
  a pending entry" reduces to "duplicate of any entry." This makes a re-run
  provision/seed ceremony idempotent instead of doubling the same errand.
  """
  @spec append(map(), map() | nil) :: :ok | {:error, term()}
  def append(%{"text" => text} = item, %{} = ctx) when is_binary(text) do
    stamped =
      Map.put_new_lazy(item, "ts", fn -> DateTime.utc_now() |> DateTime.to_iso8601() end)

    with {:ok, uuid} <- ensure_dir(ctx) do
      # CX-r97r: dedupe check and append share the SAME recomputed read (see
      # `NoteDoc.append_entry_unless/4`) instead of a separate
      # `read_entries/2` call followed by a separate `append_entry/3` read —
      # closing the double-read staleness window between them.
      NoteDoc.append_entry_unless(
        uuid,
        stamped,
        fn existing ->
          if Enum.any?(existing, fn e -> Map.get(e, "text") == text end) do
            Logger.debug("Agenda.append: skipping duplicate entry #{inspect(text)}")
            true
          else
            false
          end
        end,
        ctx
      )
    end
  end

  def append(item, %{} = ctx) when is_map(item) do
    item =
      Map.put_new_lazy(item, "ts", fn -> DateTime.utc_now() |> DateTime.to_iso8601() end)

    with {:ok, uuid} <- ensure_dir(ctx) do
      NoteDoc.append_entry(uuid, item, ctx)
    end
  end

  def append(_item, _ctx), do: {:error, :no_mud_ctx}

  @doc """
  REPLACE the entire agenda: overwrite the `"entries"` list wholesale with
  `items` (a list of free-form maps), bot-signed, zone-preserving
  (`World.merge_meta` — a targeted `"entries"` field overwrite, never a struct
  round-trip; CX-cl65). Each item gets a stamped `"ts"` if it omits one.

  This is what `update_agenda` (Camillo C5b) calls: the tool's purpose is
  rewriting the desk, not growing an append-only log that never shrinks — see
  `Commonplace.Bots.Worker.Tools.UpdateAgenda`'s moduledoc for the finding that
  motivated the switch from `append/2`.
  """
  @spec replace([map()], map() | nil) :: :ok | {:error, term()}
  def replace(items, %{home_room_uuid: _} = ctx) when is_list(items) do
    stamped =
      Enum.map(items, fn item ->
        Map.put_new_lazy(item, "ts", fn -> DateTime.utc_now() |> DateTime.to_iso8601() end)
      end)

    with {:ok, uuid} <- ensure_dir(ctx) do
      World.merge_meta(uuid, NoteDoc.note_filename(), %{"entries" => stamped}, ctx.store,
        signing_context: ctx.signing_context,
        cert_cids: ctx.cert_cids,
        signer_id: ctx.signer_id
      )
    end
  end

  def replace(_items, _ctx), do: {:error, :no_mud_ctx}
end
