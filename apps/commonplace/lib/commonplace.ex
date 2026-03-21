defmodule Commonplace do
  @moduledoc """
  CRDT document store built on BEAM primitives.

  Documents are Yjs CRDTs (via Yelixer) managed by GenServers,
  coordinated through Phoenix PubSub, and persisted as a
  Merkle DAG of commits in CubDB.
  """
end
