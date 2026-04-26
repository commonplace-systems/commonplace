defmodule Commonplace.Chat.ChatViewComputeTest do
  @moduledoc """
  CX-7kl3 (sub-bead ii of CX-04d8 M3): tests for the chat-tier
  ViewCompute spec — the chain rules + compute_fn that ViewCompute
  invokes on each `_messages` commit.

  Chain rules lift from `Chat.Messages.@chain_rules` (M2 home) to
  `ChatViewCompute.chain_rules()` here. Same M2 substrate primitive
  consumes them; this just relocates them out of the data-shape
  module and into the compute spec module — substrate-pure direction.
  """
  use ExUnit.Case, async: true

  alias Commonplace.Chat.ChatViewCompute
  alias Commonplace.Document.ViewXml

  describe "chain_rules/0" do
    test "returns the M2 config-map shape with edit_of + tombstone_of chains" do
      rules = ChatViewCompute.chain_rules()

      assert %{chains: chains} = rules
      assert is_list(chains)

      fields = Enum.map(chains, & &1.field) |> MapSet.new()
      assert MapSet.member?(fields, "edit_of")
      assert MapSet.member?(fields, "tombstone_of")

      semantics = Map.new(chains, fn rule -> {rule.field, rule.semantics} end)
      assert semantics["edit_of"] == :latest_replaces
      assert semantics["tombstone_of"] == :marks_deleted
    end
  end

  describe "compute_fn/1" do
    test "produces parseable view-XML from a list of JSON-encoded entries" do
      entries = [
        Jason.encode!(%{
          "id" => "msg-1",
          "ts" => "T0",
          "author_signer_id" => "alice@x",
          "author_path" => "alice.usr",
          "text" => "first"
        })
      ]

      compute = ChatViewCompute.compute_fn("general")
      xml = compute.(entries)

      assert {:ok, %ViewXml.Node{tag: :view}} = ViewXml.parse(xml)
      assert xml =~ "msg-1"
      assert xml =~ "first"
    end

    test "applies edit_of chain (M2 :latest_replaces) — chain tip's text wins" do
      entries = [
        Jason.encode!(%{
          "id" => "m1",
          "ts" => "T0",
          "author_signer_id" => "alice@x",
          "author_path" => "alice.usr",
          "text" => "v1"
        }),
        Jason.encode!(%{
          "id" => "m1-edit",
          "ts" => "T1",
          "author_signer_id" => "alice@x",
          "author_path" => "alice.usr",
          "text" => "v2",
          "edit_of" => "m1"
        })
      ]

      compute = ChatViewCompute.compute_fn("general")
      xml = compute.(entries)

      # Materialized view: original "v1" → tip "v2"
      assert xml =~ "v2", "edit chain tip's text should appear"
      refute xml =~ ">v1<", "original text should be replaced by chain tip"
      assert xml =~ ~s(name="edited" value="true")
    end

    test "applies tombstone_of chain (M2 :marks_deleted) — body becomes [deleted]" do
      entries = [
        Jason.encode!(%{
          "id" => "m1",
          "ts" => "T0",
          "author_signer_id" => "alice@x",
          "author_path" => "alice.usr",
          "text" => "secret"
        }),
        Jason.encode!(%{
          "id" => "m1-del",
          "ts" => "T1",
          "author_signer_id" => "alice@x",
          "author_path" => "alice.usr",
          "tombstone_of" => "m1"
        })
      ]

      compute = ChatViewCompute.compute_fn("general")
      xml = compute.(entries)

      assert xml =~ "[deleted]"
      refute xml =~ ">secret<", "deleted body must not surface original text"
      assert xml =~ ~s(name="deleted" value="true")
    end

    test "empty entries → valid view-XML with no message <entity>s" do
      compute = ChatViewCompute.compute_fn("empty-room")
      xml = compute.([])

      assert {:ok, _} = ViewXml.parse(xml)
      assert xml =~ ~s(name="empty-room")
      refute xml =~ ~s(kind="message")
    end
  end
end
