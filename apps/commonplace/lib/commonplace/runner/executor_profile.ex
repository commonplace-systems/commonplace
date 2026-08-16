defmodule Commonplace.Runner.ExecutorProfile do
  @moduledoc """
  Repository-owned meanings for launching an executor.

  The governance boundary is this module: complete profile values are literals
  in repository code, not freely editable documents. An editable declaration
  can select one of them by name through `ExecutorProfileDeclaration`; it
  cannot restate an instantiator or any safety behavior.

  Profiles declare an instantiator kind, the required `oom_score_adj`, the
  failure-domain boundary, and the receipt policy. They do not implement an
  instantiator and this module never launches, starts, spawns, writes, retries,
  or sleeps.

  ## Repository-ownership is a DECLARED STOPGAP, not the destination

  Repository-ownership makes the governance question "who can merge to main",
  which is a *second authority system* standing beside the capability certs this
  project already uses. That is the second-trust-root shape, and it is not where
  this is going.

  The destination is: editing a profile is free, and *activation* is gated — an
  instantiator may only use a **ratified, pinned profile revision**, checked
  through the capability system rather than through repository access. Editing a
  profile would then grant nothing, because an unratified edit is not
  selectable.

  It ships repository-owned today for one measured reason: there is no general
  ratification machinery yet. The eviction ceremony has a bespoke one and the
  topology work needs one; neither is a mechanism this module can call. When
  that machinery exists, selection moves to a pinned ratified revision and this
  section goes away.

  The property that must hold either way, and does hold here: **a profile
  carries no authority to change itself or to select another profile.** Without
  it, the stopgap and the destination would differ only in who edits, and the
  escalation path would survive the migration.
  """

  @enforce_keys [
    :name,
    :instantiator,
    :oom_score_adj,
    :failure_domain,
    :receipts
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          name: String.t(),
          instantiator: :tmux_workerclaude | :pod,
          oom_score_adj: integer(),
          failure_domain: :tmux_session | :pod,
          receipts: :required
        }

  @profile_values %{
    "tmux-workerclaude" => %{
      name: "tmux-workerclaude",
      instantiator: :tmux_workerclaude,
      oom_score_adj: 500,
      failure_domain: :tmux_session,
      receipts: :required
    },
    "pod" => %{
      name: "pod",
      instantiator: :pod,
      oom_score_adj: 500,
      failure_domain: :pod,
      receipts: :required
    }
  }

  @doc "Select a repository-owned profile by its exact name."
  @spec select(String.t()) :: {:ok, t()} | {:error, term()}
  def select(name) when is_binary(name) do
    case Map.fetch(@profile_values, name) do
      {:ok, profile_value} -> {:ok, struct!(__MODULE__, profile_value)}
      :error -> {:error, {:unknown_executor_profile, name}}
    end
  end
end
