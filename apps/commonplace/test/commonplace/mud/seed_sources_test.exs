defmodule Commonplace.MUD.SeedSourcesTest do
  use ExUnit.Case, async: true

  @moduledoc """
  CX-6pbu (self-hosting slice 3): guard test for the seed sources moved
  out of pasted `~S'''`/heredoc module attributes into
  `priv/engine_verbs/*.exs.seed` (+ `priv/chat/compute.exs.seed`),
  loaded at compile time via `@external_resource` + `File.read!`.

  True byte-parity against the old literal can't be asserted here (the
  literal is gone post-move) — that was verified during development via
  a throwaway diff against the pre-move git blob and then deleted. This
  test instead asserts the loaded attributes are non-empty, contain
  their expected module/defmodule marker, and end in a newline — a
  cheap sanity net alongside the full test suite (engine-module
  doc-compile tests, chat template tests) staying green.
  """

  alias Commonplace.Chat.TemplateBootstrap
  alias Commonplace.MUD.Bootstrap

  @engine_sources [
    {:engine_parser_source, "defmodule Commonplace.MUD.EngineParser do"},
    {:engine_look_verb_source, "defmodule Commonplace.MUD.EngineLook do"},
    {:engine_inventory_verb_source, "defmodule Commonplace.MUD.EngineInventory do"},
    {:engine_emote_verb_source, "defmodule Commonplace.MUD.EngineEmote do"},
    {:engine_say_verb_source, "defmodule Commonplace.MUD.EngineSay do"}
  ]

  for {attr, marker} <- @engine_sources do
    test "Bootstrap.#{attr}/0 source is non-empty, has its module marker, ends in newline" do
      source = apply(Bootstrap, unquote(attr), [])
      assert source != ""
      assert String.contains?(source, unquote(marker))
      assert String.ends_with?(source, "\n")
    end
  end

  test "chat compute source is non-empty, has its module marker, ends in newline" do
    source = TemplateBootstrap.chat_compute_source()
    assert source != ""
    assert String.contains?(source, "defmodule Commonplace.UserCode.Chat.Compute do")
    assert String.ends_with?(source, "\n")
  end
end
