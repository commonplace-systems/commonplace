defmodule Commonplace.Tree.Schema do
  @moduledoc """
  Directory document schema — a YMap listing children UUIDs.

  Schema documents define the tree structure. Each directory doc
  has a "entries" YMap where keys are names and values are child UUIDs.
  """

  @schema_type "entries"

  def schema_type, do: @schema_type
end
