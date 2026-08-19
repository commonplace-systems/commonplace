defmodule Commonplace.Presence.MailboxTest do
  @moduledoc """
  CX-92u: deterministic derivation of a per-agent mailbox red-log UUID
  from a stable identity_uuid. Lets an agent reconnect and tail the same
  log (picking up messages sent while offline) without any per-session
  provisioning.
  """
  use ExUnit.Case, async: true

  alias Commonplace.Presence.Mailbox

  describe "log_uuid_for_identity/1" do
    test "is deterministic for the same identity_uuid" do
      id = "550e8400-e29b-41d4-a716-446655440000"
      assert Mailbox.log_uuid_for_identity(id) == Mailbox.log_uuid_for_identity(id)
    end

    test "differs across identity_uuids" do
      a = Mailbox.log_uuid_for_identity("550e8400-e29b-41d4-a716-446655440000")
      b = Mailbox.log_uuid_for_identity("550e8400-e29b-41d4-a716-446655440001")
      refute a == b
    end

    test "is distinct from the identity_uuid itself" do
      id = "550e8400-e29b-41d4-a716-446655440000"
      refute Mailbox.log_uuid_for_identity(id) == id
    end

    test "returns a well-formed UUID string" do
      result = Mailbox.log_uuid_for_identity("550e8400-e29b-41d4-a716-446655440000")
      assert is_binary(result)
      assert String.length(result) == 36

      assert Regex.match?(
               ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/,
               result
             )
    end
  end

  describe "topic_for_name/1" do
    test "produces a path-style magenta topic under 'agents/'" do
      assert Mailbox.topic_for_name("bartleby") == "agents/bartleby"
    end

    test "preserves slashes and hyphens in agent names" do
      assert Mailbox.topic_for_name("claude-code-001") == "agents/claude-code-001"
    end
  end
end
