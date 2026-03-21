defmodule Commonplace.Tree.Reachability do
  @moduledoc """
  Walk the document tree from root to determine liveness.

  A UUID is live iff it is reachable from the server's root tree.
  Unreachable documents can be garbage collected.
  """
end
