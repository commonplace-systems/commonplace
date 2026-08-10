defmodule Commonplace.TrustConfigFailClosedTest do
  @moduledoc """
  Move #2 Task 0 (CX-tdkq.12, decision O6): trust-config loading must
  fail CLOSED, not open.

  ABSENT trust.json → the permissive default (the intended zero-config
  story). PRESENT-but-corrupt trust.json → reject-all: a strict
  workspace whose config file gets a partial write or bad hand-edit
  must NOT silently degrade to fully-permissive — with an on-boot
  orchestrator that degradation is auto-RCE.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Store.CommitStore
  alias Commonplace.Test.WorkspaceFixture
  alias Commonplace.Trust

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_failclosed_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    prior_data_dir = Application.get_env(:commonplace, :data_dir)
    Application.put_env(:commonplace, :data_dir, dir)
    # config/0 prefers app env over the file — clear it for these tests.
    prior_trust = Application.get_env(:commonplace, :trust)
    Application.delete_env(:commonplace, :trust)

    store = Module.concat(__MODULE__, Store)
    start_supervised!({CommitStore, data_dir: dir, name: store})
    WorkspaceFixture.complete_workspace!(dir, store: store)

    on_exit(fn ->
      Application.put_env(:commonplace, :data_dir, prior_data_dir || "tmp/test_data")
      if prior_trust, do: Application.put_env(:commonplace, :trust, prior_trust)
      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  test "absent trust.json → permissive default (zero-config story intact)" do
    cfg = Trust.config()
    assert cfg.accept_unsigned == true
  end

  test "corrupt trust.json → fail CLOSED: strict with zero pins", %{dir: dir} do
    File.write!(Path.join(dir, "trust.json"), "{this is not json")

    cfg = Trust.config()

    assert cfg.accept_unsigned == false
    # Node auto-trust still folds in (system commits keep working) but
    # NOTHING from the corrupt file — and no other identity is trusted.
    {:ok, node_identity} = Commonplace.Crypto.NodeIdentity.identity()
    assert Map.keys(cfg.trusted_identities) == [node_identity]
  end

  test "unreadable trust.json (a directory) also fails closed", %{dir: dir} do
    File.mkdir_p!(Path.join(dir, "trust.json"))

    cfg = Trust.config()
    assert cfg.accept_unsigned == false
  end

  test "valid strict trust.json parses as before", %{dir: dir} do
    File.write!(
      Path.join(dir, "trust.json"),
      Jason.encode!(%{accept_unsigned: false, trusted_identities: %{"alice" => "QUJD"}})
    )

    cfg = Trust.config()
    assert cfg.accept_unsigned == false
    assert cfg.trusted_identities["alice"] == "QUJD"
  end
end
