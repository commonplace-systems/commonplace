defmodule Commonplace.Projection.MixedPlaneHistoryRedTest do
  use ExUnit.Case, async: false

  alias Commonplace.Projection.MixedPlaneHistoryFixture

  test "head-only is clean while the same fixture trips at its historical pin" do
    result = MixedPlaneHistoryFixture.contrast()

    assert {:ok, _bytes, _verdict} = result.head_result
    IO.puts("HEAD_SCAN CLEAN commit=#{hex(result.fixture.head_commit_id)}")

    assert [{armed_commit_id, {:unknown, {:mixed_plane, _details}}}] = result.hits
    assert armed_commit_id == result.fixture.armed_commit_id
    IO.puts("PER_COMMIT_SCAN TRIPS commit=#{hex(armed_commit_id)}")
  end

  defp hex(bytes), do: Base.encode16(bytes, case: :lower)
end
