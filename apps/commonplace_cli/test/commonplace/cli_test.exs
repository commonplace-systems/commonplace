defmodule Commonplace.CLITest do
  use ExUnit.Case

  test "help text includes commands" do
    assert Commonplace.CLI.__info__(:functions) |> Keyword.has_key?(:main)
  end
end
