defmodule Commonplace.Store.TranslatedCommitSigningTest do
  @moduledoc """
  CX-tdkq.26: the cross-epoch translator runs with no user in the loop —
  translation is a system action of the RECEIVING node (the phase-2.5
  pattern), and the original signature cannot survive the byte rewrite.
  Its output must therefore be node-signed, or strict Gate A
  (`accept_unsigned: false`) rejects every translated commit and
  multi-epoch sync bricks under strict mode.

  The signature lives OUTSIDE the content address (see
  `Commonplace.Store.Commit`), so node-signing keeps translated commit
  ids byte-deterministic across peers.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Crypto.{NodeIdentity, Signing}
  alias Commonplace.Document.ContentType
  alias Commonplace.Store.{Commit, CommitStore, Translator}
  alias Yelixer.{BlockStore, Doc, Encoding}
  alias Yelixer.Types.Text

  setup do
    dir = Path.join(System.tmp_dir!(), "translated_signing_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    name = :"translated_signing_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: name})
    on_exit(fn -> File.rm_rf!(dir) end)
    %{store: name}
  end

  # Bare-text late-edit scenario, cribbed from translator_test.exs:
  # client 1 writes "abc", snapshot re-identifies, client 2's edit
  # (built against P's state vector) arrives late and must be
  # translated onto the snapshot.
  defp translate_a_late_edit(store, uuid) do
    {:ok, _genesis} = CommitStore.ensure_genesis(store, uuid)

    doc_p = Doc.new(client_id: 1)
    {doc_p, _} = Doc.get_or_create_type(doc_p, "t", :text)
    doc_p = Text.insert(doc_p, "t", 0, "abc")
    e_p = Encoding.encode_update(doc_p)
    base_sv = BlockStore.state_vector(doc_p.store)

    _reg = CommitStore.create_chained_commit(store, uuid, e_p, %{kind: :regular})
    {:ok, snapshot} = CommitStore.snapshot(store, uuid)
    p_namespace = snapshot.metadata[:snapshot_parents] |> hd()

    doc_b = Doc.new(client_id: 2)
    {doc_b, _} = Doc.get_or_create_type(doc_b, "t", :text)
    {:ok, doc_b} = Encoding.apply_update(doc_b, e_p)
    doc_b = Text.insert(doc_b, "t", 3, "de")
    edit_update = Encoding.encode_diff(doc_b, base_sv)

    edit = Commit.new(uuid, edit_update, nil, %{kind: :regular, snapshot_parent: p_namespace})

    Translator.translate_edit(store, edit, snapshot.id)
  end

  # Envelope scenario with a broken derivation map, cribbed from
  # translator_fallback_test.exs — forces the positional-rebase
  # fallback mint, the translator's OTHER Commit.new site.
  defp translate_via_fallback(store, uuid) do
    {:ok, _genesis} = CommitStore.ensure_genesis(store, uuid)

    doc_p =
      Doc.new(client_id: 1)
      |> ContentType.create(:text, "n")
      |> ContentType.insert_text(0, "abc")

    e_p = Encoding.encode_update(doc_p)
    base_sv = BlockStore.state_vector(doc_p.store)

    _reg = CommitStore.create_chained_commit(store, uuid, e_p, %{kind: :regular})
    {:ok, snapshot} = CommitStore.snapshot(store, uuid)
    p_namespace = snapshot.metadata[:snapshot_parents] |> hd()

    doc_b = Doc.new(client_id: 2)
    {:ok, doc_b} = Encoding.apply_update(doc_b, e_p)
    doc_b = ContentType.insert_text(doc_b, 3, "de")
    edit_update = Encoding.encode_diff(doc_b, base_sv)

    edit = Commit.new(uuid, edit_update, nil, %{kind: :regular, snapshot_parent: p_namespace})

    pre_doc = Doc.new()
    {:ok, pre_doc} = Encoding.apply_update(pre_doc, e_p)

    broken_snapshot = put_in(snapshot.metadata[:derivation_map], %{p_namespace => %{}})

    Translator.translate_edit_with_snapshot(edit, broken_snapshot,
      fallback_to_positional: true,
      pre_doc: pre_doc
    )
  end

  defp strict_config_with_node_pinned do
    {:ok, identity} = NodeIdentity.identity()
    {:ok, pub} = NodeIdentity.public_key()
    %{accept_unsigned: false, trusted_identities: %{identity => Signing.encode_key(pub)}}
  end

  test "translated commit is node-signed", %{store: store} do
    {:ok, translated} = translate_a_late_edit(store, "tcs-signed")

    refute is_nil(translated.signature),
           "translated commit must be node-signed (no user is in the loop)"

    {:ok, node_identity} = NodeIdentity.identity()
    assert translated.signer_id =~ node_identity

    {:ok, pub} = NodeIdentity.public_key()
    assert :ok = Signing.verify_commit(translated, pub)
  end

  test "translated commit passes Gate A in strict mode", %{store: store} do
    {:ok, translated} = translate_a_late_edit(store, "tcs-gate-a")

    strict = strict_config_with_node_pinned()

    assert :ok =
             Commonplace.Trust.authorized?(
               translated,
               :write,
               {:doc, translated.doc_uuid},
               strict
             )
  end

  test "signing stays outside the content address — commit id is unchanged by the signature",
       %{store: store} do
    {:ok, translated} = translate_a_late_edit(store, "tcs-id-det")

    # Re-mint the same content unsigned; the content address must match,
    # proving the signature does not enter the id.
    unsigned_twin =
      Commit.new(
        translated.doc_uuid,
        translated.update,
        translated.parent_id,
        translated.metadata,
        translated.merge_parents
      )

    assert unsigned_twin.id == translated.id
  end

  test "positional-fallback translated commit is node-signed too", %{store: store} do
    {:ok, translated} = translate_via_fallback(store, "tcs-fallback")

    refute is_nil(translated.signature),
           "fallback-minted translated commit must be node-signed"

    {:ok, node_identity} = NodeIdentity.identity()
    assert translated.signer_id =~ node_identity
  end
end
