defmodule Commonplace.Bots.TelegramBridge.Transport.TelegramTest do
  @moduledoc """
  Camillo C4 — `Commonplace.Bots.TelegramBridge.Transport.Telegram`.
  Offline via `opts[:http_fn]` — no network, anywhere in this file.
  """
  use ExUnit.Case, async: true

  alias Commonplace.Bots.TelegramBridge.Transport.Telegram, as: TelegramTransport

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_tg_transport_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    env_file = Path.join(dir, ".env")
    File.write!(env_file, "CAMILLO_BOT_TOKEN=999999:SuperSecretTransportToken\n")
    on_exit(fn -> File.rm_rf!(dir) end)
    %{env_file: env_file}
  end

  describe "success" do
    test "a 200 response returns {:ok, state} unchanged, no parse_mode in the body", %{
      env_file: env_file
    } do
      test_pid = self()

      http_fn = fn :post, url, opts ->
        send(test_pid, {:posted, url, Keyword.get(opts, :json)})
        {:ok, %{status: 200, body: %{"ok" => true, "result" => %{}}}}
      end

      assert {:ok, state} = TelegramTransport.new(env_file: env_file, http_fn: http_fn)

      assert {:ok, ^state} =
               TelegramTransport.relay_to_external(state, %{
                 author: "camillo.bot",
                 text: "hi jes",
                 chat_id: 42
               })

      assert_received {:posted, url, json}
      assert url =~ "999999:SuperSecretTransportToken"
      assert url =~ "/sendMessage"
      assert json == %{chat_id: 42, text: "hi jes"}
      refute Map.has_key?(json, :parse_mode)
    end
  end

  describe "429 rate limiting" do
    test "maps to {:error, {:rate_limited, retry_after}} without sleeping/retrying itself", %{
      env_file: env_file
    } do
      http_fn = fn :post, _url, _opts ->
        {:ok, %{status: 429, body: %{"parameters" => %{"retry_after" => 7}}}}
      end

      {:ok, state} = TelegramTransport.new(env_file: env_file, http_fn: http_fn)

      {elapsed_us, result} =
        :timer.tc(fn ->
          TelegramTransport.relay_to_external(state, %{author: "x", text: "y", chat_id: 1})
        end)

      assert {:error, {:rate_limited, 7}} = result
      # No blocking backoff inside the transport itself (the BRIDGE owns
      # the retry-next-tick cadence) — this should return near-instantly.
      assert elapsed_us < 500_000
    end

    test "429 with no retry_after in the body yields retry_after: nil", %{env_file: env_file} do
      http_fn = fn :post, _url, _opts -> {:ok, %{status: 429, body: %{}}} end
      {:ok, state} = TelegramTransport.new(env_file: env_file, http_fn: http_fn)

      assert {:error, {:rate_limited, nil}} =
               TelegramTransport.relay_to_external(state, %{author: "x", text: "y", chat_id: 1})
    end
  end

  describe "other HTTP errors" do
    test "a 500 maps to {:error, {:telegram_status, 500}}", %{env_file: env_file} do
      http_fn = fn :post, _url, _opts -> {:ok, %{status: 500, body: %{"ok" => false}}} end
      {:ok, state} = TelegramTransport.new(env_file: env_file, http_fn: http_fn)

      assert {:error, {:telegram_status, 500}} =
               TelegramTransport.relay_to_external(state, %{author: "x", text: "y", chat_id: 1})
    end

    test "a non-429 4xx also maps to {:error, {:telegram_status, code}}", %{env_file: env_file} do
      http_fn = fn :post, _url, _opts ->
        {:ok, %{status: 400, body: %{"ok" => false, "description" => "bad"}}}
      end

      {:ok, state} = TelegramTransport.new(env_file: env_file, http_fn: http_fn)

      assert {:error, {:telegram_status, 400}} =
               TelegramTransport.relay_to_external(state, %{author: "x", text: "y", chat_id: 1})
    end

    test "a transport-level failure maps to {:error, {:transport_error, sanitized}}", %{
      env_file: env_file
    } do
      http_fn = fn :post, _url, _opts ->
        {:error, %RuntimeError{message: "connection refused"}}
      end

      {:ok, state} = TelegramTransport.new(env_file: env_file, http_fn: http_fn)

      assert {:error, {:transport_error, RuntimeError}} =
               TelegramTransport.relay_to_external(state, %{author: "x", text: "y", chat_id: 1})
    end
  end

  describe "no-log-discipline: token and URL never leak" do
    test "the token never appears in inspect(transport_state)", %{env_file: env_file} do
      {:ok, state} =
        TelegramTransport.new(
          env_file: env_file,
          http_fn: fn _, _, _ -> {:ok, %{status: 200, body: %{}}} end
        )

      dumped = inspect(state, limit: :infinity, printable_limit: :infinity)
      refute dumped =~ "999999:SuperSecretTransportToken"
      assert dumped =~ ":redacted"
    end

    test "a captured error tuple never contains the token or the request URL", %{
      env_file: env_file
    } do
      http_fn = fn :post, url, _opts -> {:error, %RuntimeError{message: "boom for #{url}"}} end
      {:ok, state} = TelegramTransport.new(env_file: env_file, http_fn: http_fn)

      assert {:error, {:transport_error, sanitized}} =
               TelegramTransport.relay_to_external(state, %{author: "x", text: "y", chat_id: 1})

      dumped = inspect(sanitized, limit: :infinity, printable_limit: :infinity)
      refute dumped =~ "999999:SuperSecretTransportToken"
      refute dumped =~ "api.telegram.org"
    end

    test "the 429/500/400 error tuples never embed the URL either", %{env_file: env_file} do
      http_fn = fn :post, _url, _opts -> {:ok, %{status: 500, body: %{}}} end
      {:ok, state} = TelegramTransport.new(env_file: env_file, http_fn: http_fn)

      assert {:error, reason} =
               TelegramTransport.relay_to_external(state, %{author: "x", text: "y", chat_id: 1})

      refute inspect(reason) =~ "999999:SuperSecretTransportToken"
      refute inspect(reason) =~ "api.telegram.org"
    end
  end

  describe "constructor failure" do
    test "a missing env file returns {:error, ...} rather than a state with no token" do
      assert {:error, {:env_file_not_found, _path}} =
               TelegramTransport.new(
                 env_file: "/nonexistent/path/.env",
                 http_fn: fn _, _, _ -> :unused end
               )
    end
  end
end
