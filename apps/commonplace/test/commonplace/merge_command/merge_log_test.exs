defmodule Commonplace.MergeCommand.MergeLogTest do
  @moduledoc """
  CX-nuc2: deterministic per-document merge log UUID derivation. Used
  when the merge target is a leaf doc (not a schema) — there's nowhere
  to attach a `__merge.log` schema entry, so the log lives at a
  UUID5-derived address any peer can rediscover given the target_uuid.
  """
  use ExUnit.Case, async: true

  alias Commonplace.MergeCommand.MergeLog

  describe "log_uuid_for_doc/1" do
    test "is deterministic for the same target_uuid" do
      id = "target-uuid-alpha"
      assert MergeLog.log_uuid_for_doc(id) == MergeLog.log_uuid_for_doc(id)
    end

    test "differs across target_uuids" do
      a = MergeLog.log_uuid_for_doc("target-uuid-alpha")
      b = MergeLog.log_uuid_for_doc("target-uuid-beta")
      refute a == b
    end

    test "is distinct from the target_uuid itself" do
      id = "target-uuid-alpha"
      refute MergeLog.log_uuid_for_doc(id) == id
    end

    test "is distinct from the mailbox UUID for the same raw identifier" do
      # Mailbox UUIDs (CX-92u) derive from a different namespace, so
      # even if someone calls both on the same string they get
      # different results — no accidental collision between a
      # presence identity's mailbox and a doc's merge log.
      id = "550e8400-e29b-41d4-a716-446655440000"

      refute MergeLog.log_uuid_for_doc(id) ==
               Commonplace.Presence.Mailbox.log_uuid_for_identity(id)
    end

    test "returns a well-formed UUID string" do
      result = MergeLog.log_uuid_for_doc("target-uuid-alpha")
      assert is_binary(result)
      assert String.length(result) == 36

      assert Regex.match?(
               ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/,
               result
             )
    end
  end
end
