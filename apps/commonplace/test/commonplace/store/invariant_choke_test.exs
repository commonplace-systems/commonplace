defmodule Commonplace.Store.InvariantChokeTest do
  @moduledoc """
  CX-jfok (step 2 of the 2026-08-05 resting-state invariants design,
  §4 build-shape item 2 / §7 R1): every advance of `{:latest, uuid}`
  funnels through ONE private `put_latest/5` in
  `Commonplace.Store.CommitStore`, which both writes the head pointer
  and dispatches the post-advance alarm.

  Two kinds of pin live here:

    * Behavioural — each of the six head-advance sites dispatches
      exactly once on success, and the non-advancing outcomes (CAS
      mismatch, local-write-gate rejection, an import that finds a
      local head already present) dispatch nothing.
    * Structural — the source scan below. R1's original form was "the
      head advances at exactly four sites", a COUNT stated in prose,
      which is precisely the kind of claim that rots silently as a
      fifth site appears. The scan turns it into a check that goes red.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Document.ContentType
  alias Commonplace.Store.{Commit, CommitStore, CommitStoreClient}

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_invariant_choke_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    n = :rand.uniform(1_000_000_000)
    name = :"choke_store_#{n}"
    probe = :"choke_probe_#{n}"

    Process.register(self(), probe)

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: dir,
       name: :"choke_sup_#{n}",
       commit_store_name: name,
       trust_side_store_name: :"choke_tss_#{n}",
       pending_imports_name: :"choke_pi_#{n}",
       invariant_dispatcher: probe}
    )

    old_knob = Application.get_env(:commonplace, :local_write_gate)

    on_exit(fn ->
      Application.delete_env(:commonplace, :trust)

      case old_knob do
        nil -> Application.delete_env(:commonplace, :local_write_gate)
        v -> Application.put_env(:commonplace, :local_write_gate, v)
      end

      File.rm_rf!(dir)
    end)

    %{store: name, probe: probe}
  end

  defp text_update(body) do
    doc = Yelixer.Doc.new() |> ContentType.create(:text, "page.md")
    doc = ContentType.insert_text(doc, 0, body)
    Yelixer.Encoding.encode_update(doc)
  end

  defp assert_advance(doc_uuid, commit_id, source) do
    assert_receive {:"$gen_cast", {:advance, meta}}, 1000
    assert meta.doc_uuid == doc_uuid
    assert meta.commit_id == commit_id
    assert meta.source == source
    refute_receive {:"$gen_cast", {:advance, _}}, 100
  end

  defp drain_advances do
    receive do
      {:"$gen_cast", {:advance, _}} -> drain_advances()
    after
      0 -> :ok
    end
  end

  describe "the six head-advance sites each dispatch exactly one advance" do
    test "1. write_snapshot_cas", %{store: store} do
      uuid = UUID.uuid4()

      assert {:ok, commit} =
               CommitStore.write_snapshot_cas(store, uuid, text_update("snap"), %{}, nil)

      assert_advance(uuid, commit.id, :snapshot_cas)
    end

    test "2. write_prebuilt_commit_cas", %{store: store} do
      uuid = UUID.uuid4()
      commit = Commit.new(uuid, text_update("prebuilt"), nil, %{kind: :merge})

      assert {:ok, stored} = CommitStore.write_prebuilt_commit_cas(store, commit)

      assert_advance(uuid, stored.id, :prebuilt_cas)
    end

    test "3. put_built_commit", %{store: store} do
      uuid = UUID.uuid4()
      commit = CommitStoreClient.create_chained_commit(store, uuid, text_update("built"))

      assert %Commit{} = commit
      assert_advance(uuid, commit.id, :put_built_commit)
    end

    test "4. set_latest", %{store: store} do
      uuid = UUID.uuid4()
      commit = CommitStore.create_commit(store, uuid, text_update("head"), nil)
      drain_advances()

      assert :ok = CommitStore.set_latest(store, uuid, commit.id)
      assert_advance(uuid, commit.id, :set_latest)
    end

    test "5. import_commit onto a doc with no local head", %{store: store} do
      uuid = UUID.uuid4()
      commit = Commit.new(uuid, text_update("remote"), nil, %{})

      assert :ok = CommitStore.import_commit(store, commit)
      assert_advance(uuid, commit.id, :imported_genesis)
    end

    test "6. do_write_commit (create_commit / create_chained_commit)", %{store: store} do
      uuid = UUID.uuid4()
      commit = CommitStore.create_commit(store, uuid, text_update("local"), nil)
      assert_advance(uuid, commit.id, :write_commit)

      chained = CommitStore.create_chained_commit(store, uuid, text_update("more"))
      assert_advance(uuid, chained.id, :write_commit)
    end
  end

  describe "no dispatch when the head does not advance" do
    test "write_snapshot_cas with a stale expected parent", %{store: store} do
      uuid = UUID.uuid4()
      _ = CommitStore.create_commit(store, uuid, text_update("one"), nil)
      drain_advances()

      assert {:error, :parent_moved} =
               CommitStore.write_snapshot_cas(store, uuid, text_update("snap"), %{}, nil)

      refute_receive {:"$gen_cast", {:advance, _}}, 200
    end

    test "write_prebuilt_commit_cas with a stale parent", %{store: store} do
      uuid = UUID.uuid4()
      _ = CommitStore.create_commit(store, uuid, text_update("one"), nil)
      drain_advances()

      stale = Commit.new(uuid, text_update("prebuilt"), <<0::256>>, %{kind: :merge})
      assert {:error, :parent_moved} = CommitStore.write_prebuilt_commit_cas(store, stale)

      refute_receive {:"$gen_cast", {:advance, _}}, 200
    end

    test "put_built_commit with a stale expected parent", %{store: store} do
      uuid = UUID.uuid4()
      head = CommitStore.create_commit(store, uuid, text_update("one"), nil)
      drain_advances()

      candidate = Commit.new(uuid, text_update("two"), head.id, %{})
      assert {:error, :parent_moved} = CommitStore.put_built_commit(store, candidate, nil, nil)

      refute_receive {:"$gen_cast", {:advance, _}}, 200
    end

    test "a local write rejected by the local-write gate", %{store: store} do
      Application.put_env(:commonplace, :trust, %{accept_unsigned: false, trusted_identities: %{}})

      Application.put_env(:commonplace, :local_write_gate, :enforce)

      uuid = UUID.uuid4()

      assert {:error, {:trust_rejected, :unsigned}} =
               CommitStore.create_commit(store, uuid, text_update("secret"), nil)

      refute_receive {:"$gen_cast", {:advance, _}}, 200
    end

    test "put_built_commit rejected by the local-write gate", %{store: store} do
      Application.put_env(:commonplace, :trust, %{accept_unsigned: false, trusted_identities: %{}})

      Application.put_env(:commonplace, :local_write_gate, :enforce)

      uuid = UUID.uuid4()
      candidate = Commit.new(uuid, text_update("secret"), nil, %{})

      assert {:error, {:trust_rejected, :unsigned}} =
               CommitStore.put_built_commit(store, candidate, nil, nil)

      refute_receive {:"$gen_cast", {:advance, _}}, 200
    end

    test "import_commit when a local head already exists", %{store: store} do
      uuid = UUID.uuid4()
      local = CommitStore.create_commit(store, uuid, text_update("local"), nil)
      drain_advances()

      sibling = Commit.new(uuid, text_update("remote"), local.id, %{})
      assert :ok = CommitStore.import_commit(store, sibling)

      refute_receive {:"$gen_cast", {:advance, _}}, 200
    end
  end

  describe "the cast never raises into the write path" do
    test "an unregistered dispatcher name is a safe no-op" do
      dir = Path.join(System.tmp_dir!(), "cp_choke_nodispatch_#{:rand.uniform(1_000_000_000)}")
      File.mkdir_p!(dir)
      n = :rand.uniform(1_000_000_000)
      name = :"choke_nodispatch_store_#{n}"

      start_supervised!(
        Supervisor.child_spec(
          {Commonplace.Store.Supervisor,
           data_dir: dir,
           name: :"choke_nodispatch_sup_#{n}",
           commit_store_name: name,
           trust_side_store_name: :"choke_nodispatch_tss_#{n}",
           pending_imports_name: :"choke_nodispatch_pi_#{n}",
           invariant_dispatcher: :"choke_nobody_home_#{n}"},
          id: :choke_nodispatch_trio
        )
      )

      on_exit(fn -> File.rm_rf!(dir) end)

      uuid = UUID.uuid4()
      assert %Commit{} = CommitStore.create_commit(name, uuid, text_update("x"), nil)
      assert Process.alive?(Process.whereis(name))
    end
  end

  # ── The structural pin ────────────────────────────────────────────────
  #
  # R1 says the head-advance surface is one function. A prose count
  # cannot notice a seventh site; this can. A line is treated as a WRITE
  # of `{:latest, _}` when it either calls `CubDB.put`/`CubDB.put_multi`
  # on that key or IS a `put_multi` row (a line whose first non-space
  # characters are `{{:latest,`). Reads — `CubDB.get(db, {:latest, _})`,
  # `min_key:`/`max_key:` range bounds, and the `fn {{:latest, uuid}, _}`
  # destructure in `do_all_doc_uuids/1` — match neither shape.
  describe "source scan: only put_latest writes the head pointer" do
    test "no head-pointer write outside CommitStore.put_latest/5" do
      offenders =
        Path.wildcard(Path.join(lib_root(), "**/*.ex"), match_dot: false)
        |> Enum.flat_map(&head_pointer_writes/1)
        |> Enum.reject(fn %{function: function} -> function == "put_latest" end)

      assert offenders == [],
             """
             A `{:latest, _}` head-pointer WRITE was found outside
             `Commonplace.Store.CommitStore.put_latest/5`. Every head
             advance must funnel through that one function — it is the
             R1 choke, and the invariant dispatch hangs off it, so a
             site that bypasses it advances the head with no validation
             and no alarm.

             Offending sites:
             #{Enum.map_join(offenders, "\n", fn o -> "  #{o.file}:#{o.line} (in #{o.function}/?)\n    #{String.trim(o.text)}" end)}
             """
    end
  end

  # Anchored on __DIR__, not the process cwd: an umbrella test run's
  # working directory differs between `mix test` at the root and inside
  # the app, and a scan that silently globs zero files is the emptiest
  # kind of false green.
  defp lib_root do
    Path.expand(Path.join(__DIR__, "../../../lib"))
  end

  defp head_pointer_writes(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reduce({nil, []}, fn {line, lineno}, {current_function, hits} ->
      current_function =
        case Regex.run(~r/^\s{0,4}defp?\s+([a-z_][a-zA-Z0-9_?!]*)/, line) do
          [_, fun] -> fun
          nil -> current_function
        end

      if head_pointer_write?(line) do
        {current_function,
         [%{file: path, line: lineno, function: current_function, text: line} | hits]}
      else
        {current_function, hits}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp head_pointer_write?(line) do
    String.contains?(line, "{:latest,") and
      (String.contains?(line, "CubDB.put") or
         String.starts_with?(String.trim_leading(line), "{{:latest,"))
  end

  # A control that cannot go red is not a control. This exercises the
  # scanner's own detection on synthetic lines rather than trusting that
  # the real corpus's emptiness means the scanner works.
  describe "source scan: the scanner itself can fail" do
    test "recognises both write shapes and neither read shape" do
      assert head_pointer_write?(~s|    CubDB.put(state.db, {:latest, doc_uuid}, commit_id)|)
      assert head_pointer_write?(~s|            {{:latest, doc_uuid}, commit.id}|)
      assert head_pointer_write?(~s|  CubDB.put_multi(db, [{{:latest, u}, id}])|)

      refute head_pointer_write?(~s|    case CubDB.get(state.db, {:latest, doc_uuid}) do|)
      refute head_pointer_write?(~s|      min_key: {:latest, ""},|)
      refute head_pointer_write?("    |> Enum.map(fn {{:latest, uuid}, _commit_id} -> uuid end)")
      refute head_pointer_write?(~s|    CubDB.put(state.db, {:latest_merge_head, t}, id)|)
    end

    test "a synthetic offender is reported with its function name" do
      tmp = Path.join(System.tmp_dir!(), "cp_choke_scan_#{:rand.uniform(1_000_000_000)}.ex")

      File.write!(tmp, """
      defmodule Fake do
        defp sneaky_advance(db, uuid, id) do
          CubDB.put(db, {:latest, uuid}, id)
        end
      end
      """)

      on_exit(fn -> File.rm_rf!(tmp) end)

      assert [%{function: "sneaky_advance", line: 3}] = head_pointer_writes(tmp)
    end
  end
end
