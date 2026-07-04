defmodule Commonplace.GitBridge.CanonicalJson do
  @moduledoc """
  Deterministic, byte-stable JSON rendering for GitBridge's exported
  files and sidecar metadata.

  Jason does not guarantee map key order across versions (it's an
  implementation detail, not a contract), so this module walks the term
  itself — sorting map keys recursively — and only calls out to Jason to
  encode individual leaf scalars (strings/numbers/booleans/nil). That
  keeps output byte-identical for two terms that are equal, regardless
  of how their maps were built (insertion order, cache path, etc.) —
  the property GitBridge's phantom-diff invariant (no spurious git
  commits when nothing changed) depends on.

  Output is 2-space indented, with a single trailing newline (git-diff
  and POSIX-text-file friendly).
  """

  @doc """
  Render `term` as canonical JSON text: sorted map keys, 2-space indent,
  exactly one trailing newline.
  """
  @spec encode(term()) :: String.t()
  def encode(term) do
    iodata = render(term, 0)
    IO.iodata_to_binary([iodata, "\n"])
  end

  # --- Private ---

  defp render(map, indent) when is_map(map) do
    entries = map |> Map.to_list() |> Enum.sort_by(fn {k, _v} -> to_string(k) end)

    case entries do
      [] ->
        "{}"

      _ ->
        inner_indent = indent + 1

        body =
          entries
          |> Enum.map(fn {k, v} ->
            [
              pad(inner_indent),
              scalar(to_string(k)),
              ": ",
              render(v, inner_indent)
            ]
          end)
          |> Enum.intersperse(",\n")

        ["{\n", body, "\n", pad(indent), "}"]
    end
  end

  defp render(list, indent) when is_list(list) do
    case list do
      [] ->
        "[]"

      _ ->
        inner_indent = indent + 1

        body =
          list
          |> Enum.map(fn v -> [pad(inner_indent), render(v, inner_indent)] end)
          |> Enum.intersperse(",\n")

        ["[\n", body, "\n", pad(indent), "]"]
    end
  end

  defp render(scalar, _indent), do: scalar(scalar)

  defp scalar(value), do: Jason.encode!(value)

  defp pad(indent), do: String.duplicate("  ", indent)
end
