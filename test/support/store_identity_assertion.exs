defmodule Commonplace.Test.StoreIdentityAssertion do
  @moduledoc """
  The one shared form of the restored-store identity assertion.

  Eighteen test files across three apps carried a copy-pasted `on_exit`
  assertion that the app-default CommitStore singleton, after a test
  stopped and restarted it, points at the store the test expects. The
  copies pinned the store's data_dir as a RELATIVE string — which broke
  in two waves (13 files, then the 5 the first sweep's app-scoped
  selector missed) when the relative-path/cwd-split fix
  (`sol/s-snapshot-fresh-s3`, landed at ff071567) made the store expand
  its data_dir at init. This module is the extraction that ends the
  copy-paste population: the intent lives here once.

  The assertion compares the EXPANDED path deliberately: the intent is
  "the restored singleton points at THIS store", not any particular
  string form of the path. Do not weaken it back to string equality on a
  relative form — that reintroduces the assertion the cwd-split fix
  broke, eighteen times.
  """

  import ExUnit.Assertions

  alias Commonplace.Store.CommitStore

  def assert_restored_store!(restored_data_dir) do
    assert CubDB.data_dir(CommitStore.db_handle(CommitStore)) ==
             Path.expand(Path.join(restored_data_dir, "commits"))
  end
end
