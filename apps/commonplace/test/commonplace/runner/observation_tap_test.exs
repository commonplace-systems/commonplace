defmodule Commonplace.Runner.ObservationTapTest do
  use ExUnit.Case, async: false

  alias Commonplace.Crypto.{Signing, SigningContext}
  alias Commonplace.Document.ContentType
  alias Commonplace.Runner.ObservationTap
  alias Commonplace.Store.{CommitStore, CommitStoreClient}
  alias Commonplace.Tree.{DocBuilder, Schema, Walk}

  setup do
    root = Path.join(System.tmp_dir!(), "cp_o1_tap_#{UUID.uuid4()}")
    checkout_dir = Path.join(root, "checkout")
    registry_root = Path.join(root, "observations")
    store_dir = Path.join(root, "store")
    File.mkdir_p!(checkout_dir)
    File.mkdir_p!(registry_root)
    File.mkdir_p!(store_dir)

    store = :"o1_tap_store_#{System.unique_integer([:positive])}"
    start_supervised!({CommitStore, data_dir: store_dir, name: store})

    {public_key, private_key} = Signing.generate_keypair()

    runner = %SigningContext{
      identity_uuid: "fixture-runner",
      public_key: public_key,
      private_key: private_key
    }

    on_exit(fn -> File.rm_rf!(root) end)

    %{
      checkout_dir: checkout_dir,
      deployment_id: "deployment-o1",
      registry_root: registry_root,
      runner: runner,
      sha: String.duplicate("a", 40),
      store: store
    }
  end

  test "tap ignores a remote entry by name and leaves checkout bytes unchanged", ctx do
    File.write!(Path.join(ctx.checkout_dir, "pod.txt"), "pod bytes\n")
    before = checkout_bytes(ctx.checkout_dir)
    tap = start_tap!(ctx)

    assert {:ok, %{inbound: :none}} = ObservationTap.sync_now(tap)
    root_uuid = ObservationTap.root_uuid(tap)

    remote_doc_uuid = UUID.uuid4()
    remote_doc = ContentType.create(Yelixer.Doc.new(), :text, "remote.txt")
    remote_doc = ContentType.insert_text(remote_doc, 0, "remote bytes\n")

    CommitStoreClient.create_commit(
      ctx.store,
      remote_doc_uuid,
      Yelixer.Encoding.encode_update(remote_doc),
      nil
    )

    {:ok, root_doc} = DocBuilder.reconstruct_snapshot(ctx.store, root_uuid)
    remote_root = Schema.add_file(root_doc, "remote.txt", remote_doc_uuid)

    CommitStoreClient.create_chained_commit(
      ctx.store,
      root_uuid,
      Yelixer.Encoding.encode_update(remote_root)
    )

    assert {:ok, %{inbound: {:ignored, ["remote.txt"]}}} = ObservationTap.sync_now(tap)
    assert checkout_bytes(ctx.checkout_dir) == before
    refute File.exists?(Path.join(ctx.checkout_dir, "remote.txt"))
  end

  test "tap mirrors create modify and delete through existing tree reads", ctx do
    tap = start_tap!(ctx)
    root_uuid = ObservationTap.root_uuid(tap)
    path = Path.join(ctx.checkout_dir, "live.txt")

    File.write!(path, "created\n")
    assert {:ok, %{outbound: outbound}} = ObservationTap.sync_now(tap)
    assert "live.txt" in outbound
    assert observed_text(ctx.store, root_uuid, "live.txt") == "created\n"

    File.write!(path, "modified\n")
    assert {:ok, %{outbound: ["live.txt"]}} = ObservationTap.sync_now(tap)
    assert observed_text(ctx.store, root_uuid, "live.txt") == "modified\n"

    File.rm!(path)
    assert {:ok, %{outbound: ["live.txt"]}} = ObservationTap.sync_now(tap)
    assert {:error, {:not_found, "live.txt"}} = lookup(root_uuid, "live.txt", ctx.store)
  end

  test "every reachable observation head is runner-signed and root metadata is unmistakable",
       ctx do
    File.write!(Path.join(ctx.checkout_dir, "witnessed.txt"), "seen\n")
    tap = start_tap!(ctx)
    assert {:ok, _report} = ObservationTap.sync_now(tap)
    root_uuid = ObservationTap.root_uuid(tap)

    assert {:ok, root_commit} = CommitStoreClient.latest_commit(ctx.store, root_uuid)

    assert root_commit.metadata == %{
             kind: :observation,
             witness: "runner-witnessed",
             verification: "UNVERIFIED WORKING STATE",
             harvest: "not-yet-harvested",
             deployment_id: ctx.deployment_id,
             sha: ctx.sha,
             path: "/pods/#{ctx.deployment_id}/live"
           }

    reachable = Walk.reachable_uuids(root_uuid, &load_doc(ctx.store, &1))

    for uuid <- reachable do
      assert {:ok, commit} = CommitStoreClient.latest_commit(ctx.store, uuid)

      assert commit.signer_id ==
               Signing.signer_id(ctx.runner.identity_uuid, ctx.runner.public_key)

      assert :ok = Signing.verify_commit(commit, ctx.runner.public_key)
    end
  end

  test "unregister reaps by default and retain preserves the labeled root", ctx do
    tap = start_tap!(ctx)
    descriptor = ObservationTap.descriptor_path(ctx.registry_root, ctx.deployment_id)
    assert File.regular?(descriptor)

    assert :ok = ObservationTap.unregister(tap, retain: false)
    refute File.exists?(descriptor)

    retained = start_tap!(%{ctx | deployment_id: "deployment-retained"})
    retained_descriptor = ObservationTap.descriptor_path(ctx.registry_root, "deployment-retained")
    assert :ok = ObservationTap.unregister(retained, retain: true)
    assert File.regular?(retained_descriptor)
  end

  defp start_tap!(ctx) do
    start_supervised!(
      {ObservationTap,
       checkout_dir: ctx.checkout_dir,
       deployment_id: ctx.deployment_id,
       sha: ctx.sha,
       store: ctx.store,
       signing_context: ctx.runner,
       registry_root: ctx.registry_root,
       interval_ms: 60_000},
      id: {ObservationTap, ctx.deployment_id}
    )
  end

  defp observed_text(store, root_uuid, path) do
    {:ok, uuid} = lookup(root_uuid, path, store)
    {:ok, doc} = DocBuilder.reconstruct_snapshot(store, uuid)
    ContentType.get_content(doc)
  end

  defp lookup(root_uuid, path, store) do
    Walk.resolve_path(root_uuid, path, &load_doc(store, &1))
  end

  defp load_doc(store, uuid) do
    case DocBuilder.reconstruct_snapshot(store, uuid) do
      {:ok, doc} -> doc
      :none -> nil
    end
  end

  defp checkout_bytes(dir) do
    dir
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.reject(&File.dir?/1)
    |> Map.new(fn path -> {Path.relative_to(path, dir), File.read!(path)} end)
  end
end
