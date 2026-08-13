defmodule Commonplace.Runner.PodHandle do
  @moduledoc """
  Opaque handle for one runner pod launched for CX-n6zc.

  Reaping presents the unforgeable `ref` to the launcher that captured the
  bubblewrap port. `scope_pid` is the captured outer bubblewrap PID and is
  diagnostic evidence only; callers never rediscover a pod by a process name,
  argv substring, or pid scan.
  """

  @enforce_keys [:launcher, :ref, :scope_pid, :pod_home]
  defstruct [:launcher, :ref, :scope_pid, :pod_home]

  @type t :: %__MODULE__{
          launcher: GenServer.server(),
          ref: reference(),
          scope_pid: pos_integer(),
          pod_home: Path.t()
        }
end
