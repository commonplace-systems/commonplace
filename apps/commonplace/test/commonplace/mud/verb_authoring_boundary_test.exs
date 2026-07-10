defmodule Commonplace.MUD.VerbAuthoringBoundaryTest do
  @moduledoc """
  SECURITY-BOUNDARY GUARD: a real citizen holding only a `{:subtree,home}`
  `[:write]` cert CANNOT author (save) executable verb code, even in their OWN
  home — while the NODE (execute authority) can. This is the write⊥execute /
  Gate-B boundary = RCE protection: a player who can build rooms must never be
  able to inject executable code that later runs with execute privileges.

  Characterized the live @verb save-denial fable's playtest hit (2026-07-10): the
  denial is `{:trust_rejected, :capability_insufficient}` — a WRITE-GATE authority
  refusal, NOT a broken path (the same save NODE-signed returns `:ok`). This pin
  guards the boundary: if a future change ever lets a `[:write]` citizen save a
  verb, test 1 goes green-on-save and fails here — surfacing an RCE regression.
  If product intent later adds player-authored zone-scoped verbs, that's a NEW
  cert grammar (execute-scoped subtree cert / node-mediated review) + a deliberate
  update to this guard, never a silent one.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Crypto.{NodeIdentity, Signing, SigningContext}
  alias Commonplace.Store.CommitStore
  alias Commonplace.MUD.{Citizenship, VerbSource}
  alias Commonplace.Tree.Schema

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_verbchar_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    n = :rand.uniform(1_000_000_000)
    store = :"verbchar_store_#{n}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: dir,
       name: :"verbchar_sup_#{n}",
       commit_store_name: store,
       trust_side_store_name: :"verbchar_tss_#{n}",
       pending_imports_name: :"verbchar_pi_#{n}"}
    )

    old = %{
      data_dir: Application.get_env(:commonplace, :data_dir),
      trust: Application.get_env(:commonplace, :trust),
      knob: Application.get_env(:commonplace, :local_write_gate)
    }

    Application.put_env(:commonplace, :data_dir, dir)
    Application.put_env(:commonplace, :trust, %{accept_unsigned: false, trusted_identities: %{}})
    Application.put_env(:commonplace, :local_write_gate, :enforce)

    on_exit(fn ->
      for {k, v} <- [data_dir: old.data_dir, trust: old.trust, local_write_gate: old.knob] do
        if v == nil, do: Application.delete_env(:commonplace, k), else: Application.put_env(:commonplace, k, v)
      end

      File.rm_rf!(dir)
    end)

    {:ok, node_ctx} = NodeIdentity.signing_context()
    root = UUID.uuid4()
    CommitStore.create_commit(store, root, Yelixer.Encoding.encode_update(Schema.new_schema()), nil, %{}, signing_context: node_ctx)

    {pub, priv} = Signing.generate_keypair()
    pid = UUID.uuid4()
    citizen = %SigningContext{identity_uuid: pid, public_key: pub, private_key: priv}
    {:ok, %{cert_cids: cids, home_room_uuid: home}} = Citizenship.ensure(pid, pub, "builder", root, store)

    %{store: store, home: home, citizen: citizen, cids: cids, node_ctx: node_ctx}
  end

  # bare-literal body: passes the safe-verb lint (no calls) so BOTH tests isolate
  # the AUTHORITY axis (node vs player), not the allowlist. (The lint runs BEFORE
  # the write, so a disallowed call would mask the trust result.)
  @body "\"tick\""

  test "a {:write}-only citizen CANNOT save a verb in their OWN home — denied at the write-gate", %{store: store, home: home, citizen: citizen, cids: cids} do
    result =
      VerbSource.save_safe_verb(home, "tick", @body, [home], store,
        signing_context: citizen,
        cert_cids: cids,
        signer_id: nil
      )

    # The write-gate refuses the code-doc write: the citizen's {:subtree,home}
    # cert grants [:write], not the authority to author executable verb code.
    # Pin the SHAPE — a bare {:error, _} would also match a lint/compile fault,
    # which is NOT the boundary we're guarding.
    assert {:error, {:trust_rejected, _}} = result
  end

  test "the NODE (execute authority) CAN save the same verb in that home — proving it's authority, not a broken path", %{store: store, home: home, node_ctx: node_ctx} do
    result =
      VerbSource.save_safe_verb(home, "tick", @body, [home], store,
        signing_context: node_ctx,
        cert_cids: []
      )

    assert result == :ok
  end

  # CX-jxqs: the @verb editor must signal read-only PREVIEW upfront for a caller
  # who can't author verbs here — not open a full editor and only deny the save.
  defp verb_ctx(store, home, sctx, cids),
    do: %{
      store: store,
      player_name: "builder",
      root_uuid: nil,
      current_room_uuid: home,
      inventory_uuid: nil,
      signing_context: sctx,
      cert_cids: cids,
      signer_id: nil
    }

  test "a {:write}-only citizen opening @verb gets PREVIEW (editable: false), not the editor", %{store: store, home: home, citizen: citizen, cids: cids} do
    cmd = Commonplace.MUD.Parser.parse("@verb here:tick")
    assert {:enter_editor, %{editable: false}} = Commonplace.MUD.Verbs.dispatch(cmd, verb_ctx(store, home, citizen, cids))
  end

  test "the NODE opening @verb gets the editable editor (editable: true)", %{store: store, home: home, node_ctx: node_ctx} do
    cmd = Commonplace.MUD.Parser.parse("@verb here:tick")
    assert {:enter_editor, %{editable: true}} = Commonplace.MUD.Verbs.dispatch(cmd, verb_ctx(store, home, node_ctx, []))
  end
end
