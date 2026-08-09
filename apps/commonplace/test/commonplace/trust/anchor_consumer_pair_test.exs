defmodule Commonplace.Trust.AnchorConsumerPairTest do
  use ExUnit.Case, async: true

  test "Trust and MUD share one anchor outcome policy" do
    assert Code.ensure_loaded?(Commonplace.Trust)
    assert function_exported?(Commonplace.Trust, :anchor_keys, 1)

    trust_source =
      File.read!(Path.join(__DIR__, "../../../lib/commonplace/trust.ex"))

    verbs_source =
      File.read!(Path.join(__DIR__, "../../../lib/commonplace/mud/verbs.ex"))

    assert trust_source =~ "def anchor_keys(cfg)"
    assert verbs_source =~ "Commonplace.Trust.anchor_keys(Commonplace.Trust.config())"
    refute verbs_source =~ "NodeIdentity.public_keys()"
  end
end
