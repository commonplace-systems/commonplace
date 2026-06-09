defmodule Commonplace.Compute do
  @moduledoc """
  CX-dhde (sub-bead ii of CX-a9cv M7): substrate-tier helpers for
  compute fns. Authors compose these with `|>` + Elixir's stdlib (Enum,
  Map, Stream, etc.) to build pipelines.

  ## Round-1 banked design principle

  **`Commonplace.Compute.*` is AUTHOR-FACING** — atom-flavored,
  Elixir-native shapes. **Substrate-tier modules retain JSON-flavored
  shapes** (string keys, nested maps) because data-on-wire is JSON.
  This module bridges via thin adapters.

  Future stdlib expansions follow this pattern: present an
  Elixir-native API; adapt to substrate-tier when calling through.
  ~10 lines per adapter; pays for itself on every author write.

  ## Surface area

  Initial stdlib is deliberately minimal:

  * `decode_json_array/1` — wraps `Enum.map(&Jason.decode!/1)`
  * `materialize/2` — chain-rules adapter over `Commonplace.Materialize`

  This module owns only the *shape bridge*: the author-facing atom/tuple
  form and its mechanical translation to the substrate form. What a chain
  rule actually MEANS — the `:latest_replaces` / `:marks_deleted`
  semantics, orphan filtering, what "latest" resolves to, cycle-safety —
  lives in `Commonplace.Materialize`, the single source of truth this
  adapter drives. Reach there (not here) for the resolution semantics.

  Expansion follows observed authoring patterns, not pre-design.
  Filter/group-by/time-window/format-conversion are already Enum/Stream;
  authors write Elixir directly. Future named substrate fns IF authoring
  shows them as recurring patterns across view types.

  ## Usage example (chat compute fn)

      defmodule Commonplace.UserCode.Chat.Compute do
        alias Commonplace.Compute

        def compute(raw, ctx) do
          raw
          |> Compute.decode_json_array()
          |> Compute.materialize(chains: [
            {:edit_of, :latest_replaces},
            {:tombstone_of, :marks_deleted}
          ])
          |> Commonplace.Chat.ChatViewBuilder.build_view_xml(ctx.room_name)
        end
      end
  """

  @doc """
  Decode a list of JSON-encoded entries to maps. Wrapper over
  `Enum.map(&Jason.decode!/1)` — promoted from M5's
  `<step kind="decode_json_array"/>` enumerated kind.

  Raises `Jason.DecodeError` on invalid JSON (substrate doesn't swallow
  parse errors).
  """
  @spec decode_json_array([binary()]) :: [term()]
  def decode_json_array(raw_entries) when is_list(raw_entries) do
    Enum.map(raw_entries, &Jason.decode!/1)
  end

  @doc """
  Materialize entries via chain rules. Author-facing shape:

      Compute.materialize(entries, chains: [
        {:edit_of, :latest_replaces},
        {:tombstone_of, :marks_deleted}
      ])

  Adapter converts the tuple form to substrate `Commonplace.Materialize`'s
  JSON-flavored shape:

      %{chains: [
        %{field: "edit_of", semantics: :latest_replaces},
        %{field: "tombstone_of", semantics: :marks_deleted}
      ]}

  Atom field names → string field names (entries on the wire have
  string keys). Tuple → map. ~10-line adapter.

  Also accepts chains already in the substrate `%{field: ..., semantics:
  ...}` map form — those pass through untouched. This lets a caller that
  builds chain rules programmatically (rather than as literal tuples)
  hand them straight in without round-tripping through the atom form.
  """
  @spec materialize([map()], keyword()) :: [map()]
  def materialize(entries, opts) when is_list(entries) and is_list(opts) do
    chains = Keyword.get(opts, :chains, [])
    Commonplace.Materialize.materialize(entries, %{chains: adapt_chains(chains)})
  end

  defp adapt_chains(chains) when is_list(chains) do
    Enum.map(chains, &adapt_chain/1)
  end

  defp adapt_chain({field, semantics}) when is_atom(field) and is_atom(semantics) do
    %{field: Atom.to_string(field), semantics: semantics}
  end

  # Pass-through for already-substrate-shape chains (e.g., callers
  # constructing chains programmatically in the substrate form).
  defp adapt_chain(%{field: _, semantics: _} = already_substrate_shape) do
    already_substrate_shape
  end
end
