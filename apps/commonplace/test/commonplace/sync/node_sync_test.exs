defmodule Commonplace.Sync.NodeSyncTest do
  use ExUnit.Case, async: true

  alias Commonplace.Sync.NodeSync

  test "diff_commit_ids returns missing IDs in each direction" do
    local = MapSet.new(["a", "b", "c"])
    remote = MapSet.new(["b", "c", "d"])

    assert {missing_local, missing_remote} = NodeSync.diff_commit_ids(local, remote)
    assert missing_local == MapSet.new(["d"])
    assert missing_remote == MapSet.new(["a"])
  end

  test "diff_commit_ids with identical sets returns empty" do
    ids = MapSet.new(["a", "b"])
    {missing_local, missing_remote} = NodeSync.diff_commit_ids(ids, ids)
    assert missing_local == MapSet.new()
    assert missing_remote == MapSet.new()
  end

  test "diff_commit_ids with empty local returns all remote as missing" do
    remote = MapSet.new(["a", "b"])
    {missing_local, missing_remote} = NodeSync.diff_commit_ids(MapSet.new(), remote)
    assert missing_local == remote
    assert missing_remote == MapSet.new()
  end
end
