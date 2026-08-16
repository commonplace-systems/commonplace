defmodule Commonplace.Cell.LaunchActTest do
  use ExUnit.Case, async: true

  alias Commonplace.Cell.LaunchAct
  alias Commonplace.Runner.ExecutorProfile

  test "a caller-supplied profile struct is refused by name" do
    assert {:ok, profile} = ExecutorProfile.select("tmux-workerclaude")

    assert {:refuse, {:caller_supplied_executor_profile, "tmux-workerclaude"}} =
             LaunchAct.perform(profile, :launch_capability, :explicit_instantiate, fake_seam())
  end

  test "a well-formed caller-supplied profile is never used" do
    assert {:ok, profile} = ExecutorProfile.select("tmux-workerclaude")

    refute launchward?(
             LaunchAct.perform(
               profile,
               :launch_capability,
               {:absence, :occupant_exit_observed},
               fake_seam()
             )
           )

    refute_received {:instantiator_called, _instruction}
  end

  test "a profile name outside the act's closed set is refused by name" do
    assert {:refuse, {:executor_profile_not_launchable, "future-instantiator"}} =
             LaunchAct.perform(
               "future-instantiator",
               :launch_capability,
               :explicit_instantiate,
               fake_seam()
             )
  end

  test "an unimplemented selected profile never reaches the instantiator seam" do
    assert {:ok, %ExecutorProfile{name: "pod"}} = ExecutorProfile.select("pod")
    assert LaunchAct.profile_names() == ["tmux-workerclaude"]

    result =
      LaunchAct.perform("pod", :launch_capability, :explicit_instantiate, fake_seam())

    assert result == {:refuse, {:executor_profile_not_launchable, "pod"}}
    refute launchward?(result)
    refute_received {:instantiator_called, _instruction}
  end

  test "absence alone is refused by name" do
    assert {:refuse, {:launch_evidence_required, :absence}} =
             LaunchAct.perform(
               "tmux-workerclaude",
               :launch_capability,
               :absence,
               fake_seam()
             )

    refute_received {:instantiator_called, _instruction}
  end

  test "a launch-ward outcome requires evidence or an explicit human instantiate" do
    detector_result =
      LaunchAct.perform(
        "tmux-workerclaude",
        :detector,
        {:absence, :occupant_exit_observed},
        fake_seam()
      )

    absence_result =
      LaunchAct.perform(
        "tmux-workerclaude",
        :launch_capability,
        :absence,
        fake_seam()
      )

    unknown_authority_result =
      LaunchAct.perform(
        "tmux-workerclaude",
        :future_authority,
        {:absence, :occupant_exit_observed},
        fake_seam()
      )

    unknown_evidence_result =
      LaunchAct.perform(
        "tmux-workerclaude",
        :launch_capability,
        :future_evidence,
        fake_seam()
      )

    assert detector_result == {:refuse, {:launch_authority_required, :detector}}

    assert unknown_authority_result ==
             {:refuse, {:launch_authority_required, :future_authority}}

    assert unknown_evidence_result ==
             {:refuse, {:launch_evidence_unrecognized, :future_evidence}}

    refute launchward?(detector_result)
    refute launchward?(absence_result)
    refute launchward?(unknown_authority_result)
    refute launchward?(unknown_evidence_result)
    refute_received {:instantiator_called, _instruction}

    assert {:launched, %{profile: %ExecutorProfile{name: "tmux-workerclaude"}}} =
             LaunchAct.perform(
               "tmux-workerclaude",
               :launch_capability,
               {:absence, :occupant_exit_observed},
               fake_seam()
             )

    assert_received {:instantiator_called,
                     %{
                       profile: %ExecutorProfile{name: "tmux-workerclaude"},
                       reason: {:absence, :occupant_exit_observed}
                     }}

    assert {:launched, %{reason: :explicit_instantiate}} =
             LaunchAct.perform(
               "tmux-workerclaude",
               :human,
               :explicit_instantiate,
               fake_seam()
             )
  end

  defp fake_seam do
    test_process = self()

    fn instruction ->
      send(test_process, {:instantiator_called, instruction})
      {:launched, instruction}
    end
  end

  defp launchward?({:launched, _instruction}), do: true
  defp launchward?({:refuse, {_reason, _name}}), do: false
end
