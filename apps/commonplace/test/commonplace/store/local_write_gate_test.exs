defmodule Commonplace.Store.LocalWriteGateTest do
  @moduledoc """
  CX-qat5.3: the third `Trust.authorized?` call-site family — the
  LOCAL-write gate at `CommitStore`'s create seam (`do_write_commit/7`,
  the legacy serialized path, AND the `{:put_built_commit, ...}` handler,
  the CX-3erd hoisted CAS path that `CommitStoreClient`'s local-mode
  `create_commit`/`create_chained_commit` route through).

  Mirrors `Commonplace.Store.ImportTrustGateTest` (Gate A) in spirit —
  same verifier (`Trust.authorized?/5`), same error taxonomy
  (`{:error, {:trust_rejected, reason}}`) — but exercised at the LOCAL
  create seam instead of `import_commit/3`, and gated additionally by
  the `:commonplace, :local_write_gate` three-position knob
  (`:off` / `:dry_run` / `:enforce`).

  See docs/plans/2026-07-06-qat5.3-local-write-gate-spec.md for the
  full design; test pins below are numbered to match spec §6.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Crypto.{NodeIdentity, Signing, SigningContext}
  alias Commonplace.Document.ContentType
  alias Commonplace.Store.{Commit, CommitStore, CommitStoreClient}
  alias Commonplace.Trust.Capability

  # Full trio (Store.Supervisor) so the phase-3 capability path (fence pin)
  # and the CAS/hoisted path (CommitStoreClient) both have a companion
  # TrustSideStore/PendingImports to address — mirrors
  # AuthorizedCapabilityTest / ExecuteBaselineTest's setup.
  setup do
    dir = Path.join(System.tmp_dir!(), "cp_local_write_gate_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    n = :rand.uniform(1_000_000_000)
    name = :"lwg_store_#{n}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: dir,
       name: :"lwg_sup_#{n}",
       commit_store_name: name,
       trust_side_store_name: :"lwg_tss_#{n}",
       pending_imports_name: :"lwg_pi_#{n}"}
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

    {pub, priv} = Signing.generate_keypair()
    identity = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    signer_id = Signing.signer_id(identity, pub)
    ctx = %SigningContext{identity_uuid: identity, private_key: priv, public_key: pub}

    %{store: name, pub: pub, priv: priv, identity: identity, signer_id: signer_id, ctx: ctx}
  end

  defp strict!(trusted \\ %{}) do
    Application.put_env(:commonplace, :trust, %{
      accept_unsigned: false,
      trusted_identities: trusted
    })
  end

  defp enforce!, do: Application.put_env(:commonplace, :local_write_gate, :enforce)
  defp dry_run!, do: Application.put_env(:commonplace, :local_write_gate, :dry_run)
  defp off!, do: Application.put_env(:commonplace, :local_write_gate, :off)

  defp text_update(body) do
    doc = Yelixer.Doc.new() |> ContentType.create(:text, "page.md")
    doc = ContentType.insert_text(doc, 0, body)
    Yelixer.Encoding.encode_update(doc)
  end

  # ── Pin 1: permissive default is a no-op ──────────────────────────────
  #
  # The full corpus (mix test apps/commonplace/test, 1790 tests) is the
  # real proof of this pin — every existing write path keeps working with
  # the gate compiled in. This is a small, explicit sanity check that both
  # create paths still land under default config + default knob.
  describe "pin 1: permissive default is a no-op" do
    test "do_write_commit path (CommitStore.create_commit) lands unsigned", %{store: store} do
      uuid = UUID.uuid4()
      commit = CommitStore.create_commit(store, uuid, text_update("hello"), nil)
      assert %Commit{} = commit
      assert {:ok, _} = CommitStore.get_commit(store, commit.id)
    end

    test "put_built_commit path (CommitStoreClient.create_chained_commit) lands unsigned", %{
      store: store
    } do
      uuid = UUID.uuid4()
      commit = CommitStoreClient.create_chained_commit(store, uuid, text_update("hello"))
      assert %Commit{} = commit
      assert {:ok, _} = CommitStore.get_commit(store, commit.id)
    end
  end

  # ── Pin 2: strict + unsigned → rejected, red event, nothing persisted,
  #    no CAS retry ────────────────────────────────────────────────────
  describe "pin 2: strict + unsigned browser write is rejected in enforce mode" do
    test "store-local gate and trust path override permissive ambient config" do
      old_trust = Application.get_env(:commonplace, :trust)
      old_gate = Application.get_env(:commonplace, :local_write_gate)
      Application.put_env(:commonplace, :trust, %{accept_unsigned: true})
      Application.put_env(:commonplace, :local_write_gate, :off)

      dir =
        Path.join(System.tmp_dir!(), "cp_explicit_write_gate_#{:rand.uniform(1_000_000_000)}")

      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "trust.json"), Jason.encode!(%{accept_unsigned: false}))
      n = :rand.uniform(1_000_000_000)
      store = :"explicit_lwg_store_#{n}"

      child =
        Supervisor.child_spec(
          {Commonplace.Store.Supervisor,
           data_dir: dir,
           name: :"explicit_lwg_sup_#{n}",
           commit_store_name: store,
           trust_side_store_name: :"explicit_lwg_tss_#{n}",
           pending_imports_name: :"explicit_lwg_pi_#{n}",
           local_write_gate: :enforce},
          id: {:explicit_lwg, n}
        )

      start_supervised!(child)

      on_exit(fn ->
        restore_env(:trust, old_trust)
        restore_env(:local_write_gate, old_gate)
        File.rm_rf!(dir)
      end)

      uuid = UUID.uuid4()

      assert {:error, {:trust_rejected, :unsigned}} =
               CommitStore.create_commit(store, uuid, text_update("must not land"), nil)

      assert :none = CommitStore.latest_commit(store, uuid)
    end

    test "do_write_commit path rejects, persists nothing, emits telemetry", %{store: store} do
      strict!()
      enforce!()
      uuid = UUID.uuid4()

      ref = make_ref()
      parent = self()

      # Filter on THIS test's doc uuid — same discipline as the CAS pin
      # below, and for the same reason plus one more (CX-7m9g / CX-t3xv).
      #
      # `[:commonplace, :commit, :rejected, :local_trust]` is node-global.
      # Any other denial in flight — a neighbour test's, or (before
      # CX-t3xv) the trust-audit-log doc's OWN refused write, whose
      # doc_uuid is the fixed uuid5 f4e8eac8-7bab-5ecd-ad86-e09f3a9ff900 —
      # would arrive first and this assertion would check a stranger's
      # metadata. That was CI 31081011655 at seed 940808, reproducible in
      # isolation because the racing denial came from EARLIER IN THIS
      # FILE, not from a neighbour.
      #
      # Note which layer this is: the gate's `reject + persist nothing`
      # assertions never failed. Only the telemetry CAPTURE raced.
      :telemetry.attach(
        {:lwg_reject_handler, ref},
        [:commonplace, :commit, :rejected, :local_trust],
        fn _event, meas, %{doc_uuid: event_uuid} = meta, _cfg ->
          if event_uuid == uuid, do: send(parent, {:lwg_rejected, ref, meas, meta})
        end,
        nil
      )

      assert {:error, {:trust_rejected, :unsigned}} =
               CommitStore.create_commit(store, uuid, text_update("secret"), nil)

      assert :none = CommitStore.latest_commit(store, uuid)

      # Selective on the uuid as well as the ref: belt and braces, so the
      # pin stays honest even if the handler filter is later loosened.
      assert_receive {:lwg_rejected, ^ref, _meas, %{doc_uuid: ^uuid} = meta}, 500
      assert meta.mode == :enforce
      assert meta.reason == :unsigned

      :telemetry.detach({:lwg_reject_handler, ref})
    end

    test "put_built_commit / CAS path rejects, persists nothing, does not retry", %{store: store} do
      strict!()
      enforce!()
      uuid = UUID.uuid4()

      ref = make_ref()
      parent = self()

      # Count how many times the CAS verb itself runs — a retry loop would
      # show up as more than one :put_built_commit call. Filter on THIS
      # test's doc uuid, not just the verb: the telemetry event is
      # node-global, and under a concurrent full-suite run another test's
      # put_built_commit would otherwise land in this mailbox and trip
      # the refute_receive below (observed as a load-only flake).
      :telemetry.attach(
        {:lwg_cas_call_handler, ref},
        [:commonplace, :commit_store, :call],
        fn _event, _meas, %{verb: verb, doc_uuid: event_uuid} = meta, _cfg ->
          if verb == :put_built_commit and event_uuid == uuid,
            do: send(parent, {:lwg_cas_call, ref, meta})
        end,
        nil
      )

      assert {:error, {:trust_rejected, :unsigned}} =
               CommitStoreClient.create_chained_commit(store, uuid, text_update("secret"))

      assert :none = CommitStore.latest_commit(store, uuid)

      assert_receive {:lwg_cas_call, ^ref, _meta}, 500
      refute_receive {:lwg_cas_call, ^ref, _meta}, 200

      :telemetry.detach({:lwg_cas_call_handler, ref})
    end

    test "red event fires on the doc's topic", %{store: store} do
      strict!()
      enforce!()
      uuid = UUID.uuid4()

      Commonplace.Dataflow.PubSub.subscribe_red(uuid)

      assert {:error, {:trust_rejected, :unsigned}} =
               CommitStore.create_commit(store, uuid, text_update("secret"), nil)

      assert_receive {"red:" <> ^uuid, {:trust, :local_write_denied, meta}}, 500
      assert meta.doc_uuid == uuid
      assert meta.reason == :unsigned
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:commonplace, key)
  defp restore_env(key, value), do: Application.put_env(:commonplace, key, value)

  # ── Pin 3: strict + player-signed write with pinned identity lands ───
  describe "pin 3: strict + pinned identity lands" do
    test "do_write_commit path", %{store: store, pub: pub, identity: identity, ctx: ctx} do
      strict!(%{identity => Signing.encode_key(pub)})
      enforce!()
      uuid = UUID.uuid4()

      commit =
        CommitStore.create_commit(store, uuid, text_update("hi"), nil, %{}, signing_context: ctx)

      assert %Commit{} = commit
      assert {:ok, _} = CommitStore.get_commit(store, commit.id)
    end

    test "put_built_commit / CAS path", %{store: store, pub: pub, identity: identity, ctx: ctx} do
      strict!(%{identity => Signing.encode_key(pub)})
      enforce!()
      uuid = UUID.uuid4()

      commit =
        CommitStoreClient.create_chained_commit(store, uuid, text_update("hi"), %{},
          signing_context: ctx
        )

      assert %Commit{} = commit
      assert {:ok, _} = CommitStore.get_commit(store, commit.id)
    end
  end

  # ── Pin 4: strict + system snapshot/merge (node-signed) lands ────────
  describe "pin 4: node-signed system commits land under strict + enforce" do
    test "create_snapshot_commit lands (phase 2.5 with_local_node_trust)", %{store: store} do
      strict!()
      enforce!()
      uuid = UUID.uuid4()

      # The base write itself must ALSO pass the gate under strict+enforce
      # — sign it with the node's own identity (auto-trusted via
      # `with_local_node_trust/1`) so this test isolates pin 4's actual
      # claim (the SNAPSHOT is what phase 2.5 node-signs and what must
      # land) rather than tripping on an unrelated unsigned-base-write
      # rejection.
      {:ok, node_ctx} = NodeIdentity.signing_context()

      commit =
        CommitStore.create_commit(store, uuid, text_update("v1"), nil, %{},
          signing_context: node_ctx
        )

      assert %Commit{} = commit

      assert {:ok, snap} = CommitStore.snapshot(store, uuid)
      assert snap.metadata.kind == :snapshot
      assert snap.signature != nil
    end
  end

  # ── Pin 5: genesis exemption ───────────────────────────────────────────
  describe "pin 5: genesis exemption" do
    test "an explicit genesis-kind write is exempt from the gate even unsigned+strict", %{
      store: store
    } do
      strict!()
      enforce!()
      uuid = UUID.uuid4()
      genesis = Commit.genesis(uuid)

      commit =
        CommitStore.create_commit(store, uuid, genesis.update, nil, genesis.metadata)

      assert %Commit{} = commit
      assert commit.signature == nil
    end

    test "genesis rides only when the gated first-write commit passes: denied write leaves no genesis row",
         %{store: store} do
      strict!()
      enforce!()
      uuid = UUID.uuid4()

      assert {:error, {:trust_rejected, :unsigned}} =
               CommitStoreClient.create_chained_commit(store, uuid, text_update("first"))

      assert :none = CommitStore.latest_commit(store, uuid)
      genesis_id = Commit.genesis(uuid).id
      assert :none = CommitStore.get_commit(store, genesis_id)
    end

    test "genesis rides along atomically when the gated first-write commit passes", %{
      store: store,
      pub: pub,
      identity: identity,
      ctx: ctx
    } do
      strict!(%{identity => Signing.encode_key(pub)})
      enforce!()
      uuid = UUID.uuid4()

      commit =
        CommitStoreClient.create_chained_commit(store, uuid, text_update("first"), %{},
          signing_context: ctx
        )

      assert %Commit{} = commit
      genesis_id = Commit.genesis(uuid).id
      assert {:ok, _} = CommitStore.get_commit(store, genesis_id)
    end
  end

  # ── Pin 6: dry-run — would-deny logged + telemetry, write still lands ─
  describe "pin 6: dry_run mode" do
    test "would-deny is logged via telemetry but the write still lands", %{store: store} do
      strict!()
      dry_run!()
      uuid = UUID.uuid4()

      ref = make_ref()
      parent = self()

      # Same uuid filter as pin 2 — the event is node-global and this
      # pin has the same first-event-is-mine assumption to lose.
      :telemetry.attach(
        {:lwg_dryrun_handler, ref},
        [:commonplace, :commit, :rejected, :local_trust],
        fn _event, meas, %{doc_uuid: event_uuid} = meta, _cfg ->
          if event_uuid == uuid, do: send(parent, {:lwg_dryrun, ref, meas, meta})
        end,
        nil
      )

      commit = CommitStore.create_commit(store, uuid, text_update("secret"), nil)
      assert %Commit{} = commit
      assert {:ok, _} = CommitStore.get_commit(store, commit.id)

      assert_receive {:lwg_dryrun, ^ref, _meas, %{doc_uuid: ^uuid} = meta}, 500
      assert meta.mode == :dry_run
      assert meta.reason == :unsigned

      :telemetry.detach({:lwg_dryrun_handler, ref})
    end

    test "dry_run is the implicit default (no explicit config)", %{store: store} do
      strict!()
      Application.delete_env(:commonplace, :local_write_gate)
      uuid = UUID.uuid4()

      commit = CommitStore.create_commit(store, uuid, text_update("secret"), nil)
      assert %Commit{} = commit
    end
  end

  # ── :off — emergency escape hatch ─────────────────────────────────────
  describe ":off skips the check entirely" do
    test "an unsigned write lands under strict config when the knob is :off", %{store: store} do
      strict!()
      off!()
      uuid = UUID.uuid4()

      commit = CommitStore.create_commit(store, uuid, text_update("secret"), nil)
      assert %Commit{} = commit
    end
  end

  # ── Pin 7: the write/execute fence ────────────────────────────────────
  #
  # The DEVIATION previously documented here — `walk_contributors/4`
  # (trust.ex) dropping its `store` argument on the way into the
  # capability path, and `VerifyChain.build_chain` calling bare
  # `CommitStore.get_capability/2` (unnormalized), so the Gate-B walk
  # broke on any NON-default store — was fixed by CX-ziye (the store is
  # now threaded through `authorized?/5`, and capability fetches route
  # through `CommitStoreClient.get_capability/2`). Dedicated regression
  # pins live in
  # `test/commonplace/trust/execute_capability_named_store_test.exs`.
  #
  # This pin now exercises the fence BOTH ways: via `Trust.authorized?/5`
  # directly (the exact per-commit call Gate B's walk makes) AND via the
  # end-to-end `authorized_to_execute?/3` convenience wrapper on this
  # test's named non-default store — the intended call surface that the
  # pre-fix defect forced this pin to avoid.
  describe "pin 7: write/execute fence" do
    test "the local-write gate forks on content: a :write-only signer's DATA write lands but their RAW-CODE write is denied (needs :execute)",
         %{store: store} do
      {root_pub, root_priv} = Signing.generate_keypair()

      root_ctx = %SigningContext{
        identity_uuid: "root",
        private_key: root_priv,
        public_key: root_pub
      }

      {alice_pub, alice_priv} = Signing.generate_keypair()

      alice_ctx = %SigningContext{
        identity_uuid: "alice",
        private_key: alice_priv,
        public_key: alice_pub
      }

      cfg = %{
        accept_unsigned: false,
        trusted_identities: %{"root" => Signing.encode_key(root_pub)}
      }

      Application.put_env(:commonplace, :trust, cfg)
      enforce!()

      text_uuid = UUID.uuid4()
      code_uuid = UUID.uuid4()

      {:ok, leaf} =
        Capability.issue(
          root_ctx,
          {"alice", alice_pub},
          %{verbs: [:write], scope: {:docs, [text_uuid, code_uuid]}, caveats: %{}}
        )

      :ok = CommitStore.store_capability(store, leaf)

      # CX-fogy: the local-write gate now FORKS on content (the RCE write-fork,
      # `Trust.authorized_to_write?`). A DATA write needs only `:write` — alice's
      # cap grants it, so this lands through the REAL gated seam
      # (`CommitStore.create_commit` → `do_write_commit` → `local_write_gate_
      # check/2`).
      text_commit =
        CommitStore.create_commit(
          store,
          text_uuid,
          text_update("just prose"),
          nil,
          %{kind: :regular, capability_proof: leaf.id},
          signing_context: alice_ctx
        )

      assert %Commit{} = text_commit
      assert {:ok, _} = CommitStore.get_commit(store, text_commit.id)

      code_doc = Yelixer.Doc.new() |> ContentType.create(:text, "code.ex")

      code_doc =
        ContentType.insert_text(code_doc, 0, "defmodule Evil do\n  def run, do: :rm_rf\nend")

      code_update = Yelixer.Encoding.encode_update(code_doc)

      # The SAME :write-only signer writing RAW CODE is now DENIED at the local-
      # write gate itself: CX-fogy classifies a raw-code after-state as requiring
      # `:execute` (Gate-B, node-only), and alice's cap grants only `:write`. This
      # is the write/execute fence, enforced at the WRITE seam (a strengthening
      # over the pre-CX-fogy content-blind gate that let raw code land and relied
      # on Gate-B at read time) — a `:write` cap can never mint raw executable
      # code. (A valid SANDBOXED safe-verb would instead fork to `:define_verb`;
      # this raw `defmodule` is neither data nor a safe-verb → `:execute`.)
      assert {:error, {:trust_rejected, :capability_insufficient}} =
               CommitStore.create_commit(
                 store,
                 code_uuid,
                 code_update,
                 nil,
                 %{kind: :regular, capability_proof: leaf.id},
                 signing_context: alice_ctx
               )

      # Nothing landed on the code doc — the gate refused the write outright.
      assert :none = CommitStore.latest_commit(store, code_uuid)

      # It is an AUTHORITY fence, not a blanket content ban: the NODE / an
      # execute-authority signer (root, pinned in `trusted_identities`) CAN write
      # the identical raw code — the trusted-identity path authorizes it
      # regardless of the content fork.
      root_code_commit =
        CommitStore.create_commit(
          store,
          code_uuid,
          code_update,
          nil,
          %{kind: :regular},
          signing_context: root_ctx
        )

      assert %Commit{} = root_code_commit
      assert {:ok, _} = CommitStore.get_commit(store, root_code_commit.id)
    end
  end

  # ── Pin 8: no-bypass enumeration ───────────────────────────────────────
  describe "pin 8: no-bypass sweep" do
    test "every function requesting commit row pairs is a known gated or synthetic writer" do
      source = File.read!("lib/commonplace/store/commit_store.ex")
      lines = String.split(source, "\n")

      # Walk the file top-to-bottom, tracking which top-level `def`/`defp`
      # we're currently inside (2-space indented — this module's only
      # indentation level for definitions), and record every function that
      # requests a commit/index row pair from the single commit_rows/1
      # constructor. The constructor itself is pinned by
      # DocCommitIndexTest; this sweep pins the authority paths reaching it.
      #
      # ⚠️ THIS SWEEP NO LONGER SEES INLINE ROW CONSTRUCTION AT ALL. It
      # matches calls to commit_rows/1, so a writer that hand-builds
      # `{{:commit, id}, commit}` is INVISIBLE here. That half of pin 8's
      # original coverage now lives in DocCommitIndexTest's whole-app
      # commit-row boundary checker. That checker distinguishes writes from
      # read patterns and enumerates the two justified production writers;
      # its tamper control injects a third-module raw writer and proves the
      # checker names it while this caller sweep remains intentionally blind.
      # ⇒ If that perimeter is ever relaxed, THIS TRIPWIRE LOSES ITS BASE.
      def_re = ~r/^  def(p)?\s+([a-zA-Z_][a-zA-Z0-9_?!]*)/

      {_current, writers} =
        Enum.reduce(lines, {nil, MapSet.new()}, fn line, {current, acc} ->
          current =
            case Regex.run(def_re, line) do
              [_, _, name] -> name
              nil -> current
            end

          acc =
            if current && current != "commit_rows" && String.contains?(line, "commit_rows(") do
              MapSet.put(acc, current)
            else
              acc
            end

          {current, acc}
        end)

      # The complete, hand-verified set of functions allowed to request
      # a commit/index row pair (verified by inspection at bead-
      # authoring time — CX-qat5.3):
      #
      #   * do_write_commit      — legacy serialized create path, GATED
      #                            by local_write_gate_check/2.
      #   * handle_call/3 (put_built_commit clause is unnamed by this
      #     regex — Elixir `handle_call` overloads all share the name
      #     "handle_call", so this set collapses every gated/CAS
      #     handle_call clause under one name) — GATED
      #     (put_built_commit), and NOT user-write-gated
      #     (write_snapshot_cas / write_prebuilt_commit_cas — see
      #     moduledoc "Signing": these sit ABOVE the build pipeline and
      #     only system-minted deterministic-anyone commits reach them).
      #   * do_store_imported    — import_commit's landing verb, gated
      #                            by the SEPARATE, pre-existing Gate A
      #                            (trust_check/2 via import_validation/3).
      #   * put_bare_commit_with_index — the shared persistence mechanism
      #                            for imported siblings and synthetic genesis;
      #                            its callers are pinned separately below.
      expected =
        MapSet.new([
          "do_write_commit",
          "handle_call",
          "do_store_imported",
          "put_bare_commit_with_index"
        ])

      assert writers == expected,
             "commit-row pair request sites changed: found #{inspect(MapSet.to_list(writers))}, " <>
               "expected exactly #{inspect(MapSet.to_list(expected))}. If you added a new local-write " <>
               "path that requests a commit row pair, it MUST run through " <>
               "local_write_gate_check/2 (mirroring do_write_commit / the put_built_commit " <>
               "handle_call clause) before persisting — this test is the tripwire."

      # The bare helper is not an authority decision of its own. Pin its two
      # callers so a new path cannot gain persistence merely by reusing it.
      {_current, bare_callers} =
        Enum.reduce(lines, {nil, MapSet.new()}, fn line, {current, acc} ->
          current =
            case Regex.run(def_re, line) do
              [_, _, name] -> name
              nil -> current
            end

          acc =
            if current && current != "put_bare_commit_with_index" &&
                 String.contains?(line, "put_bare_commit_with_index(") do
              MapSet.put(acc, current)
            else
              acc
            end

          {current, acc}
        end)

      assert bare_callers == MapSet.new(["handle_call", "do_store_imported"])

      # Positive control: the sweep must see all current pair requests (the
      # piggybacked-genesis paths each contain two calls).
      pair_request_lines =
        Enum.count(lines, fn line -> String.contains?(line, "commit_rows(") end) - 1

      assert pair_request_lines == 8,
             "expected 8 commit_rows/1 request lines across the seven write sites; " <>
               "found #{pair_request_lines}"
    end
  end
end
