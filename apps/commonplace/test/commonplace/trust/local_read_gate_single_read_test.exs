defmodule Commonplace.Trust.LocalReadGateSingleReadTest do
  use ExUnit.Case, async: true

  test "Trust resolver is the only production local_read_gate application-env reader" do
    repo_root = Path.expand("../../../../..", __DIR__)

    matches =
      repo_root
      |> Path.join("apps/*/lib/**/*.ex")
      |> Path.wildcard()
      |> Enum.flat_map(fn path ->
        path
        |> File.read!()
        |> then(&Regex.scan(~r/Application\.get_env\(\s*:commonplace,\s*:local_read_gate/, &1))
        |> Enum.map(fn _match -> Path.relative_to(path, repo_root) end)
      end)

    assert matches == ["apps/commonplace/lib/commonplace/trust.ex"]
  end
end
