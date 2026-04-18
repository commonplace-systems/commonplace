defmodule Commonplace.Store.TranslatorFallbackTest do
  @moduledoc """
  CX-7sln (Build 6.6): opt-in positional-rebase fallback.

  When `Translator.translate_edit_with_snapshot/3` is called with
  `fallback_to_positional: true` and pre-flight fails (`:case_a` /
  `:case_b`), the translator dispatches to
  `Commonplace.Document.Rebase.rebase/3` (CX-6a7) to re-author the
  dirty edit as native-coordinate ops on the target snapshot. Emits
  `[:commonplace, :late_edit, :fallback]` with
  `%{edit_hash, target_snapshot, reason, ref_id, commit_id}`.

  With the flag unset (default `false`), behavior matches 6.5 —
  pre-flight failure short-circuits as `{:error, {:untranslatable, _, _}}`.

  Positional-rebase re-authors under the local peer's client id, so
  byte-determinism across peers is lost — the documented tradeoff for
  taking the fallback path.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Document.ContentType
  alias Commonplace.Store.{Commit, CommitStore, Translator}
  alias Yelixer.{BlockStore, Doc, Encoding}
  alias Yelixer.Types.Text

  setup do
    dir = Path.join(System.tmp_dir!(), "translator_fb_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    name = :"translator_fb_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: name})
    on_exit(fn -> File.rm_rf!(dir) end)
    %{store: name}
  end

  # -------------------- Envelope-doc scenario (fallback path) --------------------

  # Envelope-structure text doc. Client 1 writes "abc" into
  # `ContentType`'s "content" YText. Client 2 builds a late edit that
  # appends "de". Returns {snapshot, edit, pre_doc, broken_snapshot}.
  # `pre_doc` is a fresh reconstruction of P's envelope state — what
  # the fallback hands to `Rebase.rebase/3` as its `old_doc`.
  # `broken_snapshot` has its derivation map cleared to force a
  # pre-flight failure (the primary path works end-to-end on envelope
  # docs after CX-hzdc, so tests that want to exercise the fallback
  # must manufacture a failure).
  defp envelope_scenario(store, uuid) do
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

    {snapshot, edit, pre_doc, broken_snapshot}
  end

  # -------------------- Bare-text scenario (primary-path succeeds) -----------

  # Mirrors the scenario in `translator_test.exs` — bare Yelixer Text
  # type "t" with no envelope. The sub-clock DM expansion in the
  # translator resolves all refs, so pre-flight succeeds and the
  # primary path wins; the fallback must NOT trigger.
  defp bare_scenario(store, uuid) do
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

    pre_doc = Doc.new()
    {:ok, pre_doc} = Encoding.apply_update(pre_doc, e_p)

    {snapshot, edit, pre_doc}
  end

  defp capture_telemetry(event) do
    test_pid = self()
    handler_id = {__MODULE__, event, make_ref()}

    :telemetry.attach(
      handler_id,
      event,
      fn ^event, meas, meta, _cfg ->
        send(test_pid, {:telemetry, event, meas, meta})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  # -------------------- Flag unset: fail-loud (matches 6.5) --------------------

  describe "translate_edit_with_snapshot/3 — flag unset (default)" do
    test "pre-flight failure returns {:error, {:untranslatable, ...}} without dispatching fallback",
         %{store: store} do
      {_snapshot, edit, _pre_doc, broken_snapshot} = envelope_scenario(store, "fb-flag-unset")

      assert {:error, {:untranslatable, _reason, _ref_id}} =
               Translator.translate_edit_with_snapshot(edit, broken_snapshot)
    end
  end

  # -------------------- Flag set: dispatch to positional rebase --------------------

  describe "translate_edit_with_snapshot/3 — fallback_to_positional: true" do
    test "pre-flight failure routes to Rebase and produces a valid commit with dirty effect preserved",
         %{store: store} do
      {_snapshot, edit, pre_doc, broken_snapshot} = envelope_scenario(store, "fb-ok")

      assert {:ok, translated} =
               Translator.translate_edit_with_snapshot(
                 edit,
                 broken_snapshot,
                 fallback_to_positional: true,
                 pre_doc: pre_doc
               )

      assert %Commit{} = translated
      assert translated.parent_id == broken_snapshot.id
      assert translated.metadata[:kind] == :regular
      assert translated.metadata[:snapshot_parent] == broken_snapshot.id
      assert is_binary(translated.update)

      # Dirty effect preserved: applying translated update on top of
      # the snapshot doc yields content == "abcde".
      {:ok, doc_s} = Encoding.apply_update(Doc.new(), broken_snapshot.update)
      {:ok, doc_final} = Encoding.apply_update(doc_s, translated.update)
      assert ContentType.get_content(doc_final) == "abcde"
    end

    test "emits [:commonplace, :late_edit, :fallback] red event with edit_hash, target_snapshot, reason, ref_id, commit_id",
         %{store: store} do
      capture_telemetry([:commonplace, :late_edit, :fallback])

      {_snapshot, edit, pre_doc, broken_snapshot} = envelope_scenario(store, "fb-telem")

      {:ok, translated} =
        Translator.translate_edit_with_snapshot(
          edit,
          broken_snapshot,
          fallback_to_positional: true,
          pre_doc: pre_doc
        )

      assert_receive {:telemetry, [:commonplace, :late_edit, :fallback], _meas, metadata}, 500
      assert metadata.edit_hash == edit.id
      assert metadata.target_snapshot == broken_snapshot.id
      assert metadata.commit_id == translated.id
      assert metadata.reason in [:case_a, :case_b]
      assert is_tuple(metadata.ref_id)
    end

    test "pre-flight SUCCESS does NOT dispatch fallback (fallback only on failure)",
         %{store: store} do
      capture_telemetry([:commonplace, :late_edit, :fallback])

      {snapshot, edit, pre_doc} = bare_scenario(store, "fb-no-trigger")

      assert {:ok, _translated} =
               Translator.translate_edit_with_snapshot(
                 edit,
                 snapshot,
                 fallback_to_positional: true,
                 pre_doc: pre_doc
               )

      refute_receive {:telemetry, [:commonplace, :late_edit, :fallback], _, _}, 200
    end
  end
end
