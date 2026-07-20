defmodule Commonplace.Bots.PromptCachingTest do
  @moduledoc """
  Camillo batch (cp-plan, jes-greenlit "yes let's fix caching") — PART 1
  (prompt caching request shape) + PART 2 (usage accounting into the
  transcript).

  Part 1 pins are on REQUEST SHAPE only — a stub `client_fn` captures
  exactly what `Commonplace.Bots.Worker.Loop.build_request/4` assembles.
  A server-side cache HIT can't be observed against a stub (there's no
  real Anthropic backend in a test); that's what part 2's usage-accounting
  pin is for (`cache_read_input_tokens` flowing into the transcript is the
  live confirmation channel, per the loop's own moduledoc "Prompt
  caching").

  Uses a minimal `FakeTools` module (not the real `Tools` registry) and
  `mud_ctx: nil` for the Part 1 (request-shape) pins — no store, no
  Citizen, no Bursar needed at all: a missing `mud_ctx` degrades
  perception/scrollback to fixed strings and skips the transcript write
  entirely (see `Loop`'s own `append_transcript/2` nil-ctx clause), so
  these tests exercise pure request assembly. The usage-accounting pin
  (part 2) DOES need a real, provisioned ctx (somewhere to actually write
  the transcript), so it sets one up.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Bots.Worker.Loop

  defmodule FakeTools do
    @moduledoc "A minimal tools_module stand-in — one no-op tool, no MUD needed."

    def tool_defs(_state) do
      [
        %{
          "name" => "noop",
          "description" => "Does nothing.",
          "input_schema" => %{"type" => "object", "properties" => %{}}
        }
      ]
    end

    def dispatch(_state, "noop", _input), do: {:ok, "done"}
  end

  defp base_state(client_fn) do
    %{
      room: "jes",
      entity: %{name: "camillo", persona: "You are camillo, a small thoughtful presence."},
      event: %{"message_id" => "m1", "author_path" => "jes.usr", "text" => "hello camillo"},
      mud_ctx: nil,
      config: %{
        max_calls: 5,
        max_output_tokens: 1000,
        max_wall_ms: 30_000,
        model: "test-model",
        fallback_model: nil
      },
      client_fn: client_fn,
      tools_module: FakeTools,
      signing_context: nil,
      allowlist: ["noop"],
      opts: []
    }
  end

  defp end_turn(usage \\ %{"output_tokens" => 5}) do
    %{
      "stop_reason" => "end_turn",
      "content" => [%{"type" => "text", "text" => "ok"}],
      "usage" => usage
    }
  end

  defp tool_use(id, name, input, usage \\ %{"output_tokens" => 20}) do
    %{
      "stop_reason" => "tool_use",
      "content" => [%{"type" => "tool_use", "id" => id, "name" => name, "input" => input}],
      "usage" => usage
    }
  end

  defp capturing_stub_client(test_pid, responses) do
    {:ok, agent} = Agent.start_link(fn -> responses end)

    fn request ->
      send(test_pid, {:request, request})

      case Agent.get_and_update(agent, fn
             [] -> {[], []}
             [h | t] -> {h, t}
           end) do
        [] -> {:error, :stub_exhausted}
        response -> {:ok, response}
      end
    end
  end

  defp cache_control?(%{"cache_control" => %{"type" => "ephemeral"}}), do: true
  defp cache_control?(_), do: false

  ## ---- PART 1 PIN: round-1 request carries the breakpoints ----

  test "PIN: round-1 request carries all THREE cache breakpoints (system, last tool def, initial message)" do
    test_pid = self()
    responses = [tool_use("t1", "noop", %{}), end_turn()]

    assert {:ok, :end_turn} = Loop.run(base_state(capturing_stub_client(test_pid, responses)))

    assert_receive {:request, round1}

    # (system-as-block) the persona carries cache_control.
    assert [%{"type" => "text", "text" => persona, "cache_control" => %{"type" => "ephemeral"}}] =
             round1.system

    assert persona =~ "camillo"

    # (a) the LAST (only) tool definition carries cache_control.
    assert [%{"cache_control" => %{"type" => "ephemeral"}} = tool_def] = round1.tools
    assert tool_def["name"] == "noop"

    # (b) the initial user message's sole content block carries cache_control.
    assert [%{"role" => "user", "content" => [block]}] = round1.messages
    assert cache_control?(block)
  end

  ## ---- PART 1 PIN: rounds 2+ still carry them, INCLUDING the sliding breakpoint ----

  test "PIN: round-2+ requests still carry the breakpoints, including the SLIDING tool_result one",
       _ctx do
    test_pid = self()

    responses = [
      tool_use("t1", "noop", %{}),
      tool_use("t2", "noop", %{}),
      end_turn()
    ]

    assert {:ok, :end_turn} = Loop.run(base_state(capturing_stub_client(test_pid, responses)))

    # Drain: round-1 request (initial), round-2 request (after t1's result),
    # round-3 request (after t2's result).
    assert_receive {:request, _round1}
    assert_receive {:request, round2}
    assert_receive {:request, round3}

    for round <- [round2, round3] do
      # (system) still cached every round.
      assert [%{"cache_control" => %{"type" => "ephemeral"}}] = round.system

      # (a) last tool def still cached.
      assert [%{"cache_control" => %{"type" => "ephemeral"}}] = round.tools

      # (b) the FIRST (initial) message's content block is STILL cached —
      # byte-stable prefix across every round.
      assert [first | _] = round.messages
      assert [first_block] = first["content"]
      assert cache_control?(first_block)

      # (c) THE SLIDING breakpoint: the LAST message (this round's newest
      # tool_result) has its LAST content block cached.
      last = List.last(round.messages)
      assert last["role"] == "user"
      last_block = List.last(last["content"])
      assert cache_control?(last_block)
      assert last_block["type"] == "tool_result"
    end
  end

  ## ---- PART 2 PIN: 3-round usage sums land correctly in the transcript ----

  test "PIN: a 3-round turn's transcript entry carries usage with correct summed values", _ctx do
    n = :rand.uniform(1_000_000_000)
    dir = Path.join(System.tmp_dir!(), "cp_bots_usage_#{n}")
    File.mkdir_p!(dir)
    store = :"usage_store_#{n}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: dir,
       name: :"usage_sup_#{n}",
       commit_store_name: store,
       trust_side_store_name: :"usage_tss_#{n}",
       pending_imports_name: :"usage_pi_#{n}"}
    )

    old_data_dir = Application.get_env(:commonplace, :data_dir)
    Application.put_env(:commonplace, :data_dir, dir)

    secrets_dir = Path.join(System.tmp_dir!(), "cp_bots_usage_secrets_#{n}")
    File.mkdir_p!(secrets_dir)
    secrets = :"usage_secrets_#{n}"

    {:ok, secrets_pid} =
      Commonplace.Store.SecretStore.start_link(data_dir: secrets_dir, name: secrets)

    on_exit(fn ->
      Application.put_env(:commonplace, :data_dir, old_data_dir || "tmp/test_data")

      if Process.alive?(secrets_pid) do
        try do
          GenServer.stop(secrets_pid)
        catch
          :exit, _ -> :ok
        end
      end

      File.rm_rf!(dir)
      File.rm_rf!(secrets_dir)
    end)

    {:ok, node_ctx} = Commonplace.Crypto.NodeIdentity.signing_context()
    mud_root = UUID.uuid4()

    Commonplace.Store.CommitStore.create_commit(
      store,
      mud_root,
      Yelixer.Encoding.encode_update(Commonplace.Tree.Schema.new_schema()),
      nil,
      %{},
      signing_context: node_ctx
    )

    {:ok, _prov} =
      Commonplace.Bots.Citizen.provision("camillo", mud_root, store, secret_store: secrets)

    {:ok, sc} =
      Commonplace.Bots.Identity.resolve_signing_context("camillo", mud_root, store,
        secret_store: secrets
      )

    {:ok, mud_ctx} =
      Commonplace.Bots.MudContext.resolve(%{name: "camillo"}, sc, mud_root, store)

    test_pid = self()

    responses = [
      tool_use("t1", "noop", %{}, %{
        "input_tokens" => 100,
        "cache_creation_input_tokens" => 50,
        "cache_read_input_tokens" => 0,
        "output_tokens" => 20
      }),
      tool_use("t2", "noop", %{}, %{
        "input_tokens" => 110,
        "cache_creation_input_tokens" => 0,
        "cache_read_input_tokens" => 90,
        "output_tokens" => 15
      }),
      end_turn(%{
        "input_tokens" => 5,
        "cache_creation_input_tokens" => 0,
        "cache_read_input_tokens" => 100,
        "output_tokens" => 5
      })
    ]

    state = %{
      base_state(capturing_stub_client(test_pid, responses))
      | mud_ctx: mud_ctx,
        opts: [store: store]
    }

    assert {:ok, :end_turn} = Loop.run(state)

    [entry] = Commonplace.Bots.Transcript.read(mud_ctx)

    assert entry["usage"] == %{
             "rounds" => 3,
             "input_tokens" => 100 + 110 + 5,
             "cache_creation_input_tokens" => 50 + 0 + 0,
             "cache_read_input_tokens" => 0 + 90 + 100,
             "output_tokens" => 20 + 15 + 5
           }
  end
end
