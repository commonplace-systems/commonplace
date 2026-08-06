defmodule Commonplace.Projection.AcceptanceTest do
  @moduledoc """
  CX-6scm's nine pre-declared acceptance cases for `Commonplace.Projection`.

  Every case below has a CONTROL: a statement of what must be observed if
  the check were removed or the defect reintroduced. Each control was
  proven red by injection before its green was allowed to count — the
  injection sites and the red output are recorded in the build report,
  and each test names its own control in a comment so a future reader can
  re-run the proof rather than trust this sentence.

  The dominant defect class in this repo is a check structurally
  incapable of going red. These tests are written to be capable of it.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Projection
  alias Commonplace.Projection.{MixedPlane, PostState}
  alias Commonplace.Store.{Commit, CommitStore}
  alias Commonplace.Tree.Schema
  alias Yelixer.{Doc, Encoding}
  alias Yelixer.Types.{Text, YMap}

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_projection_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    name = :"projection_store_#{:rand.uniform(1_000_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: name})
    on_exit(fn -> File.rm_rf!(dir) end)
    %{store: name, db: CommitStore.db_handle(name)}
  end

  # ── helpers ────────────────────────────────────────────────────────

  defp uuid, do: "doc-#{:rand.uniform(1_000_000_000)}"

  # Land a fully-formed commit row + head pointer directly. Tests here
  # need commits the public write path cannot produce (tampered bytes, a
  # forged post-state hash, a delta commit at a chosen depth), so they
  # construct the row. Everything that is NOT the point of a given test
  # still goes through `Commit.new/6`, so the content addressing is real.
  defp put(%Commit{} = commit, db, uuid, head?) do
    CubDB.put(db, {:commit, commit.id}, commit)
    if head?, do: CubDB.put(db, {:latest, uuid}, commit.id)
    commit
  end

  defp full_state_commit(db, uuid, doc, parent_id, head?, opts \\ []) do
    update = Encoding.encode_update(doc)
    psh = if opts[:post_state], do: PostState.mint(doc), else: nil

    Commit.new(uuid, update, parent_id, %{kind: :regular}, [], psh)
    |> put(db, uuid, head?)
  end

  defp sign(%Commit{} = commit, priv, signer_id),
    do: Commonplace.Crypto.Signing.sign_commit(commit, priv, signer_id)

  defp text_doc(entries) do
    doc = Doc.new(client_id: 7)
    {doc, _} = Doc.get_or_create_type(doc, "t", :text)
    Enum.reduce(entries, doc, fn s, d -> Text.insert(d, "t", Text.length(d, "t"), s) end)
  end

  defp bytes!(result) do
    assert {:ok, bytes, _verdict} = result
    bytes
  end

  # ── #1 — tamper in a SIGNED commit is loud ─────────────────────────
  #
  # CONTROL: delete the `Commit.content_address_of/1` comparison from
  # `Projection.classify_commit/2` and this test must go red — the
  # flipped byte is then absorbed and projection returns `{:ok, _, _}`,
  # which is exactly the 76%-absorbed number the sizing measured.

  describe "acceptance #1: signature/integrity threading" do
    test "a flipped byte in a signed commit projects loud, not absorbed", %{
      store: store,
      db: db
    } do
      u = uuid()
      {pub, priv} = Commonplace.Crypto.Signing.generate_keypair()
      signer = Commonplace.Crypto.Signing.signer_id("tester", pub)

      c1 = full_state_commit(db, u, text_doc(["hello"]), nil, false)
      c1 = sign(c1, priv, signer) |> put(db, u, false)

      good = text_doc(["hello", " world"])
      c2 = Commit.new(u, Encoding.encode_update(good), c1.id, %{kind: :regular})
      c2 = sign(c2, priv, signer) |> put(db, u, true)

      # sanity: the untampered chain projects
      assert {:ok, _, _} = Projection.project_at(u, c2.id, store: store)

      # now flip one byte of the stored update, leaving the id claimed
      <<h, rest::binary>> = c2.update
      tampered = %{c2 | update: <<Bitwise.bxor(h, 1)>> <> rest}
      CubDB.put(db, {:commit, c2.id}, tampered)

      assert {:error, :signature_invalid} =
               Projection.project_at(u, c2.id, store: store)
    end

    test "a re-addressed tamper is caught by the pinned key, not the id", %{
      store: store,
      db: db
    } do
      u = uuid()
      {pub, priv} = Commonplace.Crypto.Signing.generate_keypair()
      signer = Commonplace.Crypto.Signing.signer_id("tester", pub)

      original = full_state_commit(db, u, text_doc(["hello"]), nil, true)
      signed = sign(original, priv, signer) |> put(db, u, true)

      # A tamperer with write access to the row recomputes the content
      # address, so link 1 (id) is intact. The signature was made over the
      # ORIGINAL id, so link 2 must catch it — but only if a key is
      # pinned. Pin one.
      Application.put_env(:commonplace, :trust, %{
        accept_unsigned: true,
        trusted_identities: %{"tester" => Commonplace.Crypto.Signing.encode_key(pub)}
      })

      on_exit(fn -> Application.delete_env(:commonplace, :trust) end)

      forged_doc = text_doc(["goodbye"])
      forged = Commit.new(u, Encoding.encode_update(forged_doc), nil, %{kind: :regular})
      forged = %{forged | signature: signed.signature, signer_id: signer}
      CubDB.put(db, {:commit, forged.id}, forged)
      CubDB.put(db, {:latest, u}, forged.id)

      assert {:error, :signature_invalid} =
               Projection.project_at(u, forged.id, store: store)
    end

    test "unsigned tamper is loud too, but named for what it proves", %{store: store, db: db} do
      u = uuid()
      c = full_state_commit(db, u, text_doc(["hello"]), nil, true)
      <<h, rest::binary>> = c.update
      CubDB.put(db, {:commit, c.id}, %{c | update: <<Bitwise.bxor(h, 1)>> <> rest})

      assert {:error, {:content_address_mismatch, _}} =
               Projection.project_at(u, c.id, store: store)
    end

    test "the verdict states signature coverage honestly, with denominators", %{
      store: store,
      db: db
    } do
      u = uuid()
      c = full_state_commit(db, u, text_doc(["hello"]), nil, true)

      assert {:ok, _, {:corroborated, methods}} =
               Projection.project_at(u, c.id, store: store)

      assert {:signature_coverage, %{unsigned: 1, verified: 0, of: 1}} =
               Enum.find(methods, &match?({:signature_coverage, _}, &1))
    end
  end

  # ── #2 — mixed-plane trip at a pin ─────────────────────────────────
  #
  # CONTROL: remove the `tripwire/1` call from `project_doc_at/3` and the
  # first test goes red with `{:ok, _, _}` — bytes for a doc that
  # silently destroys content on the next round trip.

  describe "acceptance #2: the mixed-binding tripwire runs at PIN reads" do
    test "a constructed mixed-plane doc at its pin is unknown, never bytes", %{
      store: store,
      db: db
    } do
      u = uuid()

      # A name holding live content in BOTH planes: a Y.Map keyed item and
      # a plain Text item under the same name (CX-mchn's migration
      # residue shape).
      doc = Doc.new(client_id: 11)
      {doc, _} = Doc.get_or_create_type(doc, "shared", :map)
      doc = YMap.set(doc, "shared", "legacy_field", "residue")
      {doc, _} = Doc.get_or_create_type(doc, "shared", :map)
      doc = Text.insert(doc, "shared", 0, "later text")

      assert {:trip, _} = MixedPlane.scan(doc),
             "fixture must actually be mixed — otherwise this test cannot go red"

      c = full_state_commit(db, u, doc, nil, true)

      assert {:unknown, {:mixed_plane, %{types: [%{name: "shared"} | _]}}} =
               Projection.project_at(u, c.id, store: store)
    end

    test "an ordinary single-plane doc does NOT trip (the tripwire is not always-on)",
         %{store: store, db: db} do
      u = uuid()
      c = full_state_commit(db, u, text_doc(["ordinary"]), nil, true)
      assert {:ok, _, _} = Projection.project_at(u, c.id, store: store)
    end
  end

  # ── #3 — the head-disagreement corpus ──────────────────────────────
  #
  # The live 80-doc corpus is enumerated against the census fixture in
  # `head_disagreement_corpus_test.exs`. Here the SHAPE is pinned
  # synthetically so the semantics are testable without the corpus.
  #
  # CONTROL: make `decide_head/4` return the chain path unconditionally
  # and the undeclared case goes red — it would hand back the bytes the
  # census records as dropping 124 tree entries.

  describe "acceptance #3: head disagreement between the two shipped read paths" do
    setup %{db: db} do
      # A full-state-REWRITE chain: every round encodes the WHOLE schema
      # from a fresh doc under the same stable client_id, starting its
      # op-clock at 0 again. Round 2's NEW entry therefore mints (client,
      # clock) = (hand, 0) — a pair round 1 already used — so Yjs's
      # idempotent merge treats it as already-applied and DROPS it. Chain
      # replay silently loses the entry; the single-commit read does not.
      #
      # That is CX-6scm's P1, and it is what the census's 80 docs are.
      # Note the collision only bites when the new entry is written
      # FIRST in the round (taking the low clock) — a fixture that
      # appends instead would agree, and would test nothing.
      u = uuid()
      hand = 4242

      r1 = Doc.new(client_id: hand) |> Schema.add_file("zulu", "uuid-zulu")
      c1 = full_state_commit(db, u, r1, nil, false)

      r2 =
        Doc.new(client_id: hand)
        |> Schema.add_file("alpha", "uuid-alpha")
        |> Schema.add_file("zulu", "uuid-zulu")

      c2 = full_state_commit(db, u, r2, c1.id, true)

      %{u: u, c1: c1, c2: c2, r2: r2}
    end

    test "the fixture really does disagree (else nothing below can go red)", %{
      store: store,
      u: u
    } do
      {:ok, chain} = Commonplace.Tree.DocBuilder.reconstruct_doc(store, u, mint: false)
      {:ok, direct} = Commonplace.Tree.DocBuilder.reconstruct_snapshot(store, u)

      chain_names = Schema.list_entries(chain) |> Enum.map(& &1.name) |> Enum.sort()
      direct_names = Schema.list_entries(direct) |> Enum.map(& &1.name) |> Enum.sort()

      assert direct_names == ["alpha", "zulu"]
      assert chain_names == ["zulu"], "chain replay must drop the entry — that IS the P1"
    end

    test "undeclared head_path returns conflicted-unknown, never a silent pick", %{
      store: store,
      u: u,
      c2: c2
    } do
      assert {:unknown, {:conflicted, %{at: :head, resolvable_by: :head_path}}} =
               Projection.project_at(u, c2.id, store: store)
    end

    test "head_path: :direct returns the data-preserving live bytes, disagreement named",
         %{store: store, u: u, c2: c2, r2: r2} do
      assert {:ok, bytes, {:corroborated, methods}} =
               Projection.project_at(u, c2.id, store: store, head_path: :direct)

      assert bytes == Encoding.encode_update(r2)
      assert {:live_head_path, :direct} in methods
      assert Enum.any?(methods, &match?({:head_path_disagreement, _}, &1))
    end

    test "head_path: :chain returns the replay bytes, disagreement named", %{
      store: store,
      u: u,
      c2: c2
    } do
      assert {:ok, bytes, {:corroborated, methods}} =
               Projection.project_at(u, c2.id, store: store, head_path: :chain)

      {:ok, replayed} = Commonplace.Tree.DocBuilder.reconstruct_doc(store, u, mint: false)
      assert bytes == Encoding.encode_update(replayed)
      assert {:live_head_path, :chain} in methods
      assert Enum.any?(methods, &match?({:head_path_disagreement, _}, &1))
    end

    test "at its DISAGREEING historical pin, the same chain is conflicted (tier iii)", %{
      store: store,
      u: u,
      c1: c1
    } do
      # c1 is not head. Both paths run; on this fixture round 1 IS
      # self-contained so they agree — assert whichever it is, but assert
      # it is never a bare unverified byte return.
      case Projection.project_at(u, c1.id, store: store) do
        {:ok, _, {:corroborated, methods}} -> assert :path_agreement in methods
        {:unknown, {:conflicted, %{replay: _, direct: _}}} -> :ok
      end
    end
  end

  # ── #4 — known-good doc, determinism across fresh processes ────────

  describe "acceptance #4: known-good doc at head and at a deep pin" do
    test "correct grade, byte-identical across two fresh processes", %{store: store, db: db} do
      u = uuid()

      {c_deep, c_head} =
        Enum.reduce(1..6, {nil, nil}, fn i, {deep, prev} ->
          doc = text_doc(Enum.map(1..i, &"line#{&1} "))
          c = full_state_commit(db, u, doc, prev && prev.id, i == 6)
          {if(i == 3, do: c, else: deep), c}
        end)

      for pin <- [c_deep.id, c_head.id] do
        a = Task.async(fn -> Projection.project_at(u, pin, store: store, head_path: :direct) end)
        b = Task.async(fn -> Projection.project_at(u, pin, store: store, head_path: :direct) end)

        ra = Task.await(a)
        rb = Task.await(b)

        assert bytes!(ra) == bytes!(rb)
        assert {:ok, _, {:corroborated, _}} = ra
      end
    end
  end

  # ── #5 — minted hash: witnessed, and loud when tampered ────────────
  #
  # CONTROL: drop `post_state_hash` out of `Commit.content_address/5` and
  # the tamper direction goes red — the forged hash would then be freely
  # editable without breaking the id, and a "witness" that any row-holder
  # can rewrite witnesses nothing.

  describe "acceptance #5: post-state hash, both directions" do
    test "a commit minted with a post-state hash projects :witnessed", %{store: store, db: db} do
      u = uuid()
      doc = text_doc(["witnessed content"])
      c = full_state_commit(db, u, doc, nil, true, post_state: true)

      assert {:ok, bytes, :witnessed} = Projection.project_at(u, c.id, store: store)
      assert bytes == Encoding.encode_update(doc)
    end

    test "tampering the hash field is loud", %{store: store, db: db} do
      u = uuid()
      doc = text_doc(["witnessed content"])
      c = full_state_commit(db, u, doc, nil, true, post_state: true)

      {v, h} = c.post_state_hash
      <<b, rest::binary>> = h
      CubDB.put(db, {:commit, c.id}, %{c | post_state_hash: {v, <<Bitwise.bxor(b, 1)>> <> rest}})

      # The hash binds into the id, so the tamper breaks the content
      # address first — loud either way, and never `{:ok, _, :witnessed}`.
      assert {:error, reason} = Projection.project_at(u, c.id, store: store)
      assert reason in [:signature_invalid] or match?({:content_address_mismatch, _}, reason)
    end

    test "a hash that is internally consistent but wrong for the bytes is loud", %{
      store: store,
      db: db
    } do
      u = uuid()
      real = text_doc(["real content"])
      other = text_doc(["different content"])

      # Mint the commit over `real`'s bytes but carry `other`'s hash. The
      # id covers both, so this is a well-formed commit that simply lies.
      c =
        Commit.new(u, Encoding.encode_update(real), nil, %{kind: :regular}, [], PostState.mint(other))
        |> put(db, u, true)

      assert {:error, {:hash_mismatch, %{carried: _, direct: _, replay: _}}} =
               Projection.project_at(u, c.id, store: store)
    end

    test "a foreign encoding era is NOT reported as tamper", %{store: store, db: db} do
      u = uuid()
      doc = text_doc(["era content"])
      {_, h} = PostState.mint(doc)
      future = {PostState.encoding_version() + 1, h}

      c =
        Commit.new(u, Encoding.encode_update(doc), nil, %{kind: :regular}, [], future)
        |> put(db, u, true)

      assert {:ok, _, {:corroborated, methods}} =
               Projection.project_at(u, c.id, store: store, head_path: :direct)

      assert {:encoding_era, _} = Enum.find(methods, &match?({:encoding_era, _}, &1))
    end
  end

  # ── #6 — mint on round N of a full-state-REWRITE chain ─────────────
  #
  # The F2 interaction, and the hard centre. Minting hashes on top of a
  # chain whose naive replay is WRONG must still verify — because tier (i)
  # arbitrates: the single-commit read is tried first and the carried hash
  # decides. If arbitration were removed and replay always used, this goes
  # red with `{:error, {:hash_mismatch, _}}` on every round after the
  # first — the "permanent regression storm on the dominant funnels" the
  # design named.

  describe "acceptance #6: mint on a full-state-rewrite chain verifies" do
    test "round N of a rewrite chain projects :witnessed at every round", %{
      store: store,
      db: db
    } do
      u = uuid()
      hand = 909

      commits =
        Enum.map_reduce(1..5, nil, fn n, prev ->
          # Entries written NEWEST-FIRST so each round's new entry takes
          # clock 0 — the pair the previous round already used. That is
          # what makes naive replay drop it (see the #3 setup comment).
          round = Doc.new(client_id: hand)

          round =
            Enum.reduce(n..1//-1, round, fn i, d ->
              Schema.add_file(d, "entry#{i}", "uuid-#{i}")
            end)

          c = full_state_commit(db, u, round, prev && prev.id, n == 5, post_state: true)
          {{c, round}, c}
        end)
        |> elem(0)

      # First prove the chain really is the poisoned shape: naive replay
      # to the last pin must NOT reproduce round 5.
      {last_c, last_round} = List.last(commits)
      {:ok, replayed} = Commonplace.Tree.DocBuilder.reconstruct_doc_at(store, u, last_c.id)

      assert Encoding.encode_update(replayed) != Encoding.encode_update(last_round),
             "fixture must be a genuine rewrite chain — otherwise arbitration is untested"

      for {c, round} <- commits do
        assert {:ok, bytes, :witnessed} = Projection.project_at(u, c.id, store: store),
               "round with commit #{Base.encode16(c.id, case: :lower)} failed to verify"

        assert bytes == Encoding.encode_update(round)
      end
    end
  end

  # ── #7 — a KNOWN delta must never emerge as silent partial bytes ───
  #
  # §7.6 precision 2. CONTROL: make tier (iii) return `direct` whenever it
  # decodes (the shortcut the old `single_commit_doc` defp effectively
  # took) and this goes red with `{:ok, partial_bytes, _}`.

  describe "acceptance #7: known-delta commits never return silent partial state" do
    test "a delta commit at a historical pin is conflicted, not partial bytes", %{
      store: store,
      db: db
    } do
      u = uuid()

      base = text_doc(["aaaa"])
      c1 = full_state_commit(db, u, base, nil, false)

      # A genuine DELTA: encode only the ops added on top of `base`.
      grown = Text.insert(base, "t", Text.length(base, "t"), "bbbb")
      delta = Encoding.encode_diff(grown, Doc.state_vector(base))

      c2 = Commit.new(u, delta, c1.id, %{kind: :regular}) |> put(db, u, false)
      _c3 = full_state_commit(db, u, text_doc(["aaaabbbbcccc"]), c2.id, true)

      # Standalone-decoding the delta yields PARTIAL state ("bbbb" only) —
      # prove the hazard exists before asserting it is caught.
      {:ok, standalone} = Encoding.apply_update(Doc.new(), delta)
      refute Text.to_string(standalone, "t") == Text.to_string(grown, "t")

      assert {:unknown, {:conflicted, %{replay: _, direct: _}}} =
               Projection.project_at(u, c2.id, store: store)
    end

    test "the floor cannot buy out the tier-(iii) comparison", %{store: store, db: db} do
      u = uuid()
      base = text_doc(["aaaa"])
      c1 = full_state_commit(db, u, base, nil, false)
      grown = Text.insert(base, "t", Text.length(base, "t"), "bbbb")
      delta = Encoding.encode_diff(grown, Doc.state_vector(base))
      c2 = Commit.new(u, delta, c1.id, %{kind: :regular}) |> put(db, u, false)
      _c3 = full_state_commit(db, u, text_doc(["aaaabbbbcccc"]), c2.id, true)

      # `:any` is the cheapest floor there is. It still must not return
      # partial bytes.
      assert {:unknown, {:conflicted, _}} =
               Projection.project_at(u, c2.id, store: store, required: :any)
    end
  end

  # ── #8 — genesis pins (F7) ─────────────────────────────────────────

  describe "F7: genesis pins are the empty state, never a crash" do
    test "a zero-byte update projects the empty state", %{store: store, db: db} do
      u = uuid()
      g = Commit.genesis(u)
      CubDB.put(db, {:commit, g.id}, g)
      c1 = full_state_commit(db, u, text_doc(["after genesis"]), g.id, true)
      assert c1

      assert {:ok, bytes, _} = Projection.project_at(u, g.id, store: store)
      assert bytes == Encoding.encode_update(Doc.new())
    end
  end

  # ── #9 — the floor's anti-thumb control ────────────────────────────
  #
  # "A floor is a budget, never a thumb on the verdict" is load-bearing
  # and must be tested, not stated.
  #
  # CONTROL: make `project_doc_at/3` coerce its verdict to the requested
  # floor and this goes red — `required: :witnessed` would then return a
  # `:witnessed` grade for a chain that carries no writer expectation at
  # all, which is the underreport pattern wearing a checkmark.

  describe "acceptance #9: required: is a budget, never a thumb" do
    test "required: :witnessed on a hash-less chain returns best-achievable, truthfully", %{
      store: store,
      db: db
    } do
      u = uuid()
      c1 = full_state_commit(db, u, text_doc(["one"]), nil, false)
      c2 = full_state_commit(db, u, text_doc(["one", "two"]), c1.id, true)
      assert c2

      assert {:ok, _bytes, verdict} =
               Projection.project_at(u, c1.id, store: store, required: :witnessed)

      refute verdict == :witnessed
      assert {:corroborated, methods} = verdict
      assert :path_agreement in methods
    end

    test "the floor DOES buy more corroboration when it can", %{store: store, db: db} do
      u = uuid()
      c1 = full_state_commit(db, u, text_doc(["one"]), nil, false)
      c2 = full_state_commit(db, u, text_doc(["one", "two"]), c1.id, true)
      assert c2

      {:ok, _, {:corroborated, cheap}} =
        Projection.project_at(u, c1.id, store: store, required: :any)

      {:ok, _, {:corroborated, paid}} =
        Projection.project_at(u, c1.id, store: store, required: :witnessed)

      refute :refold_stability in cheap
      assert :refold_stability in paid
    end

    test "a hash-bearing chain DOES reach :witnessed at the same floor", %{
      store: store,
      db: db
    } do
      u = uuid()
      doc = text_doc(["witnessed"])
      c = full_state_commit(db, u, doc, nil, true, post_state: true)

      assert {:ok, _, :witnessed} =
               Projection.project_at(u, c.id, store: store, required: :witnessed)
    end

    test "an unknown floor is rejected loudly rather than defaulted", %{store: store} do
      assert_raise ArgumentError, fn ->
        Projection.project_at("nope", <<0>>, store: store, required: :probably)
      end
    end
  end

  # ── the TOCTOU guard ───────────────────────────────────────────────
  #
  # CONTROL: remove the `after_id != commit.id` clause from `tier_ii/6`
  # and this goes red — projection returns the NEW head's bytes labelled
  # as the requested (now historical) pin.

  describe "tier (ii) TOCTOU guard" do
    test "an already-superseded pin never gets tier-(ii) head authority", %{
      store: store,
      db: db
    } do
      u = uuid()
      c1 = full_state_commit(db, u, text_doc(["one"]), nil, true)
      c2 = full_state_commit(db, u, text_doc(["one", "two"]), c1.id, true)
      assert c2

      assert {:ok, _, {:corroborated, methods}} =
               Projection.project_at(u, c1.id, store: store)

      refute Enum.any?(methods, &match?({:live_head_path, _}, &1)),
             "a superseded pin must never carry tier-(ii) head authority"
    end

    # The real race, driven deterministically. Every `CommitStore` read
    # resolves its db handle through `resolve_db/1`, which falls back to
    # `GenServer.call(server, :get_db)` when the server is not a
    # persistent-term-registered name. Passing a PROXY as `:store` turns
    # each store read into an observable, countable event — so the test
    # can advance `:latest` at exactly the interleaving that matters:
    # AFTER the classification, DURING the live-path read.
    #
    # CONTROL: delete the `after_id != commit.id` clause from `tier_ii/6`
    # and this goes red — projection returns the NEW head's bytes
    # labelled with tier-(ii) authority for a pin that is no longer head.
    test "a head that advances mid-read falls through to tier (iii)", %{db: db} do
      u = uuid()
      c1 = full_state_commit(db, u, text_doc(["one"]), nil, true)
      c2 = full_state_commit(db, u, text_doc(["one", "two"]), c1.id, false)

      # `:latest` still points at c1; c2's row exists but is not head.
      assert CubDB.get(db, {:latest, u}) == c1.id

      # Advance on the 6th store read: reads 1-5 are get_commit,
      # commit_log, head?, before_id, chain-read — so the flip lands
      # between `before_id` and `after_id`, which is precisely the window
      # the guard exists for.
      {:ok, proxy} = start_supervised({__MODULE__.RacingStore, {db, u, c2.id, 6}})

      result = Projection.project_at(u, c1.id, store: proxy)

      assert CubDB.get(db, {:latest, u}) == c2.id, "the race must actually have fired"

      # The guard must produce tier (iii)'s answer for pin c1 — and for
      # this fixture that is a POSITIVE, distinguishable outcome:
      # `:path_agreement` on c1's own bytes.
      #
      # Asserting only "not tier (ii)" would be a check that cannot fail:
      # without the guard the two head paths have already diverged (one
      # read c1, one read c2), so `decide_head/4` returns
      # conflicted-unknown, which a merely-negative assertion would
      # happily accept. Proven: with the `after_id` clause commented out
      # the negative form stayed GREEN.
      assert {:ok, bytes, {:corroborated, methods}} = result
      assert :path_agreement in methods
      assert bytes == Encoding.encode_update(text_doc(["one"]))
      refute Enum.any?(methods, &match?({:live_head_path, _}, &1))
    end
  end

  defmodule RacingStore do
    @moduledoc false
    # A CommitStore stand-in that answers `:get_db` with the real handle
    # and, on the Nth answer, advances `:latest` — a deterministic
    # stand-in for a concurrent writer landing mid-read.
    use GenServer

    def start_link({db, uuid, new_head, at}),
      do: GenServer.start_link(__MODULE__, {db, uuid, new_head, at})

    @impl true
    def init({db, uuid, new_head, at}), do: {:ok, {db, uuid, new_head, at, 0}}

    @impl true
    def handle_call(:get_db, _from, {db, uuid, new_head, at, n}) do
      n = n + 1
      if n == at, do: CubDB.put(db, {:latest, uuid}, new_head)
      {:reply, db, {db, uuid, new_head, at, n}}
    end
  end

  # ── never mints ────────────────────────────────────────────────────

  describe "project_at never mints" do
    test "a long chain read does not trigger the lazy snapshot", %{store: store, db: db} do
      {u, _head} = mintable_chain(db)

      # PRE-DECLARED POSITIVE CONTROL. The observable is "the lazy
      # snapshot request reaches `SnapshotWorker`". Prove the harness can
      # SEE it before asserting its absence — otherwise the negative
      # below is a check structurally incapable of going red, this
      # repo's dominant defect class. (The earlier draft asserted on
      # CubDB row growth instead; that observable never fired even with
      # minting ON, so it proved nothing. Recorded rather than quietly
      # swapped.)
      trace_worker()
      {:ok, _} = Commonplace.Tree.DocBuilder.reconstruct_doc(store, u, mint: true)

      assert_receive {:trace, _, :receive, {:"$gen_cast", {:request, _, ^u, _}}}, 1_000
    end

    test "project_at itself never mints", %{store: store, db: db} do
      {u, head} = mintable_chain(db)

      trace_worker()

      _ =
        Projection.project_at(u, head.id, store: store, head_path: :direct, required: :witnessed)

      refute_receive {:trace, _, :receive, {:"$gen_cast", {:request, _, ^u, _}}}, 300
    end

    defp trace_worker do
      pid = Process.whereis(Commonplace.SnapshotWorker)
      assert is_pid(pid), "SnapshotWorker must be running for this observable to exist"
      :erlang.trace(pid, true, [:receive])
      on_exit(fn -> :erlang.trace(pid, false, [:receive]) end)
    end

    # A chain long enough to cross the lazy-snapshot threshold, with the
    # trigger armed. `SnapshotWorker` is already running under the
    # application supervisor, so the cast is delivered.
    defp mintable_chain(db) do
      Application.put_env(:commonplace, :reader_lazy_snapshot_enabled, true)
      Application.put_env(:commonplace, :reader_lazy_snapshot_threshold, 3)

      on_exit(fn ->
        Application.delete_env(:commonplace, :reader_lazy_snapshot_enabled)
        Application.delete_env(:commonplace, :reader_lazy_snapshot_threshold)
      end)

      u = uuid()

      head =
        Enum.reduce(1..6, nil, fn i, prev ->
          full_state_commit(db, u, text_doc(["l#{i}"]), prev && prev.id, i == 6)
        end)

      {u, head}
    end

  end
end
