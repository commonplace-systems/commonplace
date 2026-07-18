defmodule Commonplace.Bd.SchemasIssueFieldsTest do
  @moduledoc """
  Slice S1 Part 1 — round-trip coverage for the fields promoted out of
  `extra` onto `Schemas.Issue`: `needs`, `done_when`, `done_witness`,
  `claimed_by`, `legacy_id`. Defaults must be byte-compatible with
  legacy JSON blobs that predate these fields.
  """
  use ExUnit.Case, async: true

  alias Commonplace.Bd.Schemas
  alias Commonplace.Bd.Schemas.Issue

  test "encode/decode round-trips the new first-class fields" do
    issue = %Issue{
      id: "CX-1",
      title: "t",
      needs: [%{"ticket" => "CX-2"}, %{"ticket" => "CX-3", "repo" => "some-root-id"}],
      done_when: "ci_green",
      done_witness: ["deadbeef", "cafe1234"],
      claimed_by: "identity-uuid@pubkeyhex",
      legacy_id: "bd-legacy-42"
    }

    json = Schemas.encode_issue(issue)
    {:ok, decoded} = Schemas.decode_issue(json)

    assert decoded.needs == issue.needs
    assert decoded.done_when == issue.done_when
    assert decoded.done_witness == issue.done_witness
    assert decoded.claimed_by == issue.claimed_by
    assert decoded.legacy_id == issue.legacy_id
    assert decoded.extra == %{}
  end

  test "new fields default correctly and don't land in extra when absent" do
    issue = %Issue{id: "CX-1", title: "t"}

    json = Schemas.encode_issue(issue)
    {:ok, decoded} = Schemas.decode_issue(json)

    assert decoded.needs == []
    assert decoded.done_when == "manual"
    assert decoded.done_witness == []
    assert decoded.claimed_by == nil
    assert decoded.legacy_id == nil
    assert decoded.extra == %{}
  end

  test "a legacy JSON blob lacking the new fields decodes to defaults" do
    legacy_json =
      Jason.encode!(%{
        "id" => "CX-9",
        "title" => "old issue",
        "status" => "open",
        "priority" => "p2",
        "type" => "task",
        "owner" => nil,
        "created_at" => "2026-01-01T00:00:00Z",
        "updated_at" => "2026-01-01T00:00:00Z",
        "closed_at" => nil,
        "closed_reason" => nil,
        "labels" => []
      })

    {:ok, decoded} = Schemas.decode_issue(legacy_json)

    assert decoded.needs == []
    assert decoded.done_when == "manual"
    assert decoded.done_witness == []
    assert decoded.claimed_by == nil
    assert decoded.legacy_id == nil
    assert decoded.extra == %{}
  end
end
