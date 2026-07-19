defmodule Commonplace.Bots.Worker.Tools.Scratch do
  @moduledoc """
  `scratch` tool (Camillo C3c) — jot a note to the bot's own private scratchpad.

  The DEMO's visible WRITE half: a heartbeat turn calls this and a durable
  working doc grows in the tree, with no chat involved — the "continuously alive"
  runtime leaving an observable trail.

  ## Anchored under the bot's HOME (lands under enforce)

  The scratchpad lives UNDER the bot's home as a ZONED NOTE-META, not under the
  MUD root: `home/scratch/<page>/` where each dir is a zoned child (via
  `Commonplace.Bots.NoteDoc` → `ChildMutation.create_zoned_child`) INHERITING the
  home zone-stamp. Because the pages sit in the bot's home zone, the bot's
  `{:subtree, home}[:write]` cert covers every write — so a scratch jot LANDS
  under `local_write_gate: :enforce`. The prior MUD-root anchor wrote plain
  (non-zone-stamped) docs OUTSIDE the bot's cert scope and was DENIED under
  enforce (`:capability_insufficient`).

  The note itself is a `"text"` field inside the page's `__note.json` note-meta;
  `NoteDoc.append_text/4` grows it SURGICALLY (`World.merge_meta`), preserving the
  node-signed `zone` stamp on every append (never a struct round-trip — CX-cl65).

  ## Namespace bounding (in the tool, not just store perms)

  The `page` input is validated to a single safe path segment: any attempt to
  escape the `scratch/**` namespace — a `/`, a `\\`, a `..`, an empty/oversized
  name — is REFUSED with a sanitized message and NO write happens. This is a
  defense-in-depth check that does NOT rely on store permissions alone. (The
  per-bot botname layer of the old MUD-root path is now redundant — the
  scratchpad is already under the bot's OWN home — but the page-name safety
  validation is preserved.)

  ## Bot-signed, substrate-pure

  Every write (dir genesis entry-add, page append) is signed with the bot's OWN
  key via `state.mud_ctx.signing_context` (C1 discipline), carrying the
  `Citizenship.ensure/5` cert cids (pin c). The child zone-STAMP genesis is
  node-signed by construction (CX-4u03 split authority); the entry-add + note
  append are the bot's own creds.
  """

  alias Commonplace.Bots.NoteDoc

  @scratch_root "scratch"
  @default_page "notes"
  @max_segment 64
  # A single safe path segment: alnum plus . _ - and spaces. No slashes, no "..".
  @safe_segment ~r/^[A-Za-z0-9 ._-]+$/

  def name, do: "scratch"

  def definition do
    %{
      "name" => "scratch",
      "description" =>
        "Jot a note to your private scratchpad (scratch/<page>). " <>
          "Persists in the world tree under your home; append-only. " <>
          "Optional \"page\" picks a page (default \"notes\").",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "note" => %{
            "type" => "string",
            "description" => "The note to jot. Free-form text, appended as a new line."
          },
          "page" => %{
            "type" => "string",
            "description" =>
              "Optional page name within your scratchpad (a single name, no slashes). Defaults to \"notes\"."
          }
        },
        "required" => ["note"]
      }
    }
  end

  def call(%{mud_ctx: ctx}, %{"note" => note} = input)
      when is_map(ctx) and is_binary(note) and note != "" do
    with {:ok, page} <- safe_page(Map.get(input, "page")),
         {:ok, page_uuid} <- ensure_page(ctx, page),
         :ok <- NoteDoc.append_text(page_uuid, "text", line(note), ctx) do
      {:ok, "jotted to scratch/#{page}"}
    else
      # Sanitized refusals (safe_page) are already user-safe binaries; internal
      # failures (mint/merge rejections) are inspected, never leaked structurally.
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  def call(%{mud_ctx: ctx}, _input) when is_map(ctx),
    do: {:error, "scratch requires a non-empty 'note'."}

  # No MUD ctx — not in the world, no scratchpad to write. Sanitized refusal.
  def call(_state, _input), do: {:error, "You are not in the world."}

  # NAMESPACE GUARD (defense-in-depth): the page must be a single safe segment.
  # A path-escape attempt (slash, backslash, "..", empty, oversized) is refused
  # loudly — the constructed path can never leave scratch/.
  defp safe_page(nil), do: {:ok, @default_page}

  defp safe_page(page) when is_binary(page) do
    trimmed = String.trim(page)

    cond do
      trimmed == "" -> {:ok, @default_page}
      String.length(trimmed) > @max_segment -> {:error, "Bad page name."}
      trimmed in [".", ".."] -> {:error, "Bad page name."}
      String.contains?(trimmed, ["/", "\\", ".."]) -> {:error, "Bad page name."}
      Regex.match?(@safe_segment, trimmed) -> {:ok, trimmed}
      true -> {:error, "Bad page name."}
    end
  end

  defp safe_page(_), do: {:error, "Bad page name."}

  # home/scratch/ -> home/scratch/<page>/, each a ZONED note-meta dir created
  # bot-signed on first use, then reused (get-before-create via NoteDoc). Anchored
  # under ctx.home_room_uuid so the zone inherits == home and the bot's
  # {:subtree, home} cert covers every write. The scratch container carries an
  # empty note-meta; each page seeds a "text" field the note appends to.
  defp ensure_page(ctx, page) do
    with {:ok, scratch_uuid} <-
           NoteDoc.ensure_zoned_dir(ctx.home_room_uuid, @scratch_root, Jason.encode!(%{}), ctx),
         {:ok, page_uuid} <-
           NoteDoc.ensure_zoned_dir(scratch_uuid, page, Jason.encode!(%{"text" => ""}), ctx) do
      {:ok, page_uuid}
    end
  end

  defp line(note), do: String.trim_trailing(note, "\n") <> "\n"
end
