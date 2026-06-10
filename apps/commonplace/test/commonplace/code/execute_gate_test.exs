defmodule Commonplace.Code.ExecuteGateTest do
  @moduledoc """
  CX-tdkq.2 (R2, Gate B): `SourceDoc.compile` refuses to compile a code
  doc unless every commit contributing to its state since the trusted
  baseline (genesis, or a trusted snapshot) is signed by an
  `:execute`-holder.

  Head-signature alone is unsound (write-time laundering): the edit flow
  re-encodes FULL state, so a trusted editor's head commit physically
  contains an untrusted contributor's earlier bytes. The contributor-
  chain walk is the soundness floor (design doc §2 Gate B).

  The gate runs on every compile call — including ETS cache hits — so a
  trust-config change (revocation) takes effect immediately for new
  compiles. (Already-running processes are phase 1.5.)
  """
  use ExUnit.Case, async: false

  alias Commonplace.Code.SourceDoc
  alias Commonplace.Crypto.{Signing, SigningContext}
  alias Commonplace.Document.ContentType
  alias Commonplace.Store.{CommitStore, CommitStoreClient}

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_exec_gate_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    Application.put_env(:commonplace, :data_dir, dir)

    sup = Commonplace.Store.CommitStoreSupervisor
    _ = Supervisor.terminate_child(sup, Commonplace.Store.CommitStore)
    _ = Supervisor.delete_child(sup, Commonplace.Store.CommitStore)

    {:ok, _pid} =
      Supervisor.start_child(sup, {Commonplace.Store.CommitStore, data_dir: dir})

    Commonplace.Tree.DocCache.clear()
    SourceDoc.reset_cache()

    {pub, priv} = Signing.generate_keypair()
    identity = "ec1d0000-0000-0000-0000-#{:rand.uniform(999_999_999_999)}"

    ctx = %SigningContext{identity_uuid: identity, private_key: priv, public_key: pub}

    on_exit(fn ->
      Application.delete_env(:commonplace, :trust)
      _ = Supervisor.terminate_child(sup, Commonplace.Store.CommitStore)
      _ = Supervisor.delete_child(sup, Commonplace.Store.CommitStore)
      Application.put_env(:commonplace, :data_dir, "tmp/test_data")

      {:ok, _pid} =
        Supervisor.start_child(sup, {Commonplace.Store.CommitStore, data_dir: "tmp/test_data"})

      Commonplace.Tree.DocCache.clear()
      SourceDoc.reset_cache()
      File.rm_rf!(dir)
    end)

    %{identity: identity, pub: pub, ctx: ctx}
  end

  defp strict!(trusted) do
    Application.put_env(:commonplace, :trust, %{
      accept_unsigned: false,
      trusted_identities: trusted
    })
  end

  defp source(n) do
    """
    defmodule Commonplace.UserCode.ExecGate#{n} do
      def compute(_raw, _ctx), do: :gate_test_#{n}
    end
    """
  end

  defp encode_source_doc(source_string) do
    doc = Yelixer.Doc.new()
    doc = ContentType.create(doc, :text, "_source.ex")
    doc = ContentType.insert_text(doc, 0, source_string)
    Yelixer.Encoding.encode_update(doc)
  end

  # Mint a code doc whose single content commit carries the given
  # signing opts ([] = unsigned via the test env's empty SecretStore).
  defp mint(source_string, opts) do
    uuid = UUID.uuid4()
    update = encode_source_doc(source_string)

    CommitStore.create_chained_commit(
      Commonplace.Store.CommitStore,
      uuid,
      update,
      %{kind: :regular},
      opts
    )

    uuid
  end

  defp append_commit(uuid, source_string, opts) do
    update = encode_source_doc(source_string)

    CommitStore.create_chained_commit(
      Commonplace.Store.CommitStore,
      uuid,
      update,
      %{kind: :regular},
      opts
    )
  end

  test "permissive default: unsigned code doc compiles (status quo)" do
    uuid = mint(source(1), [])
    assert {:ok, mod} = SourceDoc.compile(uuid, CommitStoreClient)
    assert mod.compute(nil, nil) == :gate_test_1
  end

  test "strict: unsigned code doc is refused" do
    strict!(%{})
    uuid = mint(source(2), [])

    assert {:error, {:execution_denied, {:untrusted_contributor, _id, :unsigned}}} =
             SourceDoc.compile(uuid, CommitStoreClient)
  end

  test "strict: fully trusted chain compiles (genesis exempt)",
       %{identity: identity, pub: pub, ctx: ctx} do
    strict!(%{identity => Signing.encode_key(pub)})

    uuid = mint(source(3), signing_context: ctx)
    append_commit(uuid, source(3) <> "# v2\n", signing_context: ctx)

    assert {:ok, mod} = SourceDoc.compile(uuid, CommitStoreClient)
    assert mod.compute(nil, nil) == :gate_test_3
  end

  test "strict: laundering is caught — trusted head, untrusted earlier contributor",
       %{identity: identity, pub: pub, ctx: ctx} do
    strict!(%{identity => Signing.encode_key(pub)})

    # Untrusted (unsigned) contributor lands bytes first…
    uuid = mint(source(4), [])
    # …then a trusted editor re-commits full state under their signature.
    append_commit(uuid, source(4) <> "# trusted edit\n", signing_context: ctx)

    assert {:error, {:execution_denied, {:untrusted_contributor, _id, :unsigned}}} =
             SourceDoc.compile(uuid, CommitStoreClient)
  end

  test "the gate runs on cache hits too: revocation takes effect immediately",
       %{ctx: ctx} do
    # Compile once in permissive mode — module is now in the ETS cache.
    uuid = mint(source(5), signing_context: ctx)
    assert {:ok, _mod} = SourceDoc.compile(uuid, CommitStoreClient)

    # Trust config flips to strict with NO pinned identities (signer
    # revoked). The cached module must not be served.
    strict!(%{})

    assert {:error, {:execution_denied, _}} = SourceDoc.compile(uuid, CommitStoreClient)
  end

  test "emits [:commonplace, :code, :rejected, :trust] telemetry on denial" do
    strict!(%{})
    uuid = mint(source(6), [])

    ref = make_ref()
    parent = self()

    :telemetry.attach(
      {:exec_gate_handler, ref},
      [:commonplace, :code, :rejected, :trust],
      fn _event, _meas, meta, _cfg -> send(parent, {:exec_rejected, ref, meta}) end,
      nil
    )

    assert {:error, {:execution_denied, _}} = SourceDoc.compile(uuid, CommitStoreClient)

    assert_receive {:exec_rejected, ^ref, meta}, 500
    assert meta.doc_uuid == uuid

    :telemetry.detach({:exec_gate_handler, ref})
  end
end
