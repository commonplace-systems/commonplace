defmodule Commonplace.Outline.Order do
  @moduledoc """
  Fractional-index order keys for outline siblings (CX-saix,
  outliner.md §4).

  A key is a base-62 digit string (`0-9 < A-Z < a-z`, plain binary
  comparison) read as a fraction in (0, 1). `between/2` mints a key
  strictly between any two neighbors with NO replica coordination —
  two replicas filling the same gap mint independently and usually get
  distinct-but-adjacent keys; when they collide on an EQUAL key, the
  `(order, id)` comparator (`compare/2`) breaks the tie by node id, so
  every replica derives the identical sibling ordering.

  Tail appends increment rather than bisect (LexoRank-style), so
  append-heavy use grows key length logarithmically; only adversarial
  same-gap bisection grows ~1 char per insert, which is acceptable
  (outline reorder traffic is append/move dominated).
  """

  @base 62
  @digits ~c(0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz)
  @mid_digit Enum.at(@digits, div(@base, 2))

  @doc """
  Mint a key strictly between `left` and `right` (`nil` = unbounded).
  """
  @spec between(String.t() | nil, String.t() | nil) :: String.t()
  def between(nil, nil), do: <<@mid_digit>>
  def between(left, nil) when is_binary(left), do: increment(left)
  def between(nil, right) when is_binary(right), do: before_key(right)

  def between(left, right) when is_binary(left) and is_binary(right) and left < right do
    midpoint(left, right)
  end

  @doc """
  Total order over `{order_key, id}` pairs: by key, then by id (the
  deterministic tiebreak for equal keys minted concurrently).
  """
  @spec compare({String.t(), String.t()}, {String.t(), String.t()}) :: :lt | :eq | :gt
  def compare({o, id1}, {o, id2}) do
    cond do
      id1 < id2 -> :lt
      id1 > id2 -> :gt
      true -> :eq
    end
  end

  def compare({o1, _}, {o2, _}), do: if(o1 < o2, do: :lt, else: :gt)

  # --- minting internals (digit values, not chars) ---

  defp val(d), do: Enum.find_index(@digits, &(&1 == d))
  defp dig(v), do: Enum.at(@digits, v)

  # Smallest-effort key strictly greater than `key`, bounded only by 1.0:
  # bump the last digit if possible (length-stable), else append the
  # middle digit after an all-max prefix.
  defp increment(key) do
    digits = String.to_charlist(key)

    case bump_last(Enum.reverse(digits), []) do
      :all_max -> key <> <<@mid_digit>>
      bumped -> List.to_string(bumped)
    end
  end

  defp bump_last([], _acc), do: :all_max

  defp bump_last([d | rest], _dropped) do
    v = val(d)

    if v < @base - 1 do
      Enum.reverse([dig(v + 1) | rest]) |> List.to_string() |> String.to_charlist()
    else
      bump_last(rest, [])
    end
  end

  # A key strictly between 0 and `right`.
  defp before_key(right) do
    scan_before(String.to_charlist(right), [])
  end

  defp scan_before([d | rest], acc) do
    case val(d) do
      0 -> scan_before(rest, [d | acc])
      1 -> finish(acc, [dig(0), @mid_digit])
      v -> finish(acc, [dig(div(v, 2))])
    end
  end

  # A key strictly between `left` and `right` (left < right guaranteed).
  defp midpoint(left, right) do
    do_midpoint(String.to_charlist(left), String.to_charlist(right), [])
  end

  defp do_midpoint(l, r, acc) do
    {dl, l_rest} = take_digit(l, 0)
    {dr, r_rest} = take_digit(r, @base)

    cond do
      dl == dr ->
        do_midpoint(l_rest, r_rest, [dig(dl) | acc])

      dr - dl > 1 ->
        finish(acc, [dig(div(dl + dr, 2))])

      true ->
        # Adjacent digits: emit the lower, then anything strictly above
        # the rest of `left` (no upper bound on this side).
        finish(acc, [dig(dl) | above(l_rest)])
    end
  end

  defp take_digit([], default), do: {default, []}
  defp take_digit([d | rest], _default), do: {val(d), rest}

  # A digit-list strictly greater than `rest`, bounded by 1.0.
  defp above([]), do: [@mid_digit]

  defp above([d | rest]) do
    v = val(d)

    if v < @base - 1 do
      [dig(div(v + @base, 2))]
    else
      [d | above(rest)]
    end
  end

  defp finish(acc_rev, tail), do: List.to_string(Enum.reverse(acc_rev) ++ tail)
end
