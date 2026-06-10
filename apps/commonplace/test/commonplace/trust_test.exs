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
        if old, do: Application.put_env(:commonplace, :data_dir, old),
          else: Application.delete_env(:commonplace, :data_dir)

        File.rm_rf!(tmp)
      end)

      cfg = Trust.config()
      assert cfg.accept_unsigned == false
      assert cfg.trusted_identities == %{"some-uuid" => "AAAA"}
    end
  end
end
