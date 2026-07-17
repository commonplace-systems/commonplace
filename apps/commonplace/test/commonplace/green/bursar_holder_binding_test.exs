defmodule Commonplace.Green.BursarHolderBindingTest do
  @moduledoc """
  CX-tdkq.32: a Bursar holder must be DERIVABLE from and VERIFIED
  against an authenticated principal, not any string the caller picks.
  Today a verified agent B could acquire/transfer/release a token
  claiming to be holder A. `authenticated_as` binds the effective
  holder to the caller's authenticated identity:

    * `authenticated_as` present, holder nil/omitted -> holder :=
      authenticated_as (derive).
    * `authenticated_as` present, holder present and EQUAL -> proceed,
      `[:commonplace, :bursar, :redundant_holder_param]` telemetry.
    * `authenticated_as` present, holder present and DIFFERENT ->
      `{:error, :holder_mismatch}` (impersonation attempt).
    * `authenticated_as` absent -> legacy behavior, unchanged, but
      `[:commonplace, :bursar, :unbound_holder]` telemetry so those
      call sites are enumerable.

  The pre-existing holder-checked rejection (contending against a
  token held by someone else) is untouched — it already returns
  `{:error, {:not_holder, current_holder}}` for release/transfer/renew.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Store.CommitStore
  alias Commonplace.Green.Bursar
  alias Commonplace.Tree.Schema

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_bursar_bind_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    store_name = :"bursar_bind_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store_name})
    on_exit(fn -> File.rm_rf!(dir) end)

    root_uuid = UUID.uuid4()
    root_doc = Schema.new_schema()
    update = Yelixer.Encoding.encode_update(root_doc)
    CommitStore.create_commit(store_name, root_uuid, update, nil)

    %{store: store_name, root: root_uuid}
  end

  defp start_bursar(ctx, name \\ nil, opts \\ []) do
    name = name || :"bursar_bind_#{:rand.uniform(1_000_000)}"

    {:ok, pid} =
      Bursar.start_link(
        [root_uuid: ctx.root, store: ctx.store, name: name, sweep_interval: 60_000] ++ opts
      )

    on_exit(fn ->
      if Process.alive?(pid), do: (try do GenServer.stop(pid) catch (:exit, _ -> :ok) end)
    end)

    {pid, name}
  end

  defp attach(event) do
    test_pid = self()
    ref = make_ref()

    :telemetry.attach(
      "#{inspect(event)}-#{inspect(ref)}",
      event,
      fn ^event, measurements, metadata, _config ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach("#{inspect(event)}-#{inspect(ref)}") end)
  end

  describe "malicious-agent pair (impersonation attempts)" do
    test "B acquiring with holder=A while authenticated as B is rejected", ctx do
      {_pid, name} = start_bursar(ctx)

      assert {:error, :holder_mismatch} =
               Bursar.acquire(name, "readme.txt", "alice", authenticated_as: "bob")

      # No token was granted to anyone.
      assert :available = Bursar.query(name, "readme.txt")
    end

    test "B (authenticated, no impersonation claim) transferring A's token is rejected as not_holder-class",
         ctx do
      {_pid, name} = start_bursar(ctx)

      assert {:ok, _} = Bursar.acquire(name, "readme.txt", "alice", authenticated_as: "alice")

      # B does not claim to be "alice" (from_holder is nil -> derives to
      # "bob") — this is a legitimate transfer attempt by a real
      # principal who simply isn't the holder, distinct from the
      # holder_mismatch (impersonation) case below.
      assert {:error, {:not_holder, "alice"}} =
               Bursar.transfer(name, "readme.txt", nil, "carol", authenticated_as: "bob")

      assert {:held, %{holder: "alice"}} = Bursar.query(name, "readme.txt")
    end

    test "B (authenticated, no impersonation claim) releasing A's token is rejected as not_holder-class",
         ctx do
      {_pid, name} = start_bursar(ctx)

      assert {:ok, _} = Bursar.acquire(name, "readme.txt", "alice", authenticated_as: "alice")

      assert {:error, {:not_holder, "alice"}} =
               Bursar.release(name, "readme.txt", nil, authenticated_as: "bob")

      assert {:held, %{holder: "alice"}} = Bursar.query(name, "readme.txt")
    end

    test "B transfer with mismatched from_holder claiming to be A is rejected outright", ctx do
      {_pid, name} = start_bursar(ctx)

      assert {:ok, _} = Bursar.acquire(name, "readme.txt", "alice", authenticated_as: "alice")

      # B claims from_holder "alice" but is authenticated as "bob" — this
      # never reaches the token table check, it's rejected as impersonation.
      assert {:error, :holder_mismatch} =
               Bursar.transfer(name, "readme.txt", "alice", "carol", authenticated_as: "bob")

      assert {:held, %{holder: "alice"}} = Bursar.query(name, "readme.txt")
    end

    test "B releasing with mismatched holder param claiming to be A is rejected outright", ctx do
      {_pid, name} = start_bursar(ctx)

      assert {:ok, _} = Bursar.acquire(name, "readme.txt", "alice", authenticated_as: "alice")

      assert {:error, :holder_mismatch} =
               Bursar.release(name, "readme.txt", "alice", authenticated_as: "bob")

      assert {:held, %{holder: "alice"}} = Bursar.query(name, "readme.txt")
    end

    test "B acquires with no holder param -> token held by B (derive path)", ctx do
      {_pid, name} = start_bursar(ctx)

      assert {:ok, info} = Bursar.acquire(name, "readme.txt", nil, authenticated_as: "bob")
      assert info.holder == "bob"
      assert {:held, %{holder: "bob"}} = Bursar.query(name, "readme.txt")
    end
  end

  describe "authenticated_as + holder param semantics" do
    test "authenticated_as present, holder equal -> proceeds and emits redundant_holder_param telemetry",
         ctx do
      {_pid, name} = start_bursar(ctx)
      attach([:commonplace, :bursar, :redundant_holder_param])

      assert {:ok, info} =
               Bursar.acquire(name, "readme.txt", "alice", authenticated_as: "alice")

      assert info.holder == "alice"
      assert_receive {:telemetry, [:commonplace, :bursar, :redundant_holder_param], _, _}
    end

    test "authenticated_as absent -> legacy behavior unchanged, emits unbound_holder telemetry",
         ctx do
      {_pid, name} = start_bursar(ctx)
      attach([:commonplace, :bursar, :unbound_holder])

      assert {:ok, info} = Bursar.acquire(name, "readme.txt", "alice")
      assert info.holder == "alice"
      assert_receive {:telemetry, [:commonplace, :bursar, :unbound_holder], _, _}
    end

    test "release with authenticated_as absent is unchanged legacy behavior", ctx do
      {_pid, name} = start_bursar(ctx)

      assert {:ok, _} = Bursar.acquire(name, "readme.txt", "alice")
      assert :ok = Bursar.release(name, "readme.txt", "alice")
    end

    test "transfer with authenticated_as absent is unchanged legacy behavior", ctx do
      {_pid, name} = start_bursar(ctx)

      assert {:ok, _} = Bursar.acquire(name, "readme.txt", "alice")
      assert {:ok, info} = Bursar.transfer(name, "readme.txt", "alice", "bob")
      assert info.holder == "bob"
    end

    test "renew authenticated_as present and matching proceeds", ctx do
      {_pid, name} = start_bursar(ctx)

      assert {:ok, _} = Bursar.acquire(name, "readme.txt", "alice", authenticated_as: "alice")

      assert {:ok, info} =
               Bursar.renew(name, "readme.txt", "alice", authenticated_as: "alice")

      assert info.holder == "alice"
    end

    test "renew authenticated_as present and mismatched is rejected", ctx do
      {_pid, name} = start_bursar(ctx)

      assert {:ok, _} = Bursar.acquire(name, "readme.txt", "alice", authenticated_as: "alice")

      assert {:error, :holder_mismatch} =
               Bursar.renew(name, "readme.txt", "alice", authenticated_as: "bob")
    end

    test "renew derives holder from authenticated_as when holder is nil", ctx do
      {_pid, name} = start_bursar(ctx)

      assert {:ok, _} = Bursar.acquire(name, "readme.txt", "bob", authenticated_as: "bob")

      assert {:ok, info} =
               Bursar.renew(name, "readme.txt", nil, authenticated_as: "bob")

      assert info.holder == "bob"
    end

    test "renew by a different authenticated holder against an existing token is not_holder-class",
         ctx do
      {_pid, name} = start_bursar(ctx)

      assert {:ok, _} = Bursar.acquire(name, "readme.txt", "alice", authenticated_as: "alice")

      assert {:error, {:not_holder, "alice"}} =
               Bursar.renew(name, "readme.txt", "bob", authenticated_as: "bob")
    end
  end
end
