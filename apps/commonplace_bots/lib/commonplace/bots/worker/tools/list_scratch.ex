defmodule Commonplace.Bots.Worker.Tools.ListScratch do
  @moduledoc """
  `list_scratch` tool (Camillo C5c-iii, cp-plan #8892/#8895) — the filing
  loop's read half, part one: list the page names under the bot's own
  `home/scratch/`.

  "scrollback is what just happened; scratch is what he chose to keep;
  rooms are what he chose to KEEP keeping" — this tool (and its sibling
  `read_scratch`) are what let him actually consult the middle tier before
  distilling it further. No write path exists here; this module never
  touches the store except to read.

  ## The container/page shape (same one `Commonplace.Bots.Worker.Tools.Scratch`
  ## writes and `Commonplace.Bots.NoteDoc` mints)

  `home/scratch/` is itself a zoned note-meta dir (its OWN `__note.json`,
  currently unused content, just the container's genesis) with one child DIR
  per page (`home/scratch/<page>/`, each ALSO carrying its own `__note.json`
  whose `"text"` field is the page's content — see `Scratch`'s moduledoc).
  Listing therefore means: read `home/scratch/`'s schema entries and keep
  only the `:dir` ones — filtering by TYPE, not by name, cleanly excludes
  the container's own `__note.json` FILE entry (a `:doc`, never a `:dir`)
  without a name special-case that could drift out of sync with `NoteDoc`.

  A bot with no scratch dir yet (never jotted anything) or no `mud_ctx`
  reads as empty — `"(no scratch pages yet)"` — never an error tuple; an
  empty scratchpad is not a failure.
  """

  alias Commonplace.MUD.{Schemas, World}
  alias Commonplace.Tree.Schema

  @scratch_root "scratch"

  def name, do: "list_scratch"

  def definition do
    %{
      "name" => "list_scratch",
      "description" =>
        "List the page names in your private scratchpad (home/scratch/). No arguments.",
      "input_schema" => %{"type" => "object", "properties" => %{}}
    }
  end

  def call(%{mud_ctx: ctx}, _input) when is_map(ctx) do
    case lookup_entry(ctx.home_room_uuid, @scratch_root, ctx.store) do
      {:ok, scratch_uuid} ->
        pages =
          scratch_uuid
          |> World.list_entries(ctx.store)
          |> Enum.filter(&(&1.type == :dir))
          |> Enum.map(& &1.name)
          |> Enum.sort()

        {:ok, render(pages)}

      :error ->
        {:ok, render([])}
    end
  end

  # No MUD ctx — not in the world, no scratchpad to list. Sanitized refusal
  # (the SAME "You are not in the world." shape `scratch`/`move`/`look` use —
  # not `read_memory`'s graceful-empty-array pattern; this is a home-scoped
  # tool like `Scratch`, its write-side sibling, refuses the same way).
  def call(_state, _input), do: {:error, "You are not in the world."}

  defp render([]), do: "(no scratch pages yet)"
  defp render(pages), do: Enum.join(pages, ", ")

  defp lookup_entry(parent_uuid, name, store) do
    with {:ok, schema} <- Schemas.load_dir_schema(parent_uuid, store),
         {:ok, %{node_id: node_id}} <- Schema.get_entry(schema, name) do
      {:ok, node_id}
    else
      _ -> :error
    end
  end
end
