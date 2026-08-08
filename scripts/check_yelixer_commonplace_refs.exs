defmodule YelixerCommonplaceBoundary do
  @moduledoc false

  def run(root) do
    violations =
      root
      |> source_files()
      |> Enum.flat_map(&violations/1)

    case violations do
      [] ->
        IO.puts("yelixer boundary check passed: no executable Commonplace references")
        :ok

      violations ->
        IO.puts(:stderr, "yelixer boundary check failed: executable Commonplace references found")
        Enum.each(violations, &IO.puts(:stderr, &1))
        :error
    end
  end

  defp source_files(root) do
    ["lib", "test"]
    |> Enum.flat_map(fn directory ->
      Path.wildcard(Path.join([root, "apps", "yelixer", directory, "**", "*.{ex,exs}"]))
    end)
    |> Enum.sort()
  end

  defp violations(path) do
    path
    |> File.read!()
    |> strip_prose()
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, line_number} ->
      if Regex.match?(~r/\bCommonplace\b/, line) do
        ["#{path}:#{line_number}:#{String.trim(line)}"]
      else
        []
      end
    end)
  end

  # Preserve newlines for actionable locations while removing the two prose
  # forms allowed to mention Commonplace: line comments and heredoc bodies.
  defp strip_prose(source), do: scan(source, :code, []) |> IO.iodata_to_binary()

  defp scan(<<>>, _state, acc), do: Enum.reverse(acc)

  defp scan(<<"\"\"\"", rest::binary>>, :code, acc),
    do: scan(rest, :heredoc, ["   " | acc])

  defp scan(<<"\"\"\"", rest::binary>>, :heredoc, acc),
    do: scan(rest, :code, ["   " | acc])

  defp scan(<<"\n", rest::binary>>, :heredoc, acc),
    do: scan(rest, :heredoc, ["\n" | acc])

  defp scan(<<_byte, rest::binary>>, :heredoc, acc),
    do: scan(rest, :heredoc, [" " | acc])

  defp scan(<<"#", rest::binary>>, :code, acc),
    do: scan(rest, :comment, [" " | acc])

  defp scan(<<"\n", rest::binary>>, :comment, acc),
    do: scan(rest, :code, ["\n" | acc])

  defp scan(<<_byte, rest::binary>>, :comment, acc),
    do: scan(rest, :comment, [" " | acc])

  defp scan(<<quote, rest::binary>>, :code, acc) when quote in [?\", ?'],
    do: scan(rest, {:string, quote}, [quote | acc])

  defp scan(<<"\\", escaped, rest::binary>>, {:string, quote}, acc),
    do: scan(rest, {:string, quote}, [escaped, ?\\ | acc])

  defp scan(<<quote, rest::binary>>, {:string, quote}, acc),
    do: scan(rest, :code, [quote | acc])

  defp scan(<<byte, rest::binary>>, {:string, quote}, acc),
    do: scan(rest, {:string, quote}, [byte | acc])

  defp scan(<<byte, rest::binary>>, :code, acc),
    do: scan(rest, :code, [byte | acc])
end

root = System.argv() |> List.first() |> then(&(&1 || File.cwd!())) |> Path.expand()

case YelixerCommonplaceBoundary.run(root) do
  :ok -> System.halt(0)
  :error -> System.halt(1)
end
