defmodule Commonplace.Presence.IdentityConvergenceTest do
  @moduledoc """
  CX-tdkq.1 (R1): identity docs are SHARED multi-writer documents — two
  nodes can concurrently write the same identity doc, producing sibling
  commits (the remote one lands via import_commit, which deliberately
  does not advance :latest). `Identity.read/2` reconstructs from
  :latest only, so the sibling's write was invisible until converged.

  R1 routes identity reads/writes through SiblingMerger so the registry
  converges. (Per the trust-anchor decision, identity-doc keys are a
  convenience lookup, NOT load-bearing for trust — pinned local config
  is — but a registry that silently drops concurrent registrations is
  still a real bug.)
  """
  use ExUnit.Case, async: false

  alias Commonplace.Document.ContentType
  alias Commonplace.Presence.Identity
  alias Commonplace.Store.{Commit, CommitStore}

  setup do
    dir = Path.join(System.tmp_dir!(), "idconv_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    name = :"idconv_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: name})
    on_exit(fn -> File.rm_rf!(dir) end)
    %{store: name}
  end

  test "read converges imported sibling commits into :latest", %{store: store} do
    root_uuid = "root-#{:rand.uniform(1_000_000)}"
    {:ok, uuid} = Identity.register("alice", :bot, root_uuid, store)

    # Capture the parent both writers will chain from.
    {:ok, parent} = CommitStore.latest_commit(store, uuid)

    # Local write: add a public key (chains :latest to L).
    :ok = Identity.add_public_key(uuid, "KEY_LOCAL", store)
    {:ok, local_head} = CommitStore.latest_commit(store, uuid)
    assert local_head.parent_id == parent.id

    # Remote sibling R: another node wrote off the SAME parent and the
    # commit arrived via import (which leaves :latest on L).
    remote_doc = Yelixer.Doc.new(client_id: 424_242)
    {:ok, remote_doc} = Yelixer.Encoding.apply_update(remote_doc, parent.update)
    remote_doc = ContentType.set_key(remote_doc, "remote_marker", "R")
    remote_update = Yelixer.Encoding.encode_update(remote_doc)

    sibling = Commit.new(uuid, remote_update, parent.id, local_head.metadata)
    assert :ok = CommitStore.import_commit(store, sibling)

    # :latest is still L — without convergence the sibling is invisible.
    {:ok, head_before} = CommitStore.latest_commit(store, uuid)
    assert head_before.id == local_head.id

    # Converged read must see BOTH writers' effects.
    content = Identity.read(uuid, store)
    assert content["remote_marker"] == "R"
    assert content["public_keys"] =~ "KEY_LOCAL"
  end

  test "add_public_key converges first, so the write chains off the merged head",
       %{store: store} do
    root_uuid = "root-#{:rand.uniform(1_000_000)}"
    {:ok, uuid} = Identity.register("bob", :bot, root_uuid, store)

    {:ok, parent} = CommitStore.latest_commit(store, uuid)

    # Sibling arrives via import BEFORE the local write happens.
    remote_doc = Yelixer.Doc.new(client_id: 565_656)
    {:ok, remote_doc} = Yelixer.Encoding.apply_update(remote_doc, parent.update)
    remote_doc = ContentType.set_key(remote_doc, "remote_marker", "R")
    remote_update = Yelixer.Encoding.encode_update(remote_doc)

    sibling = Commit.new(uuid, remote_update, parent.id, parent.metadata)
    assert :ok = CommitStore.import_commit(store, sibling)

    # Local write should fold the sibling in rather than racing past it.
    :ok = Identity.add_public_key(uuid, "KEY_LOCAL", store)

    content = Identity.read(uuid, store)
    assert content["remote_marker"] == "R"
    assert content["public_keys"] =~ "KEY_LOCAL"
  end
end
