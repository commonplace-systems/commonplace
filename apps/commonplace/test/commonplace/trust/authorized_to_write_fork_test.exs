defmodule Commonplace.Trust.AuthorizedToWriteForkTest do
  @moduledoc """
  CX-fogy L2/L3 — the LOCAL-write commit gate's CODE-content capability FORK
  (`Commonplace.Trust.authorized_to_write?`), which is THE citizen-facing RCE
  containment. For a single citizen holding ONLY a `{:subtree,home}[:define_verb]`
  cert, writing to a doc in their own zoned home, the REQUIRED capability forks on
  the AFTER-state content:

    * a VALID sandboxed safe-verb (allowlist-clean, wrapper-shaped) → `:define_verb`
      → the citizen's cert authorizes it (their creative payoff);
    * RAW / unsafe code (not wrapper-shaped, or with disallowed calls) → `:execute`
      → Gate-B, node-only → the citizen is DENIED (the RCE wall);
    * plain data → `:write` → the citizen's define_verb-only cert does NOT grant
      `:write`, so denied here too (this citizen is intentionally authoring-only).

  The classifier IS the safety validator (`SafeVerb.Allowlist.check_wrapped`, the
  same bar `SafeVerb.compile` runs), so "classified safe" == "sandboxed by
  construction" — a raw RCE payload cannot pass it and is forced to `:execute`.
  This is the pin that a citizen's `:define_verb` grant can NEVER mint raw
  executable engine code, no matter how the content is labeled/filed.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Crypto.{NodeIdentity, Signing, SigningContext}
  alias Commonplace.Document.ContentType
  alias Commonplace.MUD.{ChildMutation, SafeVerb}
  alias Commonplace.Store.{CommitStore, CommitStoreClient}
  alias Commonplace.Tree.Schema
  alias Commonplace.Trust
  alias Commonplace.Trust.Capability
  alias Yelixer.Encoding

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_a2w_fork_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    n = :rand.uniform(1_000_000_000)
    store = :"a2w_store_#{n}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: dir,
       name: :"a2w_sup_#{n}",
       commit_store_name: store,
       trust_side_store_name: :"a2w_tss_#{n}",
       pending_imports_name: :"a2w_pi_#{n}"}
    )

    old = %{
      data_dir: Application.get_env(:commonplace, :data_dir),
      trust: Application.get_env(:commonplace, :trust),
      knob: Application.get_env(:commonplace, :local_write_gate)
    }

    Application.put_env(:commonplace, :data_dir, dir)
    Application.put_env(:commonplace, :trust, %{accept_unsigned: false, trusted_identities: %{}})
    # Gate OFF so the setup writes LAND regardless of authority — we test the
    # `authorized_to_write?` PREDICATE directly (a pure fn of commit+cfg+store),
    # not the gate's enforcement wiring (that's the boundary test).
    Application.put_env(:commonplace, :local_write_gate, :off)

    on_exit(fn ->
      for {k, v} <- [data_dir: old.data_dir, trust: old.trust, local_write_gate: old.knob] do
        if v == nil,
          do: Application.delete_env(:commonplace, k),
          else: Application.put_env(:commonplace, k, v)
      end

      File.rm_rf!(dir)
    end)

    {:ok, node_ctx} = NodeIdentity.signing_context()

    # A root schema + a self-zoned home (doc_zone(home) == home).
    root = UUID.uuid4()

    CommitStore.create_commit(store, root, Encoding.encode_update(Schema.new_schema()), nil, %{},
      signing_context: node_ctx
    )

    {:ok, home} = ChildMutation.create_zone_root(root, "home", "__room.json", "{}", store)

    # A citizen holding ONLY {:subtree, home}[:define_verb].
    {pub, priv} = Signing.generate_keypair()
    pid = UUID.uuid4()
    citizen = %SigningContext{identity_uuid: pid, public_key: pub, private_key: priv}

    {:ok, cap} =
      Capability.issue(
        node_ctx,
        {pid, pub},
        %{verbs: [:define_verb], scope: {:subtree, home}, caveats: %{}},
        nil,
        store: store
      )

    :ok = CommitStoreClient.store_capability(store, cap)

    %{store: store, home: home, citizen: citizen, define_cid: cap.id, node_ctx: node_ctx}
  end

  # Mint a fresh content doc signed by `ctx`, carrying the given capability_proof +
  # verb_section metadata (as the safe-verb save path does). Returns {uuid, commit}.
  defp mint_source(store, content, ctx, define_cid, home) do
    uuid = UUID.uuid4()

    doc =
      Yelixer.Doc.new()
      |> ContentType.create(:text, "verb")
      |> ContentType.insert_text(0, content)

    update = Encoding.encode_update(doc)
    metadata = %{kind: :regular, capability_proof: define_cid, verb_section: home}
    commit = CommitStore.create_commit(store, uuid, update, nil, metadata, signing_context: ctx)
    {uuid, commit}
  end

  defp valid_safe_verb do
    {:ok, wrapped} = SafeVerb.wrap_and_lint("\"glimmer\"")
    wrapped
  end

  @raw_code """
  defmodule Attacker do
    def run(_ctx) do
      System.cmd("id", [])
    end
  end
  """

  test "a VALID sandboxed safe-verb classifies :define_verb → the citizen IS authorized", %{
    store: store,
    home: home,
    citizen: citizen,
    define_cid: cid
  } do
    {uuid, commit} = mint_source(store, valid_safe_verb(), citizen, cid, home)

    assert :ok = Trust.authorized_to_write?(commit, {:doc, uuid}, Trust.config(), store)
  end

  test "RAW unsafe code classifies :execute (Gate-B) → the citizen's :define_verb cert is DENIED",
       %{store: store, home: home, citizen: citizen, define_cid: cid} do
    {uuid, commit} = mint_source(store, @raw_code, citizen, cid, home)

    # The RCE wall: raw code is forced to :execute, which a citizen never holds.
    assert {:error, _} = Trust.authorized_to_write?(commit, {:doc, uuid}, Trust.config(), store)
  end

  test "the SAME raw code IS authorized when the NODE authors it (authority, not a broken classifier)",
       %{store: store, home: home, node_ctx: node_ctx, define_cid: cid} do
    # Node writes carry no cert, but the node holds execute authority via the
    # trusted-identity path — proves the raw→:execute classification denies the
    # CITIZEN specifically, not everyone.
    {uuid, commit} = mint_source(store, @raw_code, node_ctx, cid, home)

    assert :ok = Trust.authorized_to_write?(commit, {:doc, uuid}, Trust.config(), store)
  end

  test "a data write classifies :write → the define_verb-ONLY citizen is DENIED (no :write in the grant)",
       %{store: store, home: home, citizen: citizen, define_cid: cid} do
    {uuid, commit} =
      mint_source(store, "just some plain prose, not code at all", citizen, cid, home)

    assert {:error, _} = Trust.authorized_to_write?(commit, {:doc, uuid}, Trust.config(), store)
  end
end
