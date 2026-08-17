defmodule Commonplace.Runner.PodProfileTest do
  use ExUnit.Case, async: true

  alias Commonplace.Runner.PodProfile

  @valid_document %{
    "id" => "runner-west-1",
    "harness" => "commonplace-runner-v1",
    "sandbox" => "beam-isolate",
    "services" => %{"postgres" => "16.2"}
  }

  describe "decode/1 and validate/1" do
    test "decodes the ruled vessel-inventory field set" do
      assert {:ok,
              %PodProfile{
                id: "runner-west-1",
                harness: "commonplace-runner-v1",
                sandbox: "beam-isolate",
                services: %{"postgres" => "16.2"}
              }} = PodProfile.decode(Jason.encode!(@valid_document))
    end

    # The network posture is a CLOSED SET, never a boolean, and the profile -- not
    # the launch caller -- selects it. Three arms: absent normalizes to the strictest
    # posture explicitly (no consumer ever reasons about a missing key); a member of
    # the set decodes; a non-member is REFUSED AT VALIDATION with the set named --
    # so a posture the provisioner cannot build dies at decode, not at launch.
    test "absent network normalizes to the explicit strictest posture" do
      assert {:ok, %PodProfile{network: "none"}} =
               PodProfile.decode(Jason.encode!(@valid_document))
    end

    test "a declared member of the posture set decodes" do
      document = Map.put(@valid_document, "network", "none")
      assert {:ok, %PodProfile{network: "none"}} = PodProfile.decode(Jason.encode!(document))
    end

    test "a posture outside the closed set is refused with the set named" do
      # "mediator-socket" is the RULED next member; it is refused today because the
      # mechanism that would enforce it does not exist yet. When that mechanism lands,
      # this test changes DELIBERATELY, in the same commit.
      document = Map.put(@valid_document, "network", "mediator-socket")

      assert {:error, {:invalid_profile, "network", reason}} =
               PodProfile.decode(Jason.encode!(document))

      assert reason =~ ~s(["none"])
      assert reason =~ "mediator-socket"
    end

    test "a boolean network posture is refused, not coerced" do
      document = Map.put(@valid_document, "network", true)

      assert {:error, {:invalid_profile, "network", _reason}} =
               PodProfile.decode(Jason.encode!(document))
    end

    test "invalid JSON is refused as a decode error" do
      assert {:error, reason} = PodProfile.decode("{not-json")
      assert reason =~ "pod profile document"
    end

    for field <- ~w(id harness sandbox services) do
      test "missing #{field} is refused with the field named" do
        field = unquote(field)

        assert {:error, {:invalid_profile, ^field, "is required"}} =
                 PodProfile.validate(Map.delete(@valid_document, field))
      end
    end

    test "id type refusal names id" do
      assert {:error, {:invalid_profile, "id", _reason}} =
               PodProfile.validate(%{@valid_document | "id" => 123})
    end

    test "harness type refusal names harness" do
      assert {:error, {:invalid_profile, "harness", _reason}} =
               PodProfile.validate(%{@valid_document | "harness" => nil})
    end

    test "sandbox type refusal names sandbox" do
      assert {:error, {:invalid_profile, "sandbox", _reason}} =
               PodProfile.validate(%{@valid_document | "sandbox" => []})
    end

    test "services type refusal names services" do
      assert {:error, {:invalid_profile, "services", _reason}} =
               PodProfile.validate(%{@valid_document | "services" => []})
    end

    test "invalid service inventory entry names services" do
      document = %{@valid_document | "services" => %{"postgres" => 16}}

      assert {:error, {:invalid_profile, "services", _reason}} =
               PodProfile.validate(document)
    end
  end

  describe "match_requires/2" do
    test "acceptance pair: postgres >=14 is satisfied by inventory version 16.2" do
      assert :ok = PodProfile.match_requires(%{"postgres" => ">=14"}, profile("16.2"))
    end

    test "acceptance pair: postgres >=14 is refused by inventory version 13.1" do
      assert {:refused, ["this placement cannot satisfy requirement postgres >=14"]} =
               PodProfile.match_requires(%{"postgres" => ">=14"}, profile("13.1"))
    end

    test "missing required service is refused with service and requirement named" do
      assert {:refused, ["this placement cannot satisfy requirement postgres >=14"]} =
               PodProfile.match_requires(%{"postgres" => ">=14"}, profile(%{}))
    end

    test "unparseable requirement is refused and never treated as unconstrained" do
      assert {:refused, ["this placement cannot satisfy requirement postgres eventually"]} =
               PodProfile.match_requires(%{"postgres" => "eventually"}, profile("16.2"))
    end

    test "unparseable inventory entry is refused" do
      assert {:refused, ["this placement cannot satisfy requirement postgres >=14"]} =
               PodProfile.match_requires(%{"postgres" => ">=14"}, profile("sixteen"))
    end

    test "all unsatisfied requirements are reported in stable service-name order" do
      requires = %{"redis" => ">=7", "postgres" => ">=14"}
      profile = profile(%{"postgres" => "13.1", "redis" => "6.2"})

      assert {:refused,
              [
                "this placement cannot satisfy requirement postgres >=14",
                "this placement cannot satisfy requirement redis >=7"
              ]} = PodProfile.match_requires(requires, profile)
    end

    test "empty requires matches an empty profile" do
      assert :ok = PodProfile.match_requires(%{}, profile(%{}))
    end
  end

  defp profile(services) when is_map(services) do
    %PodProfile{
      id: "runner-west-1",
      harness: "commonplace-runner-v1",
      sandbox: "beam-isolate",
      services: services
    }
  end

  defp profile(postgres_version), do: profile(%{"postgres" => postgres_version})
end
