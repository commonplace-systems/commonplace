defmodule Commonplace.Bots.DemoSession do
  @moduledoc """
  Long-lived helper for the v0 live testing session. A thin agent
  that:

    * On `start/1`, bootstraps the demo room (`Bots.Demo.bootstrap`),
      registers it with the Dispatcher, and stashes the resulting
      identifiers in an `Agent` named after this module.
    * Exposes `post/2` (post a message into the demo room) and
      `read/1` (materialized messages) so the `bin/bot-demo-post`
      and `bin/bot-demo-read` shell scripts can `:rpc.call` a
      single MFA and not have to thread room/messages_uuid args
      around.

  Lives on the **serve** node only — never started in tests.
  Tests use `Bots.Demo.bootstrap/2` directly + the test-specific
  worker_hook.

  ## Bootstrap incantation

      iex> root = UUID.uuid4()
      iex> Commonplace.Bots.DemoSession.start(root)
      %{room: "demo", room_dir_uuid: ..., messages_uuid: ..., bots: ...}

  After this, the dispatcher is subscribed and the production
  worker_hook (defaults to `Dispatcher.spawn_worker/4`) will
  spawn real workers on every chat post matching alice or bob's
  trigger regex.

  ## Why an Agent

  `:persistent_term` would also work but updates are global and
  the live session might want to re-bootstrap. Agent gives a
  proper API surface and clean teardown on stop/0.
  """

  alias Commonplace.Bots.{Demo, Dispatcher}
  alias Commonplace.Chat.{Actions, Messages}
  alias Commonplace.Crypto.{NodeIdentity, Signing, SigningContext}
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.DocBuilder

  @name __MODULE__

  @doc """
  Bootstrap a fresh demo session under `root_uuid` (must already
  have a `:latest` in the CommitStore). Returns the demo info
  map. Idempotent — calling `start/1` again replaces the stashed
  state and re-registers the room.
  """
  def start(root_uuid, opts \\ []) when is_binary(root_uuid) do
    demo = Demo.bootstrap(root_uuid, opts)
    Dispatcher.subscribe_room(demo.room, demo.room_dir_uuid, demo.messages_uuid)

    case Agent.start_link(fn -> demo end, name: @name) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> Agent.update(@name, fn _ -> demo end)
    end

    demo
  end

  @doc """
  Post a message into the demo room as `author_path` (default
  `"workspace.usr"`). Returns `{:ok, %{message_id, ts}}` on
  success.
  """
  def post(text, author_path \\ "workspace.usr") when is_binary(text) do
    demo = state()

    opts =
      [room: demo.room, author_path: author_path] ++ node_signing_opts()

    Actions.post_message(demo.messages_uuid, text, opts)
  end

  # Camillo C1: the demo harness runs on the SERVE node only, so node-sign
  # the demo post with the node's real identity (`Trust` auto-trusts it) —
  # retiring the `"ws:#{author_path}"` placeholder signer_id. On a node with
  # no key configured we pass neither, leaving the write to the
  # global-fallback / unsigned path (harmless on a permissive node).
  defp node_signing_opts do
    case NodeIdentity.signing_context() do
      {:ok, %SigningContext{} = ctx} ->
        [signer_id: Signing.signer_id(ctx.identity_uuid, ctx.public_key), signing_context: ctx]

      _ ->
        []
    end
  end

  @doc """
  Read the most recent `limit` messages from the demo room,
  materialized (edits/tombstones resolved). Returns a list of
  `{author, text, ts}` tuples, newest-first.
  """
  def read(limit \\ 20) when is_integer(limit) and limit > 0 do
    demo = state()

    case DocBuilder.reconstruct_snapshot(CommitStoreClient, demo.messages_uuid) do
      {:ok, doc} ->
        doc
        |> Messages.materialize()
        |> Enum.take(-limit)
        |> Enum.reverse()
        |> Enum.map(fn entry ->
          {Map.get(entry, "author_path"), Map.get(entry, "text"), Map.get(entry, "ts")}
        end)

      _ ->
        []
    end
  end

  @doc "Return the stashed demo info. Raises if `start/1` hasn't run."
  def state, do: Agent.get(@name, & &1)

  @doc "Stop the session (drops the Agent). For tear-down."
  def stop do
    case Process.whereis(@name) do
      nil -> :ok
      pid -> Agent.stop(pid)
    end
  end
end
