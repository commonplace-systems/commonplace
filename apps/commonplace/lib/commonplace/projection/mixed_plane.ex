defmodule Commonplace.Projection.MixedPlane do
  @moduledoc """
  CX-mchn's mixed-binding condition, as a **detect-only** tripwire that
  `Commonplace.Projection` runs on state reconstructed AT A PIN (F9).

  ## The condition

  A named Yelixer type has two storage planes:

    * the **MAP plane** — items with `parent_sub != nil`, living in the
      type's key-space;
    * the **SEQUENCE plane** — items with `parent_sub == nil`, living in
      the type's positional order.

  A single name holding live content in BOTH planes is a *mixed binding*.
  It is left behind by migration residue (a per-field → single-blob schema
  change stranding a key item under a name a later Text also writes to),
  and it is the shape under which CX-mchn destroyed 15 characters of live,
  never-deleted content in one encode/decode round-trip with an EMPTY
  delete_set.

  ## Why detect-only, and why at pin reads specifically

  CX-mchn layer 1 (`52f7caf`) fixed the AUTHORING side: `Text.insert` no
  longer resolves YATA anchors across the plane boundary, so no NEW mixed
  binding can be authored. The DECODE side was deliberately left untouched
  — it is spec-faithful (yjs 13.6.30 and yrs 0.25 both agree with it on
  the corrupting bytes), and changing inheritance semantics would alter
  what already-committed history reconstructs to.

  Which means: history authored BEFORE the fix can still contain the
  condition, and reconstructing it is exactly when the loss happens. Head
  audits stay blind to this — the armed doc's mixed binding sits at pin
  2-of-5, not at head — so a tripwire that only guards head-time paths
  never fires on it. This module is that tripwire moved to where the
  condition actually lives.

  A trip is `{:unknown, {:mixed_plane, details}}` from `project_at` —
  **never bytes**. Projection reports; it never repairs (repair has its
  own human gate).

  ## Deliberate scope

  Only LIVE items count. A tombstoned (`deleted`) item in the other plane
  cannot be resurrected into a same-key map write, so counting it would
  manufacture false trips on ordinary edited history — and a tripwire that
  fires on ordinary history gets muted, which is worse than no tripwire.
  """

  alias Yelixer.{BlockStore, Doc}

  @type details :: %{
          types: [
            %{
              name: String.t(),
              kind: atom(),
              keyed_live: non_neg_integer(),
              plain_live: non_neg_integer(),
              keys: [String.t()]
            }
          ]
        }

  @doc """
  Scan a reconstructed doc for mixed bindings.

  Returns `:ok`, or `{:trip, details}` naming every offending type with
  both plane populations and the stranded keys.
  """
  @spec scan(Doc.t()) :: :ok | {:trip, details()}
  def scan(%Doc{types: types, store: store}) do
    offenders =
      types
      |> Enum.map(fn {name, kind} -> classify(store, name, kind) end)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(& &1.name)

    case offenders do
      [] -> :ok
      _ -> {:trip, %{types: offenders}}
    end
  end

  defp classify(store, name, kind) do
    items = BlockStore.get_sequence(store, name) |> Enum.reject(& &1.deleted)

    {keyed, plain} = Enum.split_with(items, &(&1.parent_sub != nil))

    if keyed != [] and plain != [] do
      %{
        name: name,
        kind: kind,
        keyed_live: length(keyed),
        plain_live: length(plain),
        keys: keyed |> Enum.map(& &1.parent_sub) |> Enum.uniq() |> Enum.sort()
      }
    end
  end
end
