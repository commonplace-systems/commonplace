defmodule Commonplace.Runner.DOnceSessionInjectorTest do
  @moduledoc """
  S2 injector for the (D)-ONCE discovery build. Every invariant is a
  RED-CAPABLE test, not a design intention (boss's storage-read standard:
  the sentinel must be demonstrable RED before it is believed green).
  """
  use ExUnit.Case, async: true

  alias Commonplace.Runner.DOnceSessionInjector, as: Injector

  # A session shaped like codex's auth.json, with SENTINEL secrets so leak
  # is detectable: the refresh token is SECRET-REFRESH; it must never appear
  # in the bundle, and any error must never quote a value.
  defp sentinel_session do
    %{
      "OPENAI_API_KEY" => nil,
      "last_refresh" => "2026-08-20T00:00:00Z",
      "installation_id" => "install-abc-123",
      "tokens" => %{
        "access_token" => "SECRET-ACCESS",
        "refresh_token" => "SECRET-REFRESH",
        "id_token" => "SECRET-ID",
        "account_id" => "acct-9"
      }
    }
  end

  describe "store_dir/0 — refuse, never guess (boss's added clause)" do
    test "XDG_STATE_HOME absolute → the XDG path" do
      System.put_env("XDG_STATE_HOME", "/var/lib/xdgstate")
      on_exit(fn -> System.delete_env("XDG_STATE_HOME") end)

      assert {:ok, "/var/lib/xdgstate/commonplace-runner/d-once-session"} = Injector.store_dir()
    end

    test "XDG unset, HOME absolute → the explicit ~/.local/state fallback" do
      System.delete_env("XDG_STATE_HOME")
      System.put_env("HOME", "/home/runner")
      on_exit(fn -> System.delete_env("HOME") end)

      assert {:ok, "/home/runner/.local/state/commonplace-runner/d-once-session"} =
               Injector.store_dir()
    end

    test "neither usable → REFUSES, never a relative or empty-var-join path" do
      System.delete_env("XDG_STATE_HOME")
      old_home = System.get_env("HOME")
      System.delete_env("HOME")
      on_exit(fn -> if old_home, do: System.put_env("HOME", old_home) end)

      assert {:error, :session_store_unresolvable} = Injector.store_dir()
    end

    test "a RELATIVE XDG_STATE_HOME is not silently joined — falls through to refuse-or-home" do
      System.put_env("XDG_STATE_HOME", "relative/not/absolute")
      old_home = System.get_env("HOME")
      System.delete_env("HOME")

      on_exit(fn ->
        System.delete_env("XDG_STATE_HOME")
        if old_home, do: System.put_env("HOME", old_home)
      end)

      # relative XDG is treated as unset; with HOME also gone → refuse, never
      # "relative/not/absolute/commonplace-runner/...".
      assert {:error, :session_store_unresolvable} = Injector.store_dir()
    end
  end

  describe "pod_bundle/1 — refresh_token cannot reach a pod, BY CONSTRUCTION" do
    test "extracts exactly access_token + installation_id, no other key" do
      assert {:ok, bundle} = Injector.pod_bundle(sentinel_session())
      assert bundle == %{access_token: "SECRET-ACCESS", installation_id: "install-abc-123"}
      assert Map.keys(bundle) |> Enum.sort() == [:access_token, :installation_id]
      refute Map.has_key?(bundle, :refresh_token)
    end

    test "SENTINEL: the refresh token value NEVER appears in the bundle" do
      {:ok, bundle} = Injector.pod_bundle(sentinel_session())
      # This is the red-capable leak check: if any code path let the refresh
      # token into the bundle, this goes red.
      refute inspect(bundle) =~ "SECRET-REFRESH"
      refute inspect(bundle) =~ "SECRET-ID"
    end

    test "no error term ever quotes a token value — only key PATHS" do
      for broken <- [
            %{"tokens" => %{"refresh_token" => "SECRET-REFRESH"}},
            %{"tokens" => %{"access_token" => "", "refresh_token" => "SECRET-REFRESH"}},
            %{"installation_id" => "x", "tokens" => %{"refresh_token" => "SECRET-REFRESH"}}
          ] do
        {:error, error} = Injector.pod_bundle(broken)
        refute inspect(error) =~ "SECRET"
      end
    end

    test "missing tokens map refuses naming the KEY path" do
      assert {:error, {:credential_key_missing, "tokens"}} =
               Injector.pod_bundle(%{"installation_id" => "x"})
    end

    test "missing access_token refuses naming tokens.access_token" do
      assert {:error, {:credential_key_missing, "tokens.access_token"}} =
               Injector.pod_bundle(%{
                 "installation_id" => "x",
                 "tokens" => %{"refresh_token" => "r"}
               })
    end

    test "missing installation_id refuses naming it" do
      assert {:error, {:credential_key_missing, "installation_id"}} =
               Injector.pod_bundle(%{
                 "tokens" => %{"access_token" => "a", "refresh_token" => "r"}
               })
    end
  end
end
