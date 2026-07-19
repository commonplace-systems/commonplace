defmodule Commonplace.Bots.TelegramBridge.PollerTest do
  @moduledoc """
  Camillo C4 — `Commonplace.Bots.TelegramBridge.Poller`. Parsing / offset /
  redaction ONLY — no network, anywhere in this file. `opts[:http_fn]`
  replaces `Req` entirely; nothing here ever reaches the real Telegram API.
  """
  use ExUnit.Case, async: true

  alias Commonplace.Bots.TelegramBridge.Poller

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_tg_poller_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    env_file = Path.join(dir, ".env")

    File.write!(
      env_file,
      "CAMILLO_BOT_TOKEN=123456:AAsecretTokenBytesHere\nCAMILLO_OWNER_CHAT_ID=987654\n"
    )

    on_exit(fn -> File.rm_rf!(dir) end)
    %{env_file: env_file}
  end

  defp stub_http(responses) do
    agent_name = :"poller_http_stub_#{:rand.uniform(1_000_000_000)}"
    {:ok, _} = Agent.start_link(fn -> responses end, name: agent_name)

    fn :get, _url, _opts ->
      Agent.get_and_update(agent_name, fn
        [resp | rest] -> {resp, rest}
        [] -> {{:ok, %{status: 200, body: %{"ok" => true, "result" => []}}}, []}
      end)
    end
  end

  describe "token loading (redaction-safe)" do
    test "parses CAMILLO_BOT_TOKEN from the env file", %{env_file: env_file} do
      test_pid = self()

      http_fn = fn :get, url, _opts ->
        send(test_pid, {:requested_url, url})
        {:ok, %{status: 200, body: %{"ok" => true, "result" => []}}}
      end

      {:ok, poller} =
        Poller.start_link(
          bridge: self(),
          env_file: env_file,
          http_fn: http_fn,
          poll_timeout_s: 0,
          auto_poll: false
        )

      assert {:ok, _} = Poller.poll_now(poller)
      assert_received {:requested_url, url}
      assert url =~ "123456:AAsecretTokenBytesHere"
    end

    test "missing env file fails to start rather than silently running tokenless" do
      Process.flag(:trap_exit, true)

      assert {:error, {:token_load_failed, _reason}} =
               Poller.start_link(
                 bridge: self(),
                 env_file: "/nonexistent/path/.env",
                 http_fn: fn _, _, _ -> :unused end,
                 auto_poll: false
               )
    end

    test "the token never appears in inspect(state) — closure + custom Inspect redact it", %{
      env_file: env_file
    } do
      {:ok, poller} =
        Poller.start_link(
          bridge: self(),
          env_file: env_file,
          http_fn: fn :get, _url, _opts ->
            {:ok, %{status: 200, body: %{"ok" => true, "result" => []}}}
          end,
          poll_timeout_s: 0,
          auto_poll: false
        )

      state = :sys.get_state(poller)
      dumped = inspect(state, limit: :infinity, printable_limit: :infinity)

      # PRIMARY custody (consolidation-proof): the token lives in a closure,
      # so its bytes cannot appear no matter how the struct renders.
      refute dumped =~ "123456:AAsecretTokenBytesHere"

      # BELT layer: the custom Inspect impl must actually be DISPATCHED.
      # The angle-bracket form only exists when the impl ran; a stale
      # protocol consolidation (a _build predating the impl) silently
      # falls back to the raw `%…State{` dump — which this pin must FAIL
      # on, not shrug past (found live at the C4 mini-gate: targeted runs
      # passed while a full-suite run dispatched the consolidated,
      # impl-unaware Inspect).
      assert dumped =~ "#Commonplace.Bots.TelegramBridge.Poller.State<"
      refute dumped =~ "%Commonplace.Bots.TelegramBridge.Poller.State{"
      assert dumped =~ ":redacted"
    end
  end

  describe "offset advances and inbound messages forward to the bridge" do
    test "an update with message text forwards {:external_message, ...} and advances offset", %{
      env_file: env_file
    } do
      test_pid = self()

      update = %{
        "update_id" => 42,
        "message" => %{
          "text" => "hello camillo",
          "chat" => %{"id" => 987_654},
          "from" => %{"username" => "jes5199", "first_name" => "Jes"}
        }
      }

      http_fn = stub_http([{:ok, %{status: 200, body: %{"ok" => true, "result" => [update]}}}])

      {:ok, poller} =
        Poller.start_link(
          bridge: test_pid,
          env_file: env_file,
          http_fn: http_fn,
          poll_timeout_s: 0,
          auto_poll: false
        )

      assert {:ok, _} = Poller.poll_now(poller)

      assert_received {:external_message,
                       %{
                         nick: "jes5199",
                         handle: "jes5199",
                         text: "hello camillo",
                         chat_id: 987_654
                       }}

      assert Poller.offset(poller) == 43
    end

    test "a from with no username falls back to first_name for nick, handle is nil", %{
      env_file: env_file
    } do
      update = %{
        "update_id" => 7,
        "message" => %{
          "text" => "no username here",
          "chat" => %{"id" => 1},
          "from" => %{"first_name" => "Anon"}
        }
      }

      http_fn = stub_http([{:ok, %{status: 200, body: %{"ok" => true, "result" => [update]}}}])

      {:ok, poller} =
        Poller.start_link(
          bridge: self(),
          env_file: env_file,
          http_fn: http_fn,
          poll_timeout_s: 0,
          auto_poll: false
        )

      assert {:ok, _} = Poller.poll_now(poller)

      assert_received {:external_message,
                       %{nick: "Anon", handle: nil, text: "no username here", chat_id: 1}}
    end

    test "an update with no message text is skipped, but offset still advances", %{
      env_file: env_file
    } do
      update = %{
        "update_id" => 5,
        "message" => %{"chat" => %{"id" => 1}, "from" => %{"first_name" => "X"}}
      }

      http_fn = stub_http([{:ok, %{status: 200, body: %{"ok" => true, "result" => [update]}}}])

      {:ok, poller} =
        Poller.start_link(
          bridge: self(),
          env_file: env_file,
          http_fn: http_fn,
          poll_timeout_s: 0,
          auto_poll: false
        )

      assert {:ok, _} = Poller.poll_now(poller)
      refute_received {:external_message, _}
      assert Poller.offset(poller) == 6
    end
  end

  describe "error handling" do
    test "409 conflict backs off and does not crash", %{env_file: env_file} do
      http_fn = stub_http([{:ok, %{status: 409, body: %{"ok" => false}}}])

      {:ok, poller} =
        Poller.start_link(
          bridge: self(),
          env_file: env_file,
          http_fn: http_fn,
          poll_timeout_s: 0,
          backoff_ms: 1,
          auto_poll: false
        )

      assert {:error, :conflict} = Poller.poll_now(poller)
      assert Process.alive?(poller)
    end

    test "429 rate limited honors retry_after from the response body", %{env_file: env_file} do
      test_pid = self()

      http_fn = fn :get, _url, _opts ->
        send(test_pid, :called)
        {:ok, %{status: 429, body: %{"parameters" => %{"retry_after" => 0}}}}
      end

      {:ok, poller} =
        Poller.start_link(
          bridge: self(),
          env_file: env_file,
          http_fn: http_fn,
          poll_timeout_s: 0,
          backoff_ms: 60_000,
          auto_poll: false
        )

      assert {:error, :rate_limited} = Poller.poll_now(poller)
      assert_received :called
    end

    test "a transport error backs off and does not crash", %{env_file: env_file} do
      http_fn = fn :get, _url, _opts -> {:error, %RuntimeError{message: "boom"}} end

      {:ok, poller} =
        Poller.start_link(
          bridge: self(),
          env_file: env_file,
          http_fn: http_fn,
          poll_timeout_s: 0,
          backoff_ms: 1,
          auto_poll: false
        )

      assert {:error, {:transport_error, _}} = Poller.poll_now(poller)
      assert Process.alive?(poller)
    end
  end
end
