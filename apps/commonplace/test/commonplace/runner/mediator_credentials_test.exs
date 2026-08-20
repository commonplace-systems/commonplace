defmodule Commonplace.Runner.MediatorCredentialsTest do
  @moduledoc """
  The production credential loader for the host mediator (M-CUTOVER-1 glue,
  plan-ratified #13161): reads `tokens.access_token`/`tokens.refresh_token`
  from the operator's codex auth artifact, REFUSES BY NAME on every
  missing/malformed shape (a nil credential must never limp into the
  mediator), and never carries values into error terms — key names only.
  """
  use ExUnit.Case, async: true

  alias Commonplace.Runner.MediatorCredentials

  defp write_fixture!(map) do
    dir = Path.join(System.tmp_dir!(), "mediator_creds_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "auth.json")
    File.write!(path, Jason.encode!(map))
    on_exit(fn -> File.rm_rf!(dir) end)
    path
  end

  test "loads access and refresh from the operator artifact shape" do
    path =
      write_fixture!(%{
        "OPENAI_API_KEY" => nil,
        "last_refresh" => "2026-08-20T00:00:00Z",
        "tokens" => %{
          "access_token" => "fixture-access",
          "refresh_token" => "fixture-refresh",
          "id_token" => "fixture-id",
          "account_id" => "fixture-account"
        }
      })

    assert {:ok, %{access: "fixture-access", refresh: "fixture-refresh"}} =
             MediatorCredentials.load(path)
  end

  test "an absent file refuses by name" do
    assert {:error, {:credential_artifact_unreadable, :enoent}} =
             MediatorCredentials.load("/nonexistent/auth.json")
  end

  test "malformed JSON refuses by name without carrying content" do
    dir = Path.join(System.tmp_dir!(), "mediator_creds_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "auth.json")
    File.write!(path, "not-json{{{secret-looking-bytes")
    on_exit(fn -> File.rm_rf!(dir) end)

    assert {:error, :credential_artifact_not_json} = MediatorCredentials.load(path)
  end

  test "a missing tokens member refuses naming the KEY, never a value" do
    path = write_fixture!(%{"OPENAI_API_KEY" => "value-that-must-not-appear"})

    assert {:error, {:credential_key_missing, "tokens"}} = MediatorCredentials.load(path)
  end

  test "a missing or empty access/refresh token refuses naming the key" do
    missing = write_fixture!(%{"tokens" => %{"refresh_token" => "r"}})

    assert {:error, {:credential_key_missing, "tokens.access_token"}} =
             MediatorCredentials.load(missing)

    empty = write_fixture!(%{"tokens" => %{"access_token" => "", "refresh_token" => "r"}})

    assert {:error, {:credential_key_missing, "tokens.access_token"}} =
             MediatorCredentials.load(empty)

    no_refresh = write_fixture!(%{"tokens" => %{"access_token" => "a"}})

    assert {:error, {:credential_key_missing, "tokens.refresh_token"}} =
             MediatorCredentials.load(no_refresh)
  end

  test "no error term ever contains a token value" do
    for fixture <- [
          %{"tokens" => %{"refresh_token" => "SECRET-R"}},
          %{"tokens" => %{"access_token" => "SECRET-A"}},
          %{"OPENAI_API_KEY" => "SECRET-K"}
        ] do
      {:error, error} = fixture |> write_fixture!() |> MediatorCredentials.load()
      refute inspect(error) =~ "SECRET"
    end
  end
end
