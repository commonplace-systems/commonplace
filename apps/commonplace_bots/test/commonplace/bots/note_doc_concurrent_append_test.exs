defmodule Commonplace.Bots.NoteDocConcurrentAppendTest do
  @moduledoc """
  CX-t3bt reproduction harness (EVIDENCE ONLY, offline).

  Prior investigation ruled out caching and cross-node replication as the
  source of the "probe read served pre-append state, entry reappeared
  later with no intervening write" incidents. The remaining frontier is
  concurrency: `Commonplace.Bots.NoteDoc.append_entry/3` is a
  read-modify-write over the WHOLE `"entries"` list
  (`World.get_meta_map` → append in Elixir-land → `World.merge_meta`,
  which itself reconstructs the doc, does a minimal-diff text replace,
  and lands via `Schemas.write_meta_doc` → `CommitStoreClient.create_chained_commit`).

  This test drives the REAL API end to end — `Citizen.provision/4` mints a
  real bot identity + home + the real `home/transcript` NoteDoc
  (`Commonplace.Bots.NoteDoc`'s C5c-i transcript dir, the exact doc shape
  named in the bead), `MudContext.resolve/4` builds the exact ctx shape
  `NoteDoc.append_entry/3` requires (`store`, `signing_context`,
  `signer_id`, `cert_cids`) — nothing here is a stand-in for the
  production code path.

  Everything runs against an isolated `Commonplace.Store.Supervisor`
  in a tmp dir with uniquely-named child processes, never the real
  `.commonplace/` or `dogfood-mud/` workspace, and no distribution is
  started.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Bots.{Citizen, MudContext}
  alias Commonplace.Bots.Identity, as: BotIdentity
  alias Commonplace.Document.ContentType
  alias Commonplace.Tree.DocBuilder
  alias Commonplace.Bots.NoteDoc
  alias Commonplace.Store.CommitStore
  alias Commonplace.Store.SecretStore

  setup do
    n = :rand.uniform(1_000_000_000)
    dir = Path.join(System.tmp_dir!(), "cp_bots_concurrent_notedoc_#{n}")
    File.mkdir_p!(dir)
    store = :"concurrent_notedoc_store_#{n}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: dir,
       name: :"concurrent_notedoc_sup_#{n}",
       commit_store_name: store,
       trust_side_store_name: :"concurrent_notedoc_tss_#{n}",
       pending_imports_name: :"concurrent_notedoc_pi_#{n}"}
    )

    old_data_dir = Application.get_env(:commonplace, :data_dir)
    Application.put_env(:commonplace, :data_dir, dir)

    secrets_dir = Path.join(System.tmp_dir!(), "cp_bots_concurrent_notedoc_secrets_#{n}")
    File.mkdir_p!(secrets_dir)
    secrets = :"concurrent_notedoc_secrets_#{n}"
    {:ok, secrets_pid} = SecretStore.start_link(data_dir: secrets_dir, name: secrets)

    on_exit(fn ->
      Application.put_env(:commonplace, :data_dir, old_data_dir || "tmp/test_data")

      if Process.alive?(secrets_pid) do
        try do
          GenServer.stop(secrets_pid)
        catch
          :exit, _ -> :ok
        end
      end

      File.rm_rf!(dir)
      File.rm_rf!(secrets_dir)
    end)

    {:ok, node_ctx} = Commonplace.Crypto.NodeIdentity.signing_context()

    mud_root = UUID.uuid4()

    CommitStore.create_commit(
      store,
      mud_root,
      Yelixer.Encoding.encode_update(Commonplace.Tree.Schema.new_schema()),
      nil,
      %{},
      signing_context: node_ctx
    )

    %{store: store, mud_root: mud_root, secrets: secrets}
  end

  # Provisions "camillo" for real (same call the bot runtime makes at
  # startup — mints home, foyer, study, memory/agenda/transcript
  # NoteDocs) and resolves the exact ctx shape `NoteDoc.append_entry/3`
  # requires. Returns `{transcript_uuid, ctx}`.
  defp provision_camillo_transcript(ctx) do
    {:ok, prov} = Citizen.provision("camillo", ctx.mud_root, ctx.store, secret_store: ctx.secrets)

    {:ok, sc} =
      BotIdentity.resolve_signing_context("camillo", ctx.mud_root, ctx.store,
        secret_store: ctx.secrets
      )

    {:ok, mud_ctx} = MudContext.resolve(%{name: "camillo"}, sc, ctx.mud_root, ctx.store)

    {prov.transcript_uuid, mud_ctx}
  end

  # Reads back "entries", returns the list of `"marker"` strings present.
  #
  # Uses fetch_entries/2, NOT read_entries/2, and that is deliberate.
  # Since the CX-r97r fix, read_entries/2 RAISES on a corrupt note rather
  # than masking it as `[]` — correct for callers, but it would kill this
  # test at the first severe-mode burst, and this test's whole job is to
  # OBSERVE both modes and report their relative frequency. A harness that
  # dies on the condition it exists to measure cannot measure it.
  #
  # Corruption is reported here as a distinct outcome rather than as an
  # empty list, which is the same distinction the fix introduced.
  # Returns a marker list. A CORRUPT note yields `[]` here — but unlike
  # the pre-fix read_entries/2, that is not a silent conflation: callers
  # that care use `note_readable?/2` alongside, and the CX-o3ar test
  # classifies on raw parseability directly. Kept list-shaped so the
  # lost-update arithmetic stays simple.
  defp markers_present(note_uuid, ctx) do
    case NoteDoc.fetch_entries(note_uuid, ctx) do
      {:ok, entries} -> Enum.map(entries, &Map.get(&1, "marker"))
      {:error, {:unreadable, _reason}} -> []
    end
  end

  # Is the note readable at all? The distinction the CX-r97r fix added,
  # exposed here so a test can tell "nothing was appended" apart from
  # "the doc is corrupt" — the exact conflation that cost CX-t3bt weeks.
  defp note_readable?(note_uuid, ctx) do
    match?({:ok, _}, NoteDoc.fetch_entries(note_uuid, ctx))
  end

  # Fires `n` CONCURRENT append_entry/3 calls against the same note dir,
  # each with a genuinely distinct marker (round+index, never a fixed/
  # reused value — the CX-t3bt false-red gotcha: identical item content
  # under a fixed client_id gets CRDT-deduped and reads as "no loss" for
  # the wrong reason). Returns `{expected_markers, present_markers, results}`.
  defp fire_concurrent_appends(note_uuid, ctx, round, n) do
    expected = for i <- 1..n, do: "r#{round}-w#{i}-#{System.unique_integer([:positive])}"

    results =
      expected
      |> Task.async_stream(
        fn marker ->
          NoteDoc.append_entry(note_uuid, %{"marker" => marker}, ctx)
        end,
        max_concurrency: n,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    present = markers_present(note_uuid, ctx)

    {expected, present, results}
  end

  # RAW content capture — same reconstruct path `World.get_meta_map` uses
  # (`Schemas.load_dir_schema` → `Schema.get_entry` →
  # `DocBuilder.reconstruct_doc` → `ContentType.get_content`), but stops
  # BEFORE `Jason.decode`, so a corrupt/unparseable blob is visible instead
  # of being swallowed into `{:error, _}` by `get_meta_map`.
  defp raw_note_content(note_uuid, ctx) do
    {:ok, schema} = Commonplace.MUD.Schemas.load_dir_schema(note_uuid, ctx.store)
    {:ok, entry} = Commonplace.Tree.Schema.get_entry(schema, NoteDoc.note_filename())

    case DocBuilder.reconstruct_doc(ctx.store, entry.node_id) do
      {:ok, doc} -> {:ok, ContentType.get_content(doc)}
      :none -> {:error, :no_doc}
      {:error, reason} -> {:error, reason}
    end
  end

  test "POSITIVE CONTROL: the detector reports loss when a write is deliberately dropped", ctx do
    {transcript_uuid, mud_ctx} = provision_camillo_transcript(ctx)

    # Two markers "appended", but only ONE actually written — simulates a
    # lost update without relying on any race to produce it, to prove the
    # detector (read-back + set comparison) can actually see a miss.
    kept = "control-kept-#{System.unique_integer([:positive])}"
    dropped = "control-dropped-#{System.unique_integer([:positive])}"

    assert :ok = NoteDoc.append_entry(transcript_uuid, %{"marker" => kept}, mud_ctx)
    # `dropped` is deliberately never written.

    present = markers_present(transcript_uuid, mud_ctx)

    assert kept in present
    refute dropped in present

    missing = [dropped] -- present
    assert missing == [dropped], "positive control: detector must report exactly the one dropped marker"
  end

  for {label, n} <- [{"2-way", 2}, {"4-way", 4}, {"8-way", 8}] do
    test "CONCURRENT #{label}: N simultaneous append_entry calls against the same transcript", ctx do
      {transcript_uuid, mud_ctx} = provision_camillo_transcript(ctx)
      n = unquote(n)

      {expected, present, results} = fire_concurrent_appends(transcript_uuid, mud_ctx, 1, n)

      ok_count = Enum.count(results, &(&1 == :ok))
      error_results = Enum.reject(results, &(&1 == :ok))

      missing = expected -- present

      IO.puts(
        "\n[CX-t3bt #{unquote(label)}] appended=#{n} ok=#{ok_count} errors=#{inspect(error_results)} " <>
          "present=#{length(present)} missing=#{length(missing)} #{inspect(missing)}"
      )

      # CX-r97r: this assertion CHANGED when the CAS fix landed, and the
      # change is a deliberate narrowing — record why.
      #
      # It used to assert `ok_count == n` ("every concurrent append must
      # return :ok"). Under a BOUNDED compare-and-swap that is not a
      # promise the system makes: a writer that exhausts its CAS budget
      # is told `{:error, :write_conflict}` and its entry does not land.
      # Refusing loudly is the intended behaviour — the bug being fixed
      # was that those writers were told `:ok` and silently lost.
      #
      # As of CX-g8s9 all 8 DO land (the refusals were budget exhaustion
      # inflated by an unretried roundtrip refusal, not a real limit), so
      # today this passes with zero conflicts. The assertion deliberately
      # does NOT go back to `ok_count == n`: that would re-encode a
      # promise the design still does not make, and would fail on a
      # future run with heavier contention for a reason that is correct
      # behaviour. What must never happen is a SILENT loss.
      #
      # So the assertion is now the invariant that actually matters and
      # that the old one did NOT check: NO SILENT LOSS. Every marker
      # whose call returned `:ok` must be present in the doc, and every
      # absent marker must have an explicit conflict error to account for
      # it. This is strictly stronger where correctness lives and weaker
      # only where the system deliberately makes no guarantee.
      acked =
        expected
        |> Enum.zip(results)
        |> Enum.filter(fn {_marker, result} -> result == :ok end)
        |> Enum.map(fn {marker, _result} -> marker end)

      silently_lost = acked -- present

      assert silently_lost == [],
             "SILENT LOSS (the CX-r97r bug): #{length(silently_lost)} marker(s) were " <>
               "acknowledged with :ok but are absent from the doc: #{inspect(silently_lost)}"

      # The converse: nothing may go missing without an error explaining it.
      assert missing -- (expected -- acked) == [],
             "marker(s) absent with no corresponding error result: " <>
               "#{inspect(missing -- (expected -- acked))}"

      # And a refusal must be a CONFLICT specifically — not a crash, not a
      # corruption error, not some new failure mode wearing the same shape.
      for {marker, result} <- Enum.zip(expected, results), result != :ok do
        assert result == {:error, :write_conflict},
               "#{marker} failed with an unexpected error: #{inspect(result)}"
      end
    end
  end

  test "CONCURRENT multi-round 4-way: several successive rounds of 4-way concurrency", ctx do
    {transcript_uuid, mud_ctx} = provision_camillo_transcript(ctx)

    rounds = 5
    n = 4

    {all_expected, all_ok?} =
      Enum.reduce(1..rounds, {[], true}, fn round, {exp_acc, ok_acc} ->
        {expected, present, results} = fire_concurrent_appends(transcript_uuid, mud_ctx, round, n)
        ok_count = Enum.count(results, &(&1 == :ok))
        missing = expected -- present

        IO.puts(
          "\n[CX-t3bt multi-round r#{round}] appended=#{n} ok=#{ok_count} present_total=#{length(present)} " <>
            "missing_this_round=#{length(missing)} #{inspect(missing)}"
        )

        {exp_acc ++ expected, ok_acc and ok_count == n}
      end)

    final_present = markers_present(transcript_uuid, mud_ctx)
    total_missing = all_expected -- final_present

    # Say WHICH failure mode this run hit. "0 present" is ambiguous on its
    # own — it means either every append was lost (mode 1) or the doc is
    # corrupt and unreadable (mode 2). Conflating those two is precisely
    # the bug under test, so the diagnostic must not repeat it.
    mode =
      if note_readable?(transcript_uuid, mud_ctx),
        do: "readable (lost-update mode)",
        else: "UNREADABLE — doc corrupt (CX-r97r severe mode)"

    IO.puts(
      "\n[CX-t3bt multi-round FINAL] total_appended=#{length(all_expected)} " <>
        "total_present=#{length(final_present)} total_missing=#{length(total_missing)} " <>
        "doc=#{mode} #{inspect(total_missing)}"
    )

    if total_missing != [] do
      # Inspect whether the missing entries exist as SIBLING commits: walk
      # every persisted commit for the transcript doc (not just the
      # :latest-reachable chain `CommitStore.commit_log/3` walks) and check
      # whether any off-chain commit's content contains the missing marker.
      {:ok, schema} = Commonplace.MUD.Schemas.load_dir_schema(transcript_uuid, ctx.store)
      {:ok, entry} = Commonplace.Tree.Schema.get_entry(schema, NoteDoc.note_filename())
      node_id = entry.node_id

      reachable_log = CommitStore.commit_log(ctx.store, node_id)
      reachable_ids = MapSet.new(reachable_log, & &1.id)

      db = CommitStore.db_handle(ctx.store)
      all_commit_ids_for_doc = CommitStore.all_commit_ids_for_doc(ctx.store, node_id)
      sibling_ids = MapSet.difference(all_commit_ids_for_doc, reachable_ids)

      IO.puts(
        "\n[CX-t3bt sibling-check] node_id=#{node_id} reachable_commits=#{length(reachable_log)} " <>
          "total_persisted_commits=#{MapSet.size(all_commit_ids_for_doc)} unreachable_sibling_commits=#{MapSet.size(sibling_ids)}"
      )

      Enum.each(sibling_ids, fn id ->
        commit = CubDB.get(db, {:commit, id})
        IO.puts("  sibling commit #{id}: parent=#{inspect(commit && commit.parent_id)}")
      end)
    end

    # Same honesty note as the single-round tests: report, don't assert
    # blind on `total_missing`. We DO assert every call across every round
    # returned :ok (no write outright failed/errored), so a "missing"
    # result can only mean lost-update, never a masked error.
    assert all_ok?, "expected every append_entry call across all #{rounds} rounds to return :ok"
  end

  # --- Coordinator follow-up: is the SEVERE (total_present=0) mode a lost
  # update, or is the `__note.json` blob itself unparseable (CX-o3ar's
  # whole-blob-concatenation signature)? ---
  #
  # `Schemas.write_meta_doc` does a minimal-DIFF text replace against the
  # doc's CURRENT reconstructed content — not an atomic whole-field CAS at
  # the JSON level. If two concurrent writers' text edits interleave at the
  # Yjs item level (rather than one cleanly clobbering the other, as the
  # mild-mode 1-survivor-per-burst result suggested), the reconstructed
  # text could come out as neither writer's JSON — e.g. two whole
  # `{"entries":[...]}"` blobs concatenated, or a truncated splice —
  # which would explain "previously-readable entries become unreadable,
  # then subsequent appends themselves start erroring" (a decode failure
  # inside `World.get_meta_map`/`merge_meta` surfaces as a non-:ok result).
  #
  # `NoteDoc.read_entries/2` MASKS decode failure as `[]` (a deliberate
  # "unreadable → empty" degrade), so `total_present=0` alone cannot
  # distinguish "all entries lost but the doc still parses" from "the doc
  # no longer parses at all". This test captures the RAW pre-decode text
  # every round instead of trusting `read_entries`.
  test "CX-o3ar CHECK: is severe-mode (present=0) a parse failure, or a clean lost update?", ctx do
    {:ok, node_ctx} = Commonplace.Crypto.NodeIdentity.signing_context()
    _ = node_ctx

    {:ok, sc} =
      BotIdentity.resolve_signing_context("camillo", ctx.mud_root, ctx.store,
        secret_store: ctx.secrets
      )

    {:ok, prov} = Citizen.provision("camillo", ctx.mud_root, ctx.store, secret_store: ctx.secrets)
    {:ok, mud_ctx} = MudContext.resolve(%{name: "camillo"}, sc, ctx.mud_root, ctx.store)

    home_room_uuid = prov.home_room_uuid
    empty_entries = ~s({"entries":[]})

    n = 8
    attempts = 40

    samples =
      for attempt <- 1..attempts do
        dir_name = "corruption-check-#{attempt}"
        {:ok, note_uuid} = NoteDoc.ensure_zoned_dir(home_room_uuid, dir_name, empty_entries, mud_ctx)

        expected = for i <- 1..n, do: "a#{attempt}-w#{i}-#{System.unique_integer([:positive])}"

        results =
          expected
          |> Task.async_stream(
            fn marker -> NoteDoc.append_entry(note_uuid, %{"marker" => marker}, mud_ctx) end,
            max_concurrency: n,
            timeout: 30_000
          )
          |> Enum.map(fn {:ok, result} -> result end)

        ok_count = Enum.count(results, &(&1 == :ok))
        error_results = Enum.reject(results, &(&1 == :ok))

        {raw_status, raw} = raw_note_content(note_uuid, mud_ctx)
        decode_result = if is_binary(raw), do: Jason.decode(raw), else: {:error, :no_raw}

        entries_key_count =
          if is_binary(raw) do
            raw |> String.split(~s("entries")) |> length() |> Kernel.-(1)
          else
            0
          end

        byte_size = if is_binary(raw), do: byte_size(raw), else: 0
        present = markers_present(note_uuid, mud_ctx)

        mode =
          cond do
            match?({:error, _}, decode_result) -> :unparseable
            entries_key_count > 1 -> :doubled_key
            present == [] -> :severe_but_valid_json
            length(present) < n -> :mild_lost_update
            true -> :no_loss
          end

        %{
          attempt: attempt,
          mode: mode,
          ok_count: ok_count,
          error_results: error_results,
          appended: n,
          present_count: length(present),
          raw_status: raw_status,
          raw: raw,
          decode_result: decode_result,
          entries_key_count: entries_key_count,
          byte_size: byte_size
        }
      end

    by_mode = Enum.group_by(samples, & &1.mode)

    IO.puts(
      "\n[CX-o3ar mode tally across #{attempts} attempts, n=#{n}] " <>
        (by_mode
         |> Enum.map(fn {mode, list} -> "#{mode}=#{length(list)}" end)
         |> Enum.join(" "))
    )

    mild_sample = Enum.find(samples, &(&1.mode in [:mild_lost_update, :no_loss]))
    severe_sample =
      Enum.find(samples, &(&1.mode in [:unparseable, :doubled_key, :severe_but_valid_json]))

    report_sample = fn label, sample ->
      if sample do
        truncated =
          case sample.raw do
            r when is_binary(r) -> String.slice(r, 0, 400)
            other -> inspect(other)
          end

        IO.puts("""

        [CX-o3ar #{label} sample] attempt=#{sample.attempt} mode=#{sample.mode}
          ok=#{sample.ok_count}/#{sample.appended} errors=#{inspect(sample.error_results)}
          present_via_read_entries=#{sample.present_count}
          raw_status=#{inspect(sample.raw_status)} byte_size=#{sample.byte_size}
          entries_key_occurrences=#{sample.entries_key_count}
          jason_decode=#{inspect(sample.decode_result) |> String.slice(0, 200)}
          raw_content (first 400 bytes): #{inspect(truncated)}
        """)
      else
        IO.puts("\n[CX-o3ar #{label} sample] none observed in #{attempts} attempts")
      end
    end

    report_sample.("MILD", mild_sample)
    report_sample.("SEVERE", severe_sample)

    # Evidence-gathering only — no verdict asserted here. The mode tally
    # and both raw samples above are the deliverable; see the written
    # report for interpretation.
    assert is_list(samples)
  end
end
