defmodule Commonplace.Chat.ChatViewCompute do
  @moduledoc """
  CX-7kl3 (sub-bead ii of CX-04d8 M3): chat-tier ViewCompute spec.

  Two responsibilities:

  1. **Chain rules**: declare chat's edit/tombstone semantics as data
     for the substrate `Commonplace.Materialize` primitive (lifted from
     `Chat.Messages.@chain_rules` per refinement #4).
  2. **compute_fn**: build a closure suitable for
     `Commonplace.ViewCompute`'s `:compute_fn` opt — takes the JSON-list
     content of `_messages` and returns view-XML to be written into
     `_view.xml`.

  ## Why a separate module from Chat.Messages

  Per the M3 spec architectural anchor: view-XML IS rendered output.
  The substrate-pure direction puts materialize rules with the compute
  step (the SmartDoc / ViewCompute spec), not with the data-shape
  module. `Chat.Messages.materialize/1` continues to delegate here for
  the chain rules so the legacy "give me the list of materialized
  message maps" API still works for callers that want the data without
  the view-XML wrapping (currently `ChatRoomLive` + integration tests).

  ## ViewCompute single-source per refinement (B)

  `Commonplace.ViewCompute` is single-source today (one `source_uuid`,
  one PubSub subscription). Chat compute_fn reads ONLY from `_messages`
  — `_messages.log` is the red audit-log onramp, its commits don't
  carry message state. This matches refinement (B)'s hard cut and
  jes-locked answer #2 (ViewCompute productionization OUT of M3).
  """

  alias Commonplace.Chat.ChatViewBuilder
  alias Commonplace.Materialize

  @chain_rules %{
    chains: [
      %{field: "edit_of", semantics: :latest_replaces},
      %{field: "tombstone_of", semantics: :marks_deleted}
    ]
  }

  @doc """
  Chain rules for chat's edit/tombstone semantics. Same shape M2's
  substrate primitive consumes; lifted here from `Chat.Messages` so
  it lives with the compute spec rather than the data-shape module.
  """
  def chain_rules, do: @chain_rules

  @doc """
  Build a compute_fn closure for `room_name`. Returns a 1-arity
  function that:

  1. Receives the source content of `_messages` (a list of JSON
     strings, since that's what `ContentType.get_content/1` returns
     for the `:array` ContentType envelope chat uses)
  2. Decodes each entry to a map
  3. Runs `Commonplace.Materialize.materialize/2` with chain rules
  4. Calls `Commonplace.Chat.ChatViewBuilder.build_view_xml/2`
  5. Returns the view-XML string

  Suitable for `Commonplace.ViewCompute.start_link(compute_fn: ...)`.
  """
  def compute_fn(room_name) when is_binary(room_name) do
    fn raw_entries ->
      raw_entries
      |> normalize_entries()
      |> Enum.map(&Jason.decode!/1)
      |> Materialize.materialize(@chain_rules)
      |> ChatViewBuilder.build_view_xml(room_name)
    end
  end

  # ContentType.get_content/1 returns nil/list/string depending on doc
  # type. For the array envelope chat uses we expect a list; defend
  # against the empty-doc startup case where the envelope's `content`
  # type might not yet be present.
  defp normalize_entries(entries) when is_list(entries), do: entries
  defp normalize_entries(_), do: []
end
