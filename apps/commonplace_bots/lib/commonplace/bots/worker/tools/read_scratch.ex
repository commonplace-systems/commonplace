defmodule Commonplace.Bots.Worker.Tools.ReadScratch do
  @moduledoc """
  `read_scratch` tool (Camillo C5c-iii, cp-plan #8892/#8895) — the filing
  loop's read half, part two: read a page's full text back from the bot's
  own `home/<book>/<page>/`.

  "scrollback is what just happened; scratch is what he chose to keep;
  rooms are what he chose to KEEP keeping" — this is the tool that lets him
  actually consult what he chose to keep, before deciding what of it
  belongs distilled onto a room's description (`describe`).

  ## Namespace bounding (mirrors `Scratch`'s write-side guard exactly)

  `page` is validated with the SAME single-safe-segment rule
  `Commonplace.Bots.Worker.Tools.Scratch` enforces on write: a `/`, a `\\`,
  a `..`, an empty/oversized name is REFUSED with the identical sanitized
  `"Bad page name."` message, before any read is attempted. Deliberately
  duplicated (not extracted into `NoteDoc`, which is a mint/append library,
  not a validation one) rather than shared — small, and the two call sites
  (write-refuse-before-write, read-refuse-before-read) are independent
  defense-in-depth checks, not one shared trust boundary. The default page
  (no `"page"` given) is `"notes"` — the SAME default `Scratch` writes to,
  so a bare `scratch` + a bare `read_scratch` round-trip through the same
  page by default.

  ## The wiki namespace (Camillo C6, cp-plan #8949/#8952) — ZERO new authority

  The SAME optional `"book"` enum (`"scratch"` default, or `"wiki"`)
  `Scratch`/`ListScratch` accept — see `Scratch`'s moduledoc "The wiki
  namespace" for the full rationale. An out-of-enum book is refused
  sanitized before any read.

  ## Absent vs empty vs found (never an error tuple for "nothing to see")

  Matching `read_memory`'s VALUE-absent convention: a page that doesn't
  exist yet, or a book dir that doesn't exist yet (never jotted to), or
  an existing page whose text is still `""` (created but never written) all
  render a GENTLE in-fiction message — never `{:error, _}`. An `{:error,
  _}` is reserved for what's actually wrong (a bad book/page name, no
  `mud_ctx`) — a merely-empty page is not wrong, it's just empty.

  ## Cap

  The returned text is capped at ~4000 characters with an honest
  truncation note (`"…the page continues"`) appended — never a silent cut,
  never the full unbounded page dumped into a turn's context.
  """

  alias Commonplace.Bots.NoteDoc
  alias Commonplace.MUD.{Schemas, World}
  alias Commonplace.Tree.Schema

  @default_book "scratch"
  @valid_books ~w(scratch wiki)
  @default_page "notes"
  @max_segment 64
  @max_chars 4000
  @truncation_note "…the page continues"
  # Mirrors Scratch's @safe_segment exactly (see that module).
  @safe_segment ~r/^[A-Za-z0-9 ._-]+$/

  def name, do: "read_scratch"

  def definition do
    %{
      "name" => "read_scratch",
      "description" =>
        "Read a page from your scratch pages or your wiki — the spine your rooms hang " <>
          "from (book: \"scratch\" (default) or \"wiki\"). " <>
          "Optional \"page\" picks a page (default \"notes\", the same page 'scratch' " <>
          "writes to by default).",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "book" => %{
            "type" => "string",
            "enum" => @valid_books,
            "description" => "Which book: \"scratch\" (default) or \"wiki\"."
          },
          "page" => %{
            "type" => "string",
            "description" =>
              "Optional page name within the book (a single name, no slashes). Defaults to \"notes\"."
          }
        }
      }
    }
  end

  def call(%{mud_ctx: ctx}, input) when is_map(ctx) do
    with {:ok, book} <- safe_book(Map.get(input, "book")),
         {:ok, page} <- safe_page(Map.get(input, "page")) do
      {:ok, read_page(ctx, book, page)}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # No MUD ctx — not in the world, no scratchpad to read. Sanitized refusal
  # (same shape as `scratch`/`list_scratch`).
  def call(_state, _input), do: {:error, "You are not in the world."}

  # BOOK GUARD — identical enum to Scratch.safe_book/1.
  defp safe_book(nil), do: {:ok, @default_book}
  defp safe_book(book) when book in @valid_books, do: {:ok, book}
  defp safe_book(_), do: {:error, "Bad book (use \"scratch\" or \"wiki\")."}

  # NAMESPACE GUARD — identical rule to Scratch.safe_page/1 (see that
  # module's moduledoc "Namespace bounding").
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

  # A PURE lookup (never mints) — reading must never have the side effect of
  # creating the page/container it's asking about, unlike the write side's
  # get-or-create `NoteDoc.ensure_zoned_dir/4`.
  defp read_page(ctx, book, page) do
    with {:ok, book_uuid} <- lookup_entry(ctx.home_room_uuid, book, ctx.store),
         {:ok, page_uuid} <- lookup_entry(book_uuid, page, ctx.store),
         {:ok, note_map} <- World.get_meta_map(page_uuid, NoteDoc.note_filename(), ctx.store) do
      render_text(book, page, Map.get(note_map, "text", ""))
    else
      _ -> "(no such page: #{book}/#{page})"
    end
  end

  defp render_text(book, page, ""), do: "(#{book}/#{page} is empty)"

  defp render_text(_book, _page, text) when is_binary(text) do
    if String.length(text) > @max_chars do
      String.slice(text, 0, @max_chars) <> "\n" <> @truncation_note
    else
      text
    end
  end

  defp lookup_entry(parent_uuid, name, store) do
    with {:ok, schema} <- Schemas.load_dir_schema(parent_uuid, store),
         {:ok, %{node_id: node_id}} <- Schema.get_entry(schema, name) do
      {:ok, node_id}
    else
      _ -> :error
    end
  end
end
