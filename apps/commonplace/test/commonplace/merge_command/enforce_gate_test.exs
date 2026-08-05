defmodule Commonplace.MergeCommand.EnforceGateTest do
  @moduledoc """
  CX-xxav: the merge command's persist path, under
  `local_write_gate: :enforce` + strict trust.

  `MergeCommand.Handler.persist_commit/3` lands every merge through one
  gated verb, `CommitStore.put_built_commit/4`, whichever way the
  canonical pair sorted. The rejected alternative was a two-arm split
  that routed the linear case through `write_prebuilt_commit_cas/2` —
  which does NOT run the local write gate — and only the non-linear
  case through the gated verb. That split cannot be justified: arm
  selection is a function of canonical sort order, i.e. of which peer
  you are, so the same byte-identical merge would be gated on one peer
  and exempt on the other. See the handler moduledoc's "Why one verb,
  not two".

  These pins exist because every test in `handler_test.exs` runs at the
  default permissive knob, where gating is invisible, while the live
  serve runs Mode-B enforce. CX-cl65 is the banked instance of exactly
  this shape: a permissive suite stayed green across a break that only
  appeared under enforce with a real cert.

  Four pins — land and deny, each in both orientations:

    1. land, NON-LINEAR orientation (head is a merge parent, so
       `expected_parent_id != commit.parent_id`);
    2. land, LINEAR orientation (head is the parent) — same path now,
       but entering with a different expected-parent relationship;
    3. deny, NON-LINEAR orientation;
    4. deny, LINEAR orientation.

  The denial half carries most of the weight: a land-only test is
  equally satisfied by a gate that never denies anything, so pins 1-2
  alone cannot fail on a broken gate. And pin 4 specifically is the one
  that makes the one-verb ruling enforceable — pins 1, 2 and 3 all pass
  under the deleted two-arm split, because that split only exempted the
  LINEAR case from the gate, and an exemption is invisible to a test
  that expects a land.

  All four drive the REAL magenta command path (not `persist_commit/3`
  directly), because the claim is about what the handler advertises,
  which only exists at the reply.

  ## Isolating the merge write

  Fixtures are built with the gate `:off` and the gate is flipped to
  strict + `:enforce` immediately before the merge command is sent —
  the same isolation `LocalWriteGateTest`'s pin 4 uses (sign/exempt the
  base writes so the test trips on the commit under study, not on an
  unrelated unsigned fixture write).

  ## How the negative control is produced

  `Trust.with_local_node_trust/1` auto-trusts the node identity whenever
  the node keypair is sourceable, so "an untrusted node signer" is not
  reachable by configuring `trusted_identities`. It IS reachable by
  making the keypair unsourceable: `CommitBuilder.node_sign_if_system/1`
  leaves the commit UNSIGNED when `NodeIdentity.signing_context/0`
  errors, and strict mode then rejects `:unsigned`. Writing a corrupt
  `node_signing_key` into the workspace `data_dir` does that
  deterministically (`decode_keypair/1` -> `{:error, :corrupt_node_key}`).
  """
  use ExUnit.Case, async: false

  alias Commonplace.Crypto.NodeIdentity
  alias Commonplace.Dataflow.Magenta
  alias Commonplace.Store.{Commit, CommitStore}
  alias Commonplace.Tree.Schema
  alias Yelixer.{Doc, Encoding}
  alias Yelixer.Types.Text

  setup do
    n = :rand.uniform(1_000_000_000)
    dir = Path.join(System.tmp_dir!(), "cp_merge_enforce_#{n}")
    node_dir = Path.join(System.tmp_dir!(), "cp_merge_enforce_node_#{n}")
    File.mkdir_p!(dir)
    File.mkdir_p!(node_dir)

    name = :"mge_store_#{n}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: dir,
       name: :"mge_sup_#{n}",
       commit_store_name: name,
       trust_side_store_name: :"mge_tss_#{n}",
       pending_imports_name: :"mge_pi_#{n}"}
    )

    old_gate = Application.get_env(:commonplace, :local_write_gate)
    old_trust = Application.get_env(:commonplace, :trust)
    old_data_dir = Application.get_env(:commonplace, :data_dir)

    # Own the node identity/keypair for this test so the negative
    # control can corrupt it without touching any other workspace.
    Application.put_env(:commonplace, :data_dir, node_dir)

    on_exit(fn ->
      restore(:local_write_gate, old_gate)
      restore(:trust, old_trust)
      restore(:data_dir, old_data_dir)
      File.rm_rf!(dir)
      File.rm_rf!(node_dir)
    end)

    # Mint the node keypair up front so the positive pin has a real,
    # auto-trusted node signer and the negative pin has a file to break.
    assert {:ok, _node_ctx} = NodeIdentity.signing_context()

    off!()

    root_uuid = "mge-root-#{n}"
    CommitStore.create_commit(name, root_uuid, Encoding.encode_update(Schema.new_schema()), nil)

    handler_name = :"mge_handler_#{n}"

    start_supervised!(
      {Commonplace.MergeCommand.Handler,
       store: name, name: handler_name, root_uuid: root_uuid}
    )

    %{store: name, root: root_uuid, node_dir: node_dir}
  end

  defp restore(key, nil), do: Application.delete_env(:commonplace, key)
  defp restore(key, v), do: Application.put_env(:commonplace, key, v)

  defp off!, do: Application.put_env(:commonplace, :local_write_gate, :off)
  defp enforce!, do: Application.put_env(:commonplace, :local_write_gate, :enforce)

  defp strict! do
    Application.put_env(:commonplace, :trust, %{
      accept_unsigned: false,
      trusted_identities: %{}
    })
  end

  # Snapshot C -> chained L (becomes :latest) + imported sibling R.
  # Same shape as handler_test's `build_l_r`.
  defp build_l_r(store, uuid) do
    {:ok, _genesis} = CommitStore.ensure_genesis(store, uuid)

    doc_c = Doc.new(client_id: 1)
    {doc_c, _} = Doc.get_or_create_type(doc_c, "t", :text)
    doc_c = Text.insert(doc_c, "t", 0, "abc")

    CommitStore.create_chained_commit(store, uuid, Encoding.encode_update(doc_c), %{
      kind: :regular
    })

    {:ok, c_snap} = CommitStore.snapshot(store, uuid)
    {:ok, c_doc} = Encoding.apply_update(Doc.new(), c_snap.update)
    c_update = Encoding.encode_update(c_doc)

    doc_l = Doc.new(client_id: 2)
    {doc_l, _} = Doc.get_or_create_type(doc_l, "t", :text)
    {:ok, doc_l} = Encoding.apply_update(doc_l, c_update)
    doc_l = Text.insert(doc_l, "t", 0, "X")

    l_commit =
      CommitStore.create_chained_commit(store, uuid, Encoding.encode_update(doc_l), %{
        kind: :regular
      })

    doc_r = Doc.new(client_id: 3)
    {doc_r, _} = Doc.get_or_create_type(doc_r, "t", :text)
    {:ok, doc_r} = Encoding.apply_update(doc_r, c_update)
    doc_r = Text.insert(doc_r, "t", 3, "Y")

    r_commit =
      Commit.new(uuid, Encoding.encode_update(doc_r), c_snap.id, %{
        kind: :regular,
        snapshot_parent: c_snap.id
      })

    :ok = CommitStore.import_commit(store, r_commit, validator: fn _ -> :ok end)

    {l_commit, r_commit}
  end

  # Build fixtures until one lands in the requested orientation.
  # `Merger.canonical_pair/2` sorts by id and the merge commit's
  # `parent_id` is canonical-L, so:
  #
  #   :non_linear — local head (`l.id`) sorts SECOND, canonical L is the
  #     sibling, and `expected_parent_id != commit.parent_id`.
  #   :linear — local head sorts FIRST, canonical L is the head, and
  #     `expected_parent_id == commit.parent_id`.
  #
  # Which uuid produces which is a fact about hash bytes, so search
  # rather than hardcode — and assert the search succeeded, so a pin can
  # never silently degrade into re-testing the orientation it is not
  # about.
  defp build_fixture(store, prefix, orientation) do
    found =
      Enum.find_value(1..40, fn i ->
        uuid = "#{prefix}-#{i}"
        {l, r} = build_l_r(store, uuid)

        case orientation do
          :non_linear -> if l.id > r.id, do: {uuid, l, r}
          :linear -> if l.id < r.id, do: {uuid, l, r}
        end
      end)

    assert {_uuid, _l, _r} = found,
           "no fixture produced the #{orientation} orientation in 40 tries"

    found
  end

  defp register_in_root(store, root_uuid, name, uuid) do
    {:ok, root_commit} = CommitStore.latest_commit(store, root_uuid)
    schema = Schema.new_schema()
    {:ok, schema} = Encoding.apply_update(schema, root_commit.update)
    schema = Schema.add_file(schema, name, uuid)

    CommitStore.create_chained_commit(store, root_uuid, Encoding.encode_update(schema))
    name
  end

  defp send_merge(topic, r) do
    Magenta.subscribe(topic)

    Magenta.send(
      topic,
      Magenta.message("merge", "test", %{
        "other_ref" => Base.encode16(r.id, case: :lower),
        "strategy" => "translate"
      })
    )
  end

  describe "the unified persist path under enforce (CX-xxav)" do
    test "non-linear orientation: a node-signed merge clears the gate and becomes the head",
         %{store: store, root: root} do
      {uuid, l, r} = build_fixture(store, "mge-pos-nl", :non_linear)
      path = register_in_root(store, root, "enforce_pos_nl_doc", uuid)
      topic = "commands/#{path}/merge"

      # Everything above was fixture. From here the gate is real.
      strict!()
      enforce!()

      send_merge(topic, r)

      assert_receive {:magenta, ^topic, %Magenta{type: "merge_completed"} = reply}, 2000
      commit_id = Base.decode16!(reply.payload["commit_id"], case: :lower)

      assert {:ok, stored} = CommitStore.get_commit(store, commit_id),
             "advertised commit_id is not in the store under enforce"

      assert stored.metadata[:kind] == :merge

      # Non-linear: the observed head is a MERGE parent, not the parent,
      # so `expected_parent_id != commit.parent_id`.
      assert stored.parent_id == r.id
      assert l.id in stored.merge_parents
      assert stored.signature != nil, "merge commit reached put_built_commit unsigned"

      assert {:ok, %{id: ^commit_id}} = CommitStore.latest_commit(store, uuid),
             "head did not advance to the merge commit under enforce"
    end

    test "linear orientation: same gated verb, and it lands too",
         %{store: store, root: root} do
      {uuid, l, r} = build_fixture(store, "mge-pos-lin", :linear)
      path = register_in_root(store, root, "enforce_pos_lin_doc", uuid)
      topic = "commands/#{path}/merge"

      strict!()
      enforce!()

      send_merge(topic, r)

      assert_receive {:magenta, ^topic, %Magenta{type: "merge_completed"} = reply}, 2000
      commit_id = Base.decode16!(reply.payload["commit_id"], case: :lower)

      assert {:ok, stored} = CommitStore.get_commit(store, commit_id),
             "advertised commit_id is not in the store under enforce"

      assert stored.metadata[:kind] == :merge

      # Linear: the observed head IS the parent — the case the deleted
      # two-arm split would have routed around the gate.
      assert stored.parent_id == l.id
      assert r.id in stored.merge_parents
      assert stored.signature != nil, "merge commit reached put_built_commit unsigned"

      assert {:ok, %{id: ^commit_id}} = CommitStore.latest_commit(store, uuid),
             "head did not advance to the merge commit under enforce"
    end

    test "denial control, NON-LINEAR orientation: merge_failed, no phantom id, nothing landed",
         %{store: store, root: root, node_dir: node_dir} do
      assert_denied(store, root, node_dir, "mge-neg-nl", :non_linear)
    end

    # THE pin that makes the one-verb ruling enforceable. Under the
    # deleted two-arm split the linear case went through
    # `write_prebuilt_commit_cas/2`, which does not run the gate — so
    # this same unsigned merge would have LANDED, ungated, on the peer
    # whose head happened to sort first. The other three pins all pass
    # under that split; only this one goes red on it.
    test "denial control, LINEAR orientation: the gate applies here too",
         %{store: store, root: root, node_dir: node_dir} do
      assert_denied(store, root, node_dir, "mge-neg-lin", :linear)
    end
  end

  defp assert_denied(store, root, node_dir, prefix, orientation) do
    {uuid, l, r} = build_fixture(store, prefix, orientation)
    path = register_in_root(store, root, "#{prefix}_doc", uuid)
    topic = "commands/#{path}/merge"

    {:ok, head_before} = CommitStore.latest_commit(store, uuid)
    assert head_before.id == l.id

    # Break the node keypair so the system-minted merge cannot be
    # node-signed AND the node identity drops out of the trusted set
    # (`Trust.with_local_node_trust/1` sources the same keypair).
    File.write!(Path.join(node_dir, "node_signing_key"), "this is not a keypair\n")
    assert {:error, :corrupt_node_key} = NodeIdentity.signing_context()

    strict!()
    enforce!()

    send_merge(topic, r)

    assert_receive {:magenta, ^topic, %Magenta{type: "merge_failed"} = reply}, 2000
    refute_receive {:magenta, ^topic, %Magenta{type: "merge_completed"}}, 200

    # A denial, not a CAS miss — the reply names the trust rejection.
    assert reply.payload["reason"] =~ "trust_rejected"
    refute Map.has_key?(reply.payload, "commit_id")

    # Nothing landed and the head is exactly where it was.
    assert {:ok, %{id: head_id}} = CommitStore.latest_commit(store, uuid)
    assert head_id == head_before.id

    refute Enum.any?(
             CommitStore.all_commit_ids_for_doc(store, uuid),
             fn id ->
               match?({:ok, %{metadata: %{kind: :merge}}}, CommitStore.get_commit(store, id))
             end
           ),
           "a merge commit was persisted despite the gate denying it"
  end
end
