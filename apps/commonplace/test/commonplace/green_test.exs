defmodule Commonplace.GreenTest do
  @moduledoc """
  CX-vfau (part b): unit tests for the `Commonplace.Green` author
  facade (thin delegation to `BursarClient`, `with_token/4`
  acquire/run/release-on-exception semantics), plus the reference
  composition — the brief-§6 reactive-exclusivity pattern, built from
  shipped parts only:

  a `Commonplace.Black.PatternCompute` whose `compute_fn` wraps its
  write in `Commonplace.Green.with_token/4` and, on `{:denied, info}`,
  calls `Commonplace.Black.emit_red/2` instead of writing new content.
  """

  use ExUnit.Case, async: false

  alias Commonplace.Black
  alias Commonplace.Black.PatternCompute
  alias Commonplace.CommandRouter
  alias Commonplace.Dataflow.PubSub, as: CPPubSub
  alias Commonplace.Document.ContentType
  alias Commonplace.Green
  alias Commonplace.Green.Bursar
  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.{DocBuilder, Schema}

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_green_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)

    store_name = :"commit_store_green_#{:rand.uniform(1_000_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store_name})

    router_name = :"router_green_#{:rand.uniform(1_000_000_000)}"
    start_supervised!({CommandRouter, name: router_name, store: store_name})

    bursar_root = mint_root(store_name)
    bursar_name = :"bursar_green_#{:rand.uniform(1_000_000_000)}"

    {:ok, bursar_pid} =
      Bursar.start_link(
        root_uuid: bursar_root,
        store: store_name,
        name: bursar_name,
        # keep TTL sweeps out of the way of these tests' timing
        sweep_interval: 60_000
      )

    on_exit(fn -> File.rm_rf!(dir) end)

    %{store: store_name, router: router_name, bursar: bursar_name, bursar_pid: bursar_pid}
  end

  # --- helpers (mirrors black_test.exs / pattern_compute_test.exs) ---

  defp mint_root(store) do
    root_uuid = UUID.uuid4()
    doc = Schema.new_schema()
    update = Yelixer.Encoding.encode_update(doc)
    CommitStore.create_commit(store, root_uuid, update, nil)
    root_uuid
  end

  defp mint_text_file(store, parent_uuid, name, content) do
    file_uuid = UUID.uuid4()
    doc = Yelixer.Doc.new()
    doc = ContentType.create(doc, :text, name)
    doc = if content != "", do: ContentType.insert_text(doc, 0, content), else: doc
    update = Yelixer.Encoding.encode_update(doc)
    CommitStore.create_commit(store, file_uuid, update, nil)
    add_entry(store, parent_uuid, name, file_uuid)
    file_uuid
  end

  defp add_entry(store, parent_uuid, name, node_uuid) do
    parent_doc = load_schema(store, parent_uuid)
    parent_doc = Schema.add_file(parent_doc, name, node_uuid)
    update = Yelixer.Encoding.encode_update(parent_doc)
    CommitStore.create_commit(store, parent_uuid, update, latest(store, parent_uuid))
  end

  defp latest(store, uuid) do
    case CommitStore.latest_commit(store, uuid) do
      {:ok, commit} -> commit.id
      _ -> nil
    end
  end

  defp load_schema(store, uuid) do
    case DocBuilder.reconstruct_snapshot(store, uuid) do
      {:ok, doc} -> doc
      :none -> Schema.new_schema()
    end
  end

  defp read_content(store, uuid) do
    case DocBuilder.reconstruct_snapshot(store, uuid) do
      {:ok, doc} -> ContentType.get_content(doc)
      :none -> nil
    end
  end

  defp edit_text_file(store, uuid, new_content) do
    {:ok, doc} = DocBuilder.reconstruct_doc(store, uuid)
    old_len = String.length(ContentType.get_content(doc) || "")
    doc = if old_len > 0, do: ContentType.delete_text(doc, 0, old_len), else: doc
    doc = ContentType.insert_text(doc, 0, new_content)
    update = Yelixer.Encoding.encode_update(doc)
    CommitStore.create_commit(store, uuid, update, latest(store, uuid))
  end

  defp wait_until(fun, deadline_ms \\ 2000) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    do_wait(fun, deadline)
  end

  defp do_wait(fun, deadline) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("timed out waiting for condition")
      else
        Process.sleep(25)
        do_wait(fun, deadline)
      end
    end
  end

  # --- facade delegation ---

  describe "acquire/release/renew/query delegate to BursarClient" do
    test "acquire/query/release round-trip", %{bursar: b} do
      assert {:ok, %{holder: "alice"}} = Green.acquire("a.txt", "alice", server: b)
      assert {:held, %{holder: "alice"}} = Green.query("a.txt", server: b)
      assert {:denied, %{holder: "alice"}} = Green.acquire("a.txt", "bob", server: b)
      assert :ok = Green.release("a.txt", "alice", server: b)
      assert :available = Green.query("a.txt", server: b)
    end

    test "acquire threads ttl through", %{bursar: b} do
      assert {:ok, %{ttl_ms: 5000}} = Green.acquire("a.txt", "alice", server: b, ttl: 5000)
    end

    test "release by non-holder fails", %{bursar: b} do
      assert {:ok, _} = Green.acquire("a.txt", "alice", server: b)
      assert {:error, {:not_holder, "alice"}} = Green.release("a.txt", "bob", server: b)
    end

    test "renew keeps or updates ttl", %{bursar: b} do
      assert {:ok, _} = Green.acquire("a.txt", "alice", server: b, ttl: 5000)
      assert {:ok, %{ttl_ms: 9000}} = Green.renew("a.txt", "alice", server: b, ttl: 9000)
    end

    test "query on an unheld path returns :available", %{bursar: b} do
      assert :available = Green.query("nope.txt", server: b)
    end

    test "with no server opt, defaults to Commonplace.Green.Bursar (unreachable here)" do
      # No Bursar named Commonplace.Green.Bursar is running in this test
      # process tree, so the default-server path fails closed exactly
      # like BursarClient's fail-closed posture (moduledoc "Fail-closed").
      assert {:error, :bursar_unavailable} = Green.acquire("a.txt", "alice")
    end
  end

  describe "with_token/4" do
    test "acquires, runs fun, releases — returns {:ok, fun result}", %{bursar: b} do
      assert {:ok, 42} =
               Green.with_token("claim", "alice", [server: b], fn -> 42 end)

      assert :available = Green.query("claim", server: b)
    end

    test "releases even when fun raises", %{bursar: b} do
      assert_raise RuntimeError, "boom", fn ->
        Green.with_token("claim", "alice", [server: b], fn -> raise "boom" end)
      end

      assert :available = Green.query("claim", server: b)
    end

    test "denies without running fun when contended", %{bursar: b} do
      assert {:ok, _} = Green.acquire("claim", "rival", server: b)

      ran = :ets.new(:ran, [:public])

      assert {:denied, %{holder: "rival"}} =
               Green.with_token("claim", "alice", [server: b], fn ->
                 :ets.insert(ran, {:ran, true})
               end)

      assert :ets.info(ran, :size) == 0
      # contended holder's token is untouched
      assert {:held, %{holder: "rival"}} = Green.query("claim", server: b)
    end

    test "re-acquiring your own held token is idempotent (not a denial)", %{bursar: b} do
      assert {:ok, _} = Green.acquire("claim", "alice", server: b)

      assert {:ok, :ran} =
               Green.with_token("claim", "alice", [server: b], fn -> :ran end)

      assert :available = Green.query("claim", server: b)
    end
  end

  # --- the reference composition (spec §3) ---

  describe "reactive-exclusivity reference composition (brief §6)" do
    test "first trigger acquires and computes; a racing holder is denied and observed via red",
         %{store: store, router: router, bursar: bursar} do
      root = mint_root(store)
      _f1 = mint_text_file(store, root, "a.txt", "one")
      target = mint_text_file(store, root, "_target", "initial")

      claim_path = "claims/#{target}"
      compute_holder = "compute-owner"

      compute_fn = fn matches, ctx ->
        case Green.with_token(claim_path, compute_holder, [server: bursar], fn ->
               matches |> Enum.map(& &1.path) |> Enum.sort() |> Enum.join(",")
             end) do
          {:ok, rendered} ->
            rendered

          {:denied, info} ->
            Black.emit_red(target, %{
              kind: :claim_denied,
              claim_path: claim_path,
              held_by: info.holder
            })

            read_content(ctx.store, target)
        end
      end

      {:ok, pid} =
        PatternCompute.start_link(
          root_uuid: root,
          pattern: "*.txt",
          target_uuid: target,
          compute_fn: compute_fn,
          store: store,
          router: router
        )

      # First trigger (init) acquires the claim (nobody else holds it)
      # and computes — target gets the rendered match list, and the
      # claim is released again immediately after (with_token's
      # after-clause), so nothing is left held.
      :ok = wait_until(fn -> read_content(store, target) == "a.txt" end)
      assert :available = Green.query(claim_path, server: bursar)

      # Now a rival holder claims the SAME path out from under the
      # compute, simulating a genuinely racing acquirer.
      assert {:ok, _} = Green.acquire(claim_path, "rival", server: bursar)

      topic = "red:#{target}"
      CPPubSub.subscribe_red(target)

      # Trigger a recompute: editing a matched doc's content re-runs
      # compute_fn against the current match list (test 4a's pattern
      # in pattern_compute_test.exs) without changing the match set.
      f1_uuid = PatternCompute.state(pid).matches |> hd() |> Map.get(:uuid)
      edit_text_file(store, f1_uuid, "one edited")

      assert_receive {^topic, {:black, :signal, %{payload: payload}}}, 2000
      assert payload == %{kind: :claim_denied, claim_path: claim_path, held_by: "rival"}

      # Denied — target content is left unchanged (compute_fn falls
      # back to the current content rather than writing).
      assert read_content(store, target) == "a.txt"

      # Release the rival; the next recompute succeeds again.
      assert :ok = Green.release(claim_path, "rival", server: bursar)
      edit_text_file(store, f1_uuid, "one edited again")

      :ok = wait_until(fn -> read_content(store, target) == "a.txt" end)

      GenServer.stop(pid)
    end
  end
end
