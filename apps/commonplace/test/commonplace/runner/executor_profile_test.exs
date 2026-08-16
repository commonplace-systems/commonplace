defmodule Commonplace.Runner.ExecutorProfileTest do
  use ExUnit.Case, async: true

  alias Commonplace.Runner.{ExecutorProfile, ExecutorProfileDeclaration}

  @valid_declaration %{"profile" => "tmux-workerclaude"}

  test "the one-field declaration validates and round-trips" do
    assert :ok = ExecutorProfileDeclaration.validate(@valid_declaration)
    assert {:ok, encoded} = ExecutorProfileDeclaration.encode(@valid_declaration)

    assert {:ok, %ExecutorProfileDeclaration{profile: "tmux-workerclaude"}} =
             ExecutorProfileDeclaration.decode(encoded)

    assert {:ok, %ExecutorProfile{name: "tmux-workerclaude"}} =
             ExecutorProfileDeclaration.resolve(@valid_declaration)
  end

  test "a missing profile is refused with profile named" do
    assert {:error, {:invalid_executor_profile_declaration, "profile", "is required"}} =
             ExecutorProfileDeclaration.validate(%{})
  end

  test "an unknown declaration field is refused with the field named" do
    assert {:error,
            {:invalid_executor_profile_declaration, "future_field", "is not a recognized field"}} =
             ExecutorProfileDeclaration.validate(%{
               "profile" => "tmux-workerclaude",
               "future_field" => "future-value"
             })
  end

  for execution_field <- ~w(recipe command exec) do
    test "the #{execution_field} field is refused with its name" do
      execution_field = unquote(execution_field)

      assert {:error,
              {:invalid_executor_profile_declaration, ^execution_field,
               "is not a recognized field"}} =
               ExecutorProfileDeclaration.validate(
                 Map.put(@valid_declaration, execution_field, "DO-NOT-INTERPRET")
               )
    end
  end

  test "execution-bearing fields never reach profile selection or pass through" do
    parent = self()

    selector = fn value ->
      send(parent, {:selector_received, value})
      {:ok, :permissive_outcome}
    end

    for execution_field <- ~w(recipe command exec) do
      declaration = Map.put(@valid_declaration, execution_field, "DO-NOT-INTERPRET")

      assert {:error,
              {:invalid_executor_profile_declaration, ^execution_field,
               "is not a recognized field"}} =
               ExecutorProfileDeclaration.resolve(declaration, selector)
    end

    refute_received {:selector_received, _value}
  end

  test "tmux plus workerclaude is a governed profile value" do
    assert {:ok,
            %ExecutorProfile{
              name: "tmux-workerclaude",
              instantiator: :tmux_workerclaude,
              oom_score_adj: 500,
              failure_domain: :tmux_session,
              receipts: :required
            }} = ExecutorProfile.select("tmux-workerclaude")
  end

  test "a pod is a governed profile value" do
    assert {:ok,
            %ExecutorProfile{
              name: "pod",
              instantiator: :pod,
              oom_score_adj: 500,
              failure_domain: :pod,
              receipts: :required
            }} = ExecutorProfile.select("pod")
  end

  test "an unknown profile is refused with its name" do
    assert {:error, {:unknown_executor_profile, "future-instantiator"}} =
             ExecutorProfile.select("future-instantiator")
  end
end
