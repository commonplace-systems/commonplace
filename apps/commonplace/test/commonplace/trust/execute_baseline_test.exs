defmodule Commonplace.Trust.ExecuteBaselineTest do
  @moduledoc """
  CX-tdkq.27: the execute-clean Gate-B walk. A node-signed snapshot must NOT
  launder un-:execute-authorized contributions into the execute baseline. The
  store is append-only, so the walk CONTINUES past an un-clean/uncached snapshot
  and re-checks the still-present absorbed history (closing the laundering path
  without bricking legacy snapshots); a local watermark cache (keyed by trust-config
  fingerprint) lets a known-clean snapshot halt the walk early.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Crypto.{Signing, SigningContext}
  alias Commonplace.Document.ContentType
  alias Commonplace.Store.CommitStore
  alias Commonplace.Trust

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_exec_baseline_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    name = :"exec_baseline_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: name})
    on_exit(fn -> File.rm_rf!(dir) end)

    {tpub, tpriv} = Signing.generate_keypair()
    tid = "trusted-#{:rand.uniform(999_999_999)}"
    tctx = %SigningContext{identity_uuid: tid, private_key: tpriv, public_key: tpub}

    {upub, upriv} = Signing.generate_keypair()
    uid = "untrusted-#{:rand.uniform(999_999_999)}"
    uctx = %SigningContext{identity_uuid: uid, private_key: upriv, public_key: upub}

    strict = %{accept_unsigned: false, trusted_identities: %{tid => Signing.encode_key(tpub)}}

    %{store: name, tctx: tctx, uctx: uctx, strict: strict, fp: :erlang.phash2(strict.trusted_identities)}
  end

  defp put(store, uuid, body, metadata, ctx) do
    doc = Yelixer.Doc.new() |> ContentType.create(:text, "code.ex")
    doc = ContentType.insert_text(doc, 0, body)
    update = Yelixer.Encoding.encode_update(doc)
    CommitStore.create_chained_commit(store, uuid, update, metadata, signing_context: ctx)
  end

  defp snapshot_id(store, uuid) do
    {:ok, latest} = CommitStore.latest_commit(store, uuid)
    latest.id
  end

  # A synchronous call barriers the fire-and-forget put_execute_clean cast.
  defp barrier(store), do: :sys.get_state(store)

  test "laundering CLOSED: walk continues past a trusted snapshot and catches the untrusted contributor below",
       %{store: s, tctx: t, uctx: u, strict: cfg} do
    uuid = UUID.uuid4()
    put(s, uuid, "defmodule Laundered do\nend", %{kind: :regular}, u)
    put(s, uuid, "defmodule Laundered do\n  def a, do: 1\nend", %{kind: :snapshot}, t)

    assert {:error, {:untrusted_contributor, _, _}} = Trust.authorized_to_execute?(s, uuid, cfg)
  end

  test "no bricking: a clean chain under an unstamped snapshot still passes",
       %{store: s, tctx: t, strict: cfg} do
    uuid = UUID.uuid4()
    put(s, uuid, "defmodule Clean do\nend", %{kind: :regular}, t)
    put(s, uuid, "defmodule Clean do\n  def a, do: 1\nend", %{kind: :snapshot}, t)

    assert :ok = Trust.authorized_to_execute?(s, uuid, cfg)
  end

  test "a clean walk backfills the snapshot true; a second walk halts at the cached snapshot",
       %{store: s, tctx: t, strict: cfg, fp: fp} do
    uuid = UUID.uuid4()
    put(s, uuid, "defmodule Clean do\nend", %{kind: :regular}, t)
    put(s, uuid, "defmodule Clean do\n  def a, do: 1\nend", %{kind: :snapshot}, t)
    snap = snapshot_id(s, uuid)

    assert :ok = Trust.authorized_to_execute?(s, uuid, cfg)
    barrier(s)
    assert {:ok, true} = CommitStore.get_execute_clean(s, fp, snap)

    assert :ok = Trust.authorized_to_execute?(s, uuid, cfg)
  end

  test "a denied walk backfills the passed snapshot false",
       %{store: s, tctx: t, uctx: u, strict: cfg, fp: fp} do
    uuid = UUID.uuid4()
    put(s, uuid, "defmodule Laundered do\nend", %{kind: :regular}, u)
    put(s, uuid, "defmodule Laundered do\n  def a, do: 1\nend", %{kind: :snapshot}, t)
    snap = snapshot_id(s, uuid)

    assert {:error, _} = Trust.authorized_to_execute?(s, uuid, cfg)
    barrier(s)
    assert {:ok, false} = CommitStore.get_execute_clean(s, fp, snap)
  end

  test "permissive fast-path returns :ok and writes no cache",
       %{store: s, uctx: u} do
    uuid = UUID.uuid4()
    put(s, uuid, "defmodule Whatever do\nend", %{kind: :regular}, u)
    put(s, uuid, "defmodule Whatever do\n  def a, do: 1\nend", %{kind: :snapshot}, u)
    snap = snapshot_id(s, uuid)

    permissive = %{accept_unsigned: true, trusted_identities: %{}}
    assert :ok = Trust.authorized_to_execute?(s, uuid, permissive)
    barrier(s)
    assert :miss = CommitStore.get_execute_clean(s, :erlang.phash2(%{}), snap)
  end
end
