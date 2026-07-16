defmodule Commonplace.MUD.SafeVerb.ApiDocTest do
  @moduledoc """
  CX-hbb2 — the drift-killer. `ApiDoc.entries/0` is DOCUMENTATION DATA for
  the live `Commonplace.MUD.SafeVerb.Allowlist` facade admit-set; the whole
  point is that it can never silently fall behind the admit-set the way the
  hand-written `@verb`-editor banner did (CX-hn75: it omitted open_exit,
  grant, spawn, consume, whisper, and more). This test pins the two-way
  equality so any future allowlist change (add/remove a `{fun, arity}`) fails
  loudly here until `ApiDoc.entries/0` is updated to match.
  """
  use ExUnit.Case, async: true

  alias Commonplace.MUD.SafeVerb.{Allowlist, ApiDoc}

  test "entries/0 covers EXACTLY the live facade allowlist — no drift either direction" do
    documented = ApiDoc.entries() |> Map.keys() |> MapSet.new()
    admitted = Allowlist.profile().domain_allowed

    missing = MapSet.difference(admitted, documented)
    extra = MapSet.difference(documented, admitted)

    assert MapSet.equal?(documented, admitted), """
    ApiDoc.entries/0 has drifted from Commonplace.MUD.SafeVerb.Allowlist's live \
    admit-set (the CX-hn75 bug class this module exists to kill).

    Admitted but UNDOCUMENTED (add an entry to ApiDoc.entries/0): #{inspect(MapSet.to_list(missing))}
    Documented but NOT admitted (remove the stale entry from ApiDoc.entries/0): #{inspect(MapSet.to_list(extra))}
    """
  end

  test "render_calls/0 mentions every admitted function by name" do
    text = ApiDoc.render_calls()

    for {fun, _arity} <- Allowlist.profile().domain_allowed do
      assert text =~ "#{fun}(", "render_calls/0 is missing a mention of #{fun}/N"
    end
  end

  test "render_calls/0 is non-empty, stable, deterministic text" do
    assert ApiDoc.render_calls() == ApiDoc.render_calls()
    assert String.length(ApiDoc.render_calls()) > 0
  end
end
