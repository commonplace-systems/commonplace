defmodule Commonplace.Cell.LaunchAct do
  @moduledoc """
  Decides whether one governed executor launch instruction may reach an instantiator.

  The caller supplies an executor profile name, never a profile value. This
  module first bounds that name to the act's closed implementation set and then
  consumes the repository-owned value through `ExecutorProfile.select/1`.

  Authority and launch evidence are independent gates. Detecting an absent
  occupant is not launch authority, and absence without evidence is not a
  launch reason. The final function argument is an injectable instantiator seam;
  this module itself starts no process.
  """

  alias Commonplace.Runner.ExecutorProfile

  @profile_names %{"tmux-workerclaude" => :tmux_workerclaude}
  @resolved_profiles %{{"tmux-workerclaude", :tmux_workerclaude} => :authorized}

  @authority_decisions %{
    launch_capability: :authorized,
    human: :authorized,
    detector: {:refuse, {:launch_authority_required, :detector}}
  }

  @evidence_decisions %{
    {:absence, :occupant_exit_observed} => :authorized,
    :explicit_instantiate => :authorized,
    :absence => {:refuse, {:launch_evidence_required, :absence}}
  }

  @type authority :: :launch_capability | :human | atom()
  @type reason :: {:absence, :occupant_exit_observed} | :explicit_instantiate | atom()
  @type refusal :: {:refuse, {atom(), term()}}
  @type instruction :: %{profile: ExecutorProfile.t(), reason: reason()}
  @type instantiator :: (instruction() -> term())

  @doc "Return the closed set of profile names this act can instantiate."
  @spec profile_names() :: [String.t()]
  def profile_names, do: Map.keys(@profile_names)

  @doc """
  Gate one launch decision and send an authorized instruction to `instantiator`.

  A profile struct in the name position is explicitly refused and never used.
  """
  @spec perform(String.t(), authority(), reason(), instantiator()) :: term() | refusal()
  def perform(%ExecutorProfile{name: name}, _authority, _reason, _instantiator) do
    {:refuse, {:caller_supplied_executor_profile, name}}
  end

  def perform(profile_name, authority, reason, instantiator)
      when is_binary(profile_name) and is_function(instantiator, 1) do
    with :ok <- authorize(authority),
         :ok <- require_evidence(reason),
         {:ok, profile} <- resolve_profile(profile_name) do
      instantiator.(%{profile: profile, reason: reason})
    end
  end

  defp authorize(authority) do
    @authority_decisions
    |> Map.fetch(authority)
    |> authority_result(authority)
  end

  defp authority_result({:ok, :authorized}, _authority), do: :ok
  defp authority_result({:ok, {:refuse, reason}}, _authority), do: {:refuse, reason}

  defp authority_result(:error, authority),
    do: {:refuse, {:launch_authority_required, authority}}

  defp require_evidence(reason) do
    @evidence_decisions
    |> Map.fetch(reason)
    |> evidence_result(reason)
  end

  defp evidence_result({:ok, :authorized}, _reason), do: :ok
  defp evidence_result({:ok, {:refuse, refusal}}, _reason), do: {:refuse, refusal}
  defp evidence_result(:error, reason), do: {:refuse, {:launch_evidence_unrecognized, reason}}

  defp resolve_profile(profile_name) do
    @profile_names
    |> Map.fetch(profile_name)
    |> closed_profile_result(profile_name)
  end

  defp closed_profile_result(:error, profile_name) do
    {:refuse, {:executor_profile_not_launchable, profile_name}}
  end

  defp closed_profile_result({:ok, expected_instantiator}, profile_name) do
    profile_name
    |> ExecutorProfile.select()
    |> selected_profile_result(profile_name, expected_instantiator)
  end

  defp selected_profile_result(
         {:ok, %ExecutorProfile{} = profile},
         profile_name,
         expected_instantiator
       ) do
    @resolved_profiles
    |> Map.fetch({profile.name, profile.instantiator})
    |> resolved_profile_result(profile, profile_name, expected_instantiator)
  end

  defp selected_profile_result({:error, reason}, _profile_name, _expected_instantiator) do
    {:refuse, {:executor_profile_resolution_failed, reason}}
  end

  defp resolved_profile_result(
         {:ok, :authorized},
         %ExecutorProfile{} = profile,
         profile_name,
         expected_instantiator
       )
       when profile.name == profile_name and profile.instantiator == expected_instantiator do
    {:ok, profile}
  end

  defp resolved_profile_result(:error, _profile, profile_name, expected_instantiator) do
    {:refuse, {:executor_profile_instantiator_mismatch, profile_name, expected_instantiator}}
  end
end
