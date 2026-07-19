defmodule Commonplace.Bots.Worker.Tools.ListScratch do
  @moduledoc """
  `list_scratch` tool (Camillo C5c-iii, cp-plan #8892/#8895) — the filing
  loop's read half, part one: list the page names under the bot's own
  `home/<book>/`.

  "scrollback is what just happened; scratch is what he chose to keep;
  rooms are what he chose to KEEP keeping" — this tool (and its sibling
  `read_scratch`) are what let him actually consult the middle tier before
  distilling it further. No write path exists here; this module never
  touches the store except to read.

  ## The container/page shape (same one `Commonplace.Bots.Worker.Tools.Scratch`
  ## writes and `Commonplace.Bots.NoteDoc` mints)

  `home/<book>/` is itself a zoned note-meta dir (its OWN `__note.json`,
  currently unused content, just the container's genesis) with one child DIR
  per page (`home/<book>/<page>/`, each ALSO carrying its own `__note.json`
  whose `"text"` field is the page's content — see `Scratch`'s moduledoc).
  Listing therefore means: read `home/<book>/`'s schema entries and keep
  only the `:dir` ones — filtering by TYPE, not by name, cleanly excludes
  the container's own `__note.json` FILE entry (a `:doc`, never a `:dir`)
  without a name special-case that could drift out of sync with `NoteDoc`.

  A bot with no `<book>` dir yet (never jotted anything there) or no
  `mud_ctx` reads as empty — `"(no scratch pages yet)"` /
  `"(no wiki pages yet)"` — never an error tuple; an empty book is not a
  failure.

  ## The wiki namespace (Camillo C6, cp-plan #8949/#8952) — ZERO new authority

  The SAME optional `"book"` enum (`"scratch"` default, or `"wiki"`)
  `Scratch`/`ReadScratch` accept — see `Scratch`'s moduledoc "The wiki
  namespace" for the full rationale. An out-of-enum book is refused
  sanitized before any read.
  """

  alias Commonplace.MUD.{Schemas, World}
  alias Commonplace.Tree.Schema

  @default_book "scratch"
  @valid_books ~w(scratch wiki)

  def name, do: "list_scratch"

  def definition do
    %{
      "name" => "list_scratch",
      "description" =>
        "List the page names in your scratch pages or your wiki — the spine your rooms " <>
          "hang from. Optional \"book\": \"scratch\" (default) or \"wiki\".",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "book" => %{
            "type" => "string",
            "enum" => @valid_books,
            "description" => "Which book: \"scratch\" (default) or \"wiki\"."
          }
        }
      }
    }
  end

  def call(%{mud_ctx: ctx}, input) when is_map(ctx) do
    case safe_book(Map.get(input, "book")) do
      {:ok, book} -> {:ok, list_book(ctx, book)}
      {:error, reason} -> {:error, reason}
    end
  end

  # No MUD ctx — not in the world, no scratchpad to list. Sanitized refusal
  # (the SAME "You are not in the world." shape `scratch`/`move`/`look` use —
  # not `read_memory`'s graceful-empty-array pattern; this is a home-scoped
  # tool like `Scratch`, its write-side sibling, refuses the same way).
  def call(_state, _input), do: {:error, "You are not in the world."}

  # BOOK GUARD — identical enum to Scratch.safe_book/1.
  defp safe_book(nil), do: {:ok, @default_book}
  defp safe_book(book) when book in @valid_books, do: {:ok, book}
  defp safe_book(_), do: {:error, "Bad book (use \"scratch\" or \"wiki\")."}

  defp list_book(ctx, book) do
    case lookup_entry(ctx.home_room_uuid, book, ctx.store) do
      {:ok, book_uuid} ->
        book_uuid
        |> World.list_entries(ctx.store)
        |> Enum.filter(&(&1.type == :dir))
        |> Enum.map(& &1.name)
        |> Enum.sort()
        |> render(book)

      :error ->
        render([], book)
    end
  end

  defp render([], "wiki"), do: "(no wiki pages yet)"
  defp render([], _book), do: "(no scratch pages yet)"
  defp render(pages, _book), do: Enum.join(pages, ", ")

  defp lookup_entry(parent_uuid, name, store) do
    with {:ok, schema} <- Schemas.load_dir_schema(parent_uuid, store),
         {:ok, %{node_id: node_id}} <- Schema.get_entry(schema, name) do
      {:ok, node_id}
    else
      _ -> :error
    end
  end
end
