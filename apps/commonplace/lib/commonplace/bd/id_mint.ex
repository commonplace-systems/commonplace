defmodule Commonplace.Bd.IdMint do
  @moduledoc """
  Client-side ID minting for beads-on-Commonplace.

  Spec: /home/jes/commonplace-plan/docs/beads-on-commonplace.md §4.

  IDs look like `CX-bhul`, `HERMES-3kxw` — a workspace prefix plus a
  4-character base32 suffix from a restricted alphabet. The suffix
  is generated client-side from `:rand.uniform/1` (no CSPRNG; collision
  resistance comes from the alphabet × length, not unpredictability).

  On collision, retry with a fresh suffix once. In practice this
  never fires at beads scale — the alphabet of 32 chars × 4 positions
  gives ~1M slots, against thousands of issues per repo.
  """

  alias Commonplace.Bd.Workspace
  alias Commonplace.Store.CommitStoreClient

  # 32-character base32 alphabet from beads (no I, L, O, U to avoid
  # ambiguous human reads).
  @alphabet ~c"abcdefghjkmnpqrstvwxyz0123456789"
  @suffix_length 4
  @max_attempts 8

  @doc """
  Mints a fresh issue id, checking that the corresponding directory
  doesn't already exist.

  Returns `{:ok, "CX-bhul"}` or `{:error, :exhausted}` after
  `@max_attempts` collisions.
  """
  def mint_issue_id(root_uuid, prefix, store \\ CommitStoreClient) do
    do_mint(root_uuid, prefix, store, @max_attempts)
  end

  defp do_mint(_root, _prefix, _store, 0), do: {:error, :exhausted}

  defp do_mint(root_uuid, prefix, store, attempts) do
    suffix = random_suffix()
    id = "#{prefix}-#{suffix}"

    case Workspace.issue_dir_uuid(root_uuid, id, store) do
      :error -> {:ok, id}
      {:ok, _} -> do_mint(root_uuid, prefix, store, attempts - 1)
    end
  end

  @doc """
  Mints a comment id (no prefix, just `c-<suffix>`). Comment ids are
  scoped to their parent issue dir; collisions only matter within
  that dir.
  """
  def mint_comment_id, do: "c-#{random_suffix()}"

  defp random_suffix do
    Enum.map(1..@suffix_length, fn _ ->
      Enum.random(@alphabet)
    end)
    |> List.to_string()
  end
end
