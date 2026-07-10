defmodule Commonplace.MCP.Tools.CatTest do
  @moduledoc """
  CX-re6b round 16: cat structured-payload size cap (OOM defense).

  CX-ivqz (read-scoping P2, Seam 2.2): cat is now a gated by-uuid read
  surface. `run/2` consults `Trust.Read.authorized?` with the target's
  carried visibility/owner and the SERVER-RESOLVED session identity. This
  suite proves: public/absent docs read for anyone (no-regression); a
  capability_gated room reads for its owner but returns a not-found-shaped
  error to strangers; the denied response is byte-identical to a truly
  nonexistent uuid (existence-hiding); and a client-smuggled identity in
  `arguments` has no effect (attack Z6).
  """
  use ExUnit.Case, async: false

  alias Commonplace.Crypto.SigningContext
  alias Commonplace.Crypto.Signing
  alias Commonplace.Document.ContentType
  alias Commonplace.MCP.Tools.Cat
  alias Commonplace.MUD.Schemas
  alias Commonplace.MUD.Schemas.Room
  alias Commonplace.Store.CommitStore

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_cat_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    name = :"commit_store_cat_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: name})

    # CX-ivqz: the read gate only DENIES under enforce (accept_unsigned:
    # false) — the same posture P1's read_test uses. Under the permissive
    # default, Trust.reader_authorized? short-circuits to allow (matching
    # the write gate). Public docs short-circuit BEFORE the trust check, so
    # the no-regression tests pass under enforce too.
    #
    # Save/restore under the REAL app-env key names (CX-6hxa: a shorthand
    # restore-map key leaks env across files).
    old_trust = Application.get_env(:commonplace, :trust)
    Application.put_env(:commonplace, :trust, %{accept_unsigned: false, trusted_identities: %{}})

    on_exit(fn ->
      if is_nil(old_trust) do
        Application.delete_env(:commonplace, :trust)
      else
        Application.put_env(:commonplace, :trust, old_trust)
      end

      File.rm_rf!(dir)
    end)

    # CommitStoreClient has no per-call store override — it routes via a
    # pinned store name. We can't intercept the dispatch without an
    # injection layer, so these tests start the production-named store
    # and tear it down between tests.
    %{store: name, dir: dir}
  end

  defp create_text_doc(store, content) do
    uuid = UUID.uuid4()
    doc = Yelixer.Doc.new()
    doc = ContentType.create(doc, :text, "test")
    doc = ContentType.insert_text(doc, 0, content)
    update = Yelixer.Encoding.encode_update(doc)
    CommitStore.create_commit(store, uuid, update, nil)
    uuid
  end

  defp create_room_doc(store, room) do
    create_text_doc(store, Schemas.encode_room(room))
  end

  defp identity_ctx(id) do
    {pub, priv} = Signing.generate_keypair()
    %{signing_context: %SigningContext{identity_uuid: id, public_key: pub, private_key: priv}}
  end

  describe "run/2 — content & size cap (no-regression)" do
    test "tiny text doc returns content in structured payload" do
      uuid = create_text_doc(Commonplace.Store.CommitStore, "hello")

      assert {:ok, response} = Cat.run(%{"uuid" => uuid}, %{})

      structured =
        response["content"]
        |> Enum.at(1)
        |> Map.get("text")
        |> Jason.decode!()

      assert structured["content"] == "hello"
      refute Map.has_key?(structured, "truncated")
    end

    # Defense against OOM mid-IO.write: when content exceeds the cap,
    # replace it with a {size_bytes, truncated, preview} summary so the
    # serialized response never approaches a memory-pressure threshold.
    test "oversized text content is truncated with a summary" do
      big_blob = :binary.copy("x", 200_000)
      uuid = create_text_doc(Commonplace.Store.CommitStore, big_blob)

      assert {:ok, response} = Cat.run(%{"uuid" => uuid}, %{})

      structured =
        response["content"]
        |> Enum.at(1)
        |> Map.get("text")
        |> Jason.decode!()

      assert structured["truncated"] == true
      assert structured["size_bytes"] == 200_000
      assert is_binary(structured["preview"])
      assert byte_size(structured["preview"]) <= 4_096
      refute structured["content"] == big_blob
    end

    test "missing uuid returns clean not_found" do
      assert {:error, "not found: " <> _} =
               Cat.run(%{"uuid" => "00000000-0000-0000-0000-000000000000"}, %{})
    end

    test "non-string uuid returns invalid_params" do
      assert {:error, :invalid_params, _} = Cat.run(%{"uuid" => 42}, %{})
    end

    test "public doc reads for an unauthenticated (empty-context) reader" do
      uuid = create_text_doc(Commonplace.Store.CommitStore, "public prose")
      assert {:ok, _response} = Cat.run(%{"uuid" => uuid}, %{})
    end
  end

  describe "read gate — capability_gated room (Seam 2.2)" do
    setup do
      owner = "owner-#{:rand.uniform(999_999_999)}"

      uuid =
        create_room_doc(Commonplace.Store.CommitStore, %Room{
          name: "Private Home",
          description: "cozy",
          owner: owner,
          visibility: :capability_gated
        })

      %{owner: owner, gated_uuid: uuid}
    end

    test "the OWNER's server-resolved identity may read the gated room", %{
      owner: owner,
      gated_uuid: uuid
    } do
      assert {:ok, _response} = Cat.run(%{"uuid" => uuid}, identity_ctx(owner))
    end

    test "a STRANGER gets the not-found-shaped error (never the content)", %{gated_uuid: uuid} do
      stranger = "stranger-#{:rand.uniform(999_999_999)}"
      assert {:error, "not found: " <> ^uuid} = Cat.run(%{"uuid" => uuid}, identity_ctx(stranger))
    end

    test "an UNAUTHENTICATED (empty-context) reader is denied with the not-found shape", %{
      gated_uuid: uuid
    } do
      assert {:error, "not found: " <> ^uuid} = Cat.run(%{"uuid" => uuid}, %{})
    end

    test "existence-hiding: denied response is byte-identical to a truly nonexistent uuid" do
      owner = "owner-#{:rand.uniform(999_999_999)}"

      gated =
        create_room_doc(Commonplace.Store.CommitStore, %Room{
          name: "Secret",
          description: "shh",
          owner: owner,
          visibility: :capability_gated
        })

      nonexistent = "11111111-2222-3333-4444-555555555555"

      denied = Cat.run(%{"uuid" => gated}, %{})
      absent = Cat.run(%{"uuid" => nonexistent}, %{})

      # Same {:error, "not found: <uuid>"} shape — the ONLY difference is
      # the uuid echoed back, which the client already supplied. A denied
      # stranger cannot distinguish "gated" from "does not exist".
      assert {:error, "not found: " <> ^gated} = denied
      assert {:error, "not found: " <> ^nonexistent} = absent
      assert elem(denied, 0) == elem(absent, 0)
    end

    test "Z6: an identity smuggled into the arguments map has NO effect (still denied)", %{
      owner: owner,
      gated_uuid: uuid
    } do
      # Client claims to BE the owner via arguments — but identity is only
      # ever taken from the server-resolved session context. Empty context
      # ⇒ unauthenticated ⇒ denied, regardless of the smuggled fields.
      args = %{"uuid" => uuid, "identity" => owner, "identity_uuid" => owner}
      assert {:error, "not found: " <> ^uuid} = Cat.run(args, %{})
    end
  end
end
