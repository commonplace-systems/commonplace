defmodule Commonplace.TrustTest do
  # async: false — the config-loading tests mutate global application env
  # (:trust, :data_dir), which concurrently-running tests may read.
  use ExUnit.Case, async: false

  alias Commonplace.Crypto.Signing
  alias Commonplace.Store.Commit
  alias Commonplace.Trust

  # R1 semantics (design doc §2/§4, trust-and-attenuation.md): the gates call
  # ONLY Trust.authorized?(commit, verb, scope); the phase-1 body is a flat
  # allowlist of pinned identity→pubkey entries plus the accept_unsigned knob,
  # both from workspace-LOCAL config (never a synced doc). verb/scope are in
  # the signature now (phase-3 reshapes the body, not the callers) but the
  # allowlist body ignores them.

  setup do
    {pub, priv} = Signing.generate_keypair()
    identity = "11111111-1111-1111-1111-111111111111"
    signer_id = Signing.signer_id(identity, pub)

    commit = Commit.new("doc-uuid", "update bytes", nil)
    signed = Signing.sign_commit(commit, priv, signer_id)

    %{
      pub: pub,
      priv: priv,
      identity: identity,
      unsigned: commit,
      signed: signed,
      scope: {:doc, "doc-uuid"}
    }
  end

  defp config(accept_unsigned, trusted \\ %{}) do
    %{accept_unsigned: accept_unsigned, trusted_identities: trusted}
  end

  describe "unsigned commits" do
    test "pass when accept_unsigned is true", %{unsigned: c, scope: scope} do
      assert :ok = Trust.authorized?(c, :write, scope, config(true))
    end

    test "are rejected when accept_unsigned is false", %{unsigned: c, scope: scope} do
      assert {:error, :unsigned} = Trust.authorized?(c, :write, scope, config(false))
    end
  end

  describe "commits signed by a trusted identity" do
    test "pass with a valid signature in strict mode",
         %{signed: c, identity: id, pub: pub, scope: scope} do
      cfg = config(false, %{id => Signing.encode_key(pub)})
      assert :ok = Trust.authorized?(c, :write, scope, cfg)
    end

    test "pass with a valid signature in permissive mode",
         %{signed: c, identity: id, pub: pub, scope: scope} do
      cfg = config(true, %{id => Signing.encode_key(pub)})
      assert :ok = Trust.authorized?(c, :write, scope, cfg)
    end

    test "are rejected on signature forgery even in permissive mode",
         %{signed: c, identity: id, scope: scope} do
      # Claiming a trusted identity with a signature its pinned key did not
      # produce is forgery (or corruption) — no legitimate flow does this, so
      # it rejects in BOTH modes.
      {other_pub, _} = Signing.generate_keypair()
      cfg = config(true, %{id => Signing.encode_key(other_pub)})
      assert {:error, :invalid_signature} = Trust.authorized?(c, :write, scope, cfg)
    end

    test "pass if any of several pinned keys verifies",
         %{signed: c, identity: id, pub: pub, scope: scope} do
      {other_pub, _} = Signing.generate_keypair()
      cfg = config(false, %{id => [Signing.encode_key(other_pub), Signing.encode_key(pub)]})
      assert :ok = Trust.authorized?(c, :write, scope, cfg)
    end
  end

  describe "commits signed by an unknown identity" do
    test "pass in permissive mode (no worse off than unsigned)",
         %{signed: c, scope: scope} do
      assert :ok = Trust.authorized?(c, :write, scope, config(true))
    end

    test "are rejected in strict mode", %{signed: c, identity: id, scope: scope} do
      assert {:error, {:untrusted_signer, ^id}} =
               Trust.authorized?(c, :write, scope, config(false))
    end
  end

  describe "malformed signer_id" do
    test "treated like unknown signer: passes permissive, rejected strict",
         %{unsigned: c, priv: priv, scope: scope} do
      mangled = Signing.sign_commit(c, priv, "no-at-sign-here")
      assert :ok = Trust.authorized?(mangled, :write, scope, config(true))

      assert {:error, :invalid_signer_id} =
               Trust.authorized?(mangled, :write, scope, config(false))
    end
  end

  describe "config loading" do
    test "authorized?/3 reads config from the application env" do
      # The 3-arity head is what the gates call; it resolves config via
      # Trust.config/0 (app env override → trust.json in data_dir → default).
      commit = Commit.new("d", "u", nil)

      Application.put_env(:commonplace, :trust, %{
        accept_unsigned: false,
        trusted_identities: %{}
      })

      on_exit(fn -> Application.delete_env(:commonplace, :trust) end)

      assert {:error, :unsigned} = Trust.authorized?(commit, :write, {:doc, "d"})
    end

    test "defaults to permissive (accept_unsigned: true) when nothing is configured" do
      # Back-compat default-open per design doc §2; flips default-closed once
      # federation is live.
      assert %{accept_unsigned: true} = Trust.default_config()
    end

    test "config/0 auto-trusts the local node identity (phase 2.5)" do
      # The node trusts its OWN system-minted commits by construction —
      # its signing key is local-only and unforgeable by a peer — so a
      # single-node strict workspace needs zero pinning for node-signed
      # snapshots/merges. config/0 folds the node identity→pubkey in.
      tmp = Path.join(System.tmp_dir!(), "trust-node-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)

      old = Application.get_env(:commonplace, :data_dir)
      Application.put_env(:commonplace, :data_dir, tmp)

      Application.put_env(:commonplace, :trust, %{
        accept_unsigned: false,
        trusted_identities: %{}
      })

      on_exit(fn ->
        Application.put_env(:commonplace, :data_dir, old || "tmp/test_data")

        Application.delete_env(:commonplace, :trust)
        File.rm_rf!(tmp)
      end)

      {:ok, node_ctx} = Commonplace.Crypto.NodeIdentity.signing_context()

      cfg = Trust.config()
      assert Map.has_key?(cfg.trusted_identities, node_ctx.identity_uuid)

      # And a commit the node signs passes authorized? in strict mode.
      commit =
        Commit.new("d", "u", nil)
        |> Signing.sign_commit(
          node_ctx.private_key,
          Signing.signer_id(node_ctx.identity_uuid, node_ctx.public_key)
        )

      assert :ok = Trust.authorized?(commit, :write, {:doc, "d"}, cfg)
    end

    test "config/0 falls back to trust.json under data_dir" do
      tmp = Path.join(System.tmp_dir!(), "trust-cfg-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)

      File.write!(
        Path.join(tmp, "trust.json"),
        ~s({"accept_unsigned": false, "trusted_identities": {"some-uuid": "AAAA"}})
      )

      old = Application.get_env(:commonplace, :data_dir)
      Application.put_env(:commonplace, :data_dir, tmp)

      on_exit(fn ->
        Application.put_env(:commonplace, :data_dir, old || "tmp/test_data")

        File.rm_rf!(tmp)
      end)

      cfg = Trust.config()
      assert cfg.accept_unsigned == false
      # User pin survives; config/0 also folds in the local node identity
      # (phase 2.5), so assert the user entry is present rather than exact.
      assert cfg.trusted_identities["some-uuid"] == "AAAA"
    end
  end

  describe "posture/0 (CX-vyrs)" do
    setup do
      old_trust = Application.get_env(:commonplace, :trust)
      old_write_gate = Application.get_env(:commonplace, :local_write_gate)
      old_read_gate = Application.get_env(:commonplace, :local_read_gate)

      on_exit(fn ->
        if is_nil(old_trust),
          do: Application.delete_env(:commonplace, :trust),
          else: Application.put_env(:commonplace, :trust, old_trust)

        if is_nil(old_write_gate),
          do: Application.delete_env(:commonplace, :local_write_gate),
          else: Application.put_env(:commonplace, :local_write_gate, old_write_gate)

        if is_nil(old_read_gate),
          do: Application.delete_env(:commonplace, :local_read_gate),
          else: Application.put_env(:commonplace, :local_read_gate, old_read_gate)
      end)

      Application.delete_env(:commonplace, :trust)
      Application.delete_env(:commonplace, :local_write_gate)
      Application.delete_env(:commonplace, :local_read_gate)

      :ok
    end

    test "defaults: dry_run write gate, permissive read gate, not strict" do
      posture = Trust.posture()

      assert posture.local_write_gate == :dry_run
      assert posture.local_read_gate == :permissive
      assert posture.strict == false
    end

    test "reflects the resolved trust config's accept_unsigned and identity count" do
      Application.put_env(:commonplace, :trust, %{
        accept_unsigned: false,
        trusted_identities: %{"some-uuid" => "AAAA"}
      })

      posture = Trust.posture()

      assert posture.accept_unsigned == false
      # config/0 also folds in the local node identity (phase 2.5), so
      # assert at-least rather than an exact count (mirrors the
      # "config/0 falls back to trust.json" test's style above).
      assert posture.trusted_identities_count >= 1
    end

    test "strict is true only when accept_unsigned is false AND both gates are :enforce" do
      Application.put_env(:commonplace, :trust, %{
        accept_unsigned: false,
        trusted_identities: %{}
      })

      Application.put_env(:commonplace, :local_write_gate, :enforce)
      Application.put_env(:commonplace, :local_read_gate, :enforce)

      assert Trust.posture().strict == true
    end

    test "strict stays false if only one gate is :enforce" do
      Application.put_env(:commonplace, :trust, %{
        accept_unsigned: false,
        trusted_identities: %{}
      })

      Application.put_env(:commonplace, :local_write_gate, :enforce)
      Application.put_env(:commonplace, :local_read_gate, :dry_run)

      assert Trust.posture().strict == false
    end

    test "strict stays false under a permissive trust config even with both gates enforced" do
      Application.put_env(:commonplace, :trust, %{
        accept_unsigned: true,
        trusted_identities: %{}
      })

      Application.put_env(:commonplace, :local_write_gate, :enforce)
      Application.put_env(:commonplace, :local_read_gate, :enforce)

      assert Trust.posture().strict == false
    end
  end

  describe "local_write_gate/0 (S6v2)" do
    setup do
      old_gate = Application.get_env(:commonplace, :local_write_gate)

      on_exit(fn ->
        if is_nil(old_gate),
          do: Application.delete_env(:commonplace, :local_write_gate),
          else: Application.put_env(:commonplace, :local_write_gate, old_gate)
      end)

      :ok
    end

    test "resolves an absent value to dry_run" do
      Application.delete_env(:commonplace, :local_write_gate)
      assert Trust.local_write_gate() == :dry_run
    end

    test "resolves each valid value to itself" do
      for value <- [:off, :dry_run, :enforce] do
        Application.put_env(:commonplace, :local_write_gate, value)
        assert Trust.local_write_gate() == value
      end
    end

    test "resolves each valid runtime env string without minting an atom" do
      for {raw, value} <- [{"off", :off}, {"dry_run", :dry_run}, {"enforce", :enforce}] do
        Application.put_env(:commonplace, :local_write_gate, raw)
        assert Trust.local_write_gate() == value
      end
    end

    test "invalid values raise the named refusal with the complete valid set" do
      Application.put_env(:commonplace, :local_write_gate, "invalid-s6-value")

      assert_raise ArgumentError,
                   "Commonplace.Trust local_write_gate refusal: invalid value " <>
                     "\"invalid-s6-value\"; valid values: off | dry_run | enforce",
                   fn -> Trust.local_write_gate() end
    end
  end
end
