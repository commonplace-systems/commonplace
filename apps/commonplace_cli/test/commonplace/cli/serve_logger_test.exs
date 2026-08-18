defmodule Commonplace.CLI.ServeLoggerTest do
  use ExUnit.Case, async: true

  alias Commonplace.CLI.Serve

  test "serve sink lines carry an absolute UTC date and time" do
    {:ok, fixed, 0} = DateTime.from_iso8601("2026-08-18T20:30:40.123456Z")

    line =
      %{
        level: :warning,
        msg: {:string, "audit sink probe"},
        meta: %{time: DateTime.to_unix(fixed, :microsecond)}
      }
      |> Serve.format_log_event()
      |> IO.iodata_to_binary()

    assert line == "2026-08-18T20:30:40.123456+00:00 [warning] audit sink probe\n"
  end
end
