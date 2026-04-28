defmodule Commonplace.MUD.Parser do
  @moduledoc """
  Single-line MUD command parser.

  Splits player input into `verb_word`, `args` (raw), `argv` (whitespace
  list), and a `target` candidate (first argv element). Aliases like
  `n` → `north`, `i` → `inventory` are normalized here.
  """

  @direction_aliases %{
    "n" => "north",
    "s" => "south",
    "e" => "east",
    "w" => "west",
    "u" => "up",
    "d" => "down"
  }

  @verb_aliases Map.merge(@direction_aliases, %{
                  "i" => "inventory",
                  "inv" => "inventory",
                  "l" => "look",
                  "'" => "say",
                  "\"" => "say"
                })

  defmodule Command do
    defstruct verb: "", args: "", argv: [], target: nil
  end

  @doc """
  Parse a single line of input. Returns a `%Command{}`.

  Empty / whitespace-only input parses to an empty verb (caller should
  ignore).
  """
  def parse(line) when is_binary(line) do
    line = String.trim(line)

    case line do
      "" ->
        %Command{}

      <<"'", rest::binary>> when rest != "" ->
        %Command{verb: "say", args: rest, argv: [rest], target: nil}

      _ ->
        {verb_word, args} = split_first(line)
        verb = Map.get(@verb_aliases, String.downcase(verb_word), String.downcase(verb_word))
        argv = if args == "", do: [], else: String.split(args, ~r/\s+/, trim: true)
        target = List.first(argv)
        %Command{verb: verb, args: args, argv: argv, target: target}
    end
  end

  defp split_first(line) do
    case String.split(line, ~r/\s+/, parts: 2) do
      [verb] -> {verb, ""}
      [verb, rest] -> {verb, rest}
    end
  end

  @doc "Returns the canonical verb for a known direction shortcut, or nil."
  def direction_to_full(word) when is_binary(word), do: Map.get(@direction_aliases, word)

  @doc "Map a direction to its opposite (for `@dig` two-way exits)."
  def opposite_direction("north"), do: "south"
  def opposite_direction("south"), do: "north"
  def opposite_direction("east"), do: "west"
  def opposite_direction("west"), do: "east"
  def opposite_direction("up"), do: "down"
  def opposite_direction("down"), do: "up"
  def opposite_direction("in"), do: "out"
  def opposite_direction("out"), do: "in"
  def opposite_direction(_), do: nil

  @doc "Returns true if the verb is one of the cardinal/movement directions."
  def direction?(verb) when is_binary(verb) do
    verb in ["north", "south", "east", "west", "up", "down", "in", "out"]
  end
end
