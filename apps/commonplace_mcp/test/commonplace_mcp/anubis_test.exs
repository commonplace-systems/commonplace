defmodule Commonplace.MCP.AnubisTest do
  @moduledoc """
  Smoke tests that the `anubis_mcp` dep is wired in and our facade
  returns reasonable values. Not intended to be exhaustive — the
  facade grows incrementally as we route specific capabilities
  through anubis.
  """
  use ExUnit.Case, async: true

  alias Commonplace.MCP.Anubis

  describe "supported_protocol_versions/0" do
    test "returns a non-empty list of date-style version strings" do
      versions = Anubis.supported_protocol_versions()

      assert is_list(versions)
      assert length(versions) >= 1

      for v <- versions do
        assert is_binary(v)
        assert Regex.match?(~r/^\d{4}-\d{2}-\d{2}$/, v)
      end
    end
  end

  describe "latest_protocol_version/0" do
    test "is a date-style string and is present in supported_protocol_versions/0" do
      latest = Anubis.latest_protocol_version()

      assert is_binary(latest)
      assert Regex.match?(~r/^\d{4}-\d{2}-\d{2}$/, latest)
      assert latest in Anubis.supported_protocol_versions()
    end
  end
end
