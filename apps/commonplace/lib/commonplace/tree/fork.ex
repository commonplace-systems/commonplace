defmodule Commonplace.Tree.Fork do
  @moduledoc """
  Deep-copy branch with new UUIDs.

  Fork creates new UUIDs for every doc in a branch, deep-copies Yjs
  state via encode/decode roundtrip, rewrites schema references,
  and stores a ForkManifest document tracking old→new UUID mappings.
  """
end
