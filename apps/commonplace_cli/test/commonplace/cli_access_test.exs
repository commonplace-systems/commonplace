defmodule Commonplace.CLI.AccessTest do
  @moduledoc """
  CX-x8jk: the CLI must decide route / refuse / local BEFORE it opens
  anything, and its probe must never evict the holder it is asking about.

  No distribution here (standing constraint: no `Node.start` in tests) —
  the serve side is injected as a connector function, which is exactly
  the seam `Access.resolve/2` and `Access.ensure_started/2` expose.
  """
  use ExUnit.Case, async: false

  alias Commonplace.CLI.Access
  alias Commonplace.Store.{CommitStore, LockRefusal}
  alias Commonplace.Flock

  defp tmp_dir(tag) do
    dir = Path.join(System.tmp_dir!(), "cx_x8jk_#{tag}_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  # A live flock(2) holder on <dir>/commits.lock, in another process,
  # standing in for a running serve's CommitStore.
  defp hold_flock(dir, hint \\ "31337 commonplace_dev@commonplace\n") do
    path = CommitStore.commits_lock_path(dir)
    File.touch!(path)
    File.write!(path, hint)
    me = self()

    holder =
      spawn(fn ->
        {:ok, _ref} = Flock.try_lock(path, :exclusive)
        send(me, :locked)
        receive do: (:never -> :ok)
      end)

    assert_receive :locked, 1_000
    on_exit(fn -> Process.exit(holder, :kill) end)
    {holder, path}
  end

  defp reachable(node), do: fn _dir -> {:ok, node} end
  defp unreachable, do: fn _dir -> {:not_running, {:node_connect, false}} end

  # Effect stubs: record which branch ran instead of doing it.
  defp recording_effects do
    me = self()

    [
      on_route: fn node -> send(me, {:effect, :route, node}) end,
      on_local: fn dir -> send(me, {:effect, :local, dir}) end,
      on_refuse: fn dir, failure -> send(me, {:effect, :refuse, dir, failure}) end
    ]
  end

  describe "decide/2 — the whole table" do
    test "serve reachable → route, whatever the lock says" do
      assert {:route, :serve@host} = Access.decide({:ok, :serve@host}, :held)
      assert {:route, :serve@host} = Access.decide({:ok, :serve@host}, :free)
      assert {:route, :serve@host} = Access.decide({:ok, :serve@host}, :not_probed)
    end

    test "no serve + lock held → refuse" do
      assert {:refuse, {:node_connect, false}} =
               Access.decide({:not_running, {:node_connect, false}}, :held)
    end

    test "no serve + lock free → local (the offline case must keep working)" do
      assert :local = Access.decide({:not_running, {:node_connect, false}}, :free)
    end
  end

  describe "resolve/2 — inputs wired to the table" do
    test "routes without probing the lock at all" do
      me = self()
      probe = fn dir -> send(me, {:probed, dir}) && :free end

      assert {:route, :serve@host} =
               Access.resolve("/nope", connect: reachable(:serve@host), probe_lock: probe)

      refute_receive {:probed, _}, 50
    end

    test "refuses when the store is locked and no serve answers" do
      dir = tmp_dir("resolve_refuse")
      hold_flock(dir)

      assert {:refuse, {:node_connect, false}} =
               Access.resolve(dir, connect: unreachable())
    end

    test "opens locally when nothing holds the lock and no serve answers" do
      dir = tmp_dir("resolve_local")
      assert :local = Access.resolve(dir, connect: unreachable())
    end
  end

  describe "probe_lock/1" do
    test "a held lock reads :held; a free one reads :free" do
      held = tmp_dir("probe_held")
      hold_flock(held)
      assert :held = Access.probe_lock(held)

      free = tmp_dir("probe_free")
      File.touch!(CommitStore.commits_lock_path(free))
      assert :free = Access.probe_lock(free)
    end

    test "a data dir with no lock file reads :free and the probe creates nothing" do
      dir = tmp_dir("probe_enoent")
      assert :free = Access.probe_lock(dir)
      refute File.exists?(CommitStore.commits_lock_path(dir))
    end

    test "PROBE HARMLESSNESS: the holder still holds, and still excludes a third opener" do
      dir = tmp_dir("probe_harmless")
      {holder, path} = hold_flock(dir, "31337 serve@somewhere\n")
      before = File.read!(path)

      # The tool-layer probe, twice for good measure.
      assert :held = Access.probe_lock(dir)
      assert :held = Access.probe_lock(dir)

      # 1. The holder process is untouched.
      assert Process.alive?(holder)

      # 2. A THIRD, independent opener is still excluded — the probe did
      #    not release, transfer, or weaken the holder's lock.
      assert {:error, :would_block} = Flock.try_lock(path, :exclusive)

      # 3. The diagnostic hint is byte-for-byte what the holder wrote
      #    (the deleted prose-lock clobbered it with a bare pid).
      assert File.read!(path) == before

      # 4. And it is genuinely a lock, not a stuck test: once the holder
      #    dies the lock is acquirable, so (2) measured exclusion rather
      #    than some permanent failure to open.
      ref = Process.monitor(holder)
      Process.exit(holder, :kill)
      assert_receive {:DOWN, ^ref, :process, ^holder, :killed}, 1_000

      free =
        Enum.reduce_while(1..100, false, fn _, _ ->
          case Flock.try_lock(path, :exclusive) do
            {:ok, r} ->
              Flock.unlock(r)
              {:halt, true}

            _ ->
              Process.sleep(10)
              {:cont, false}
          end
        end)

      assert free, "lock never became acquirable — (2) may not have measured exclusion"
    end
  end

  describe "ensure_started/2 — the chosen branch is the one that runs" do
    test "route branch hands the serve node to the remote path" do
      Access.ensure_started(
        "/nope",
        [connect: reachable(:serve@host)] ++ recording_effects()
      )

      assert_receive {:effect, :route, :serve@host}
      refute_receive {:effect, :local, _}, 50
      refute_receive {:effect, :refuse, _}, 50
    end

    test "refuse branch runs when locked with no serve — no local open is attempted" do
      dir = tmp_dir("ensure_refuse")
      hold_flock(dir)

      Access.ensure_started(dir, [connect: unreachable()] ++ recording_effects())

      assert_receive {:effect, :refuse, ^dir, {:node_connect, false}}
      refute_receive {:effect, :local, _}, 50
      refute_receive {:effect, :route, _}, 50
    end

    test "local branch runs offline with a free lock" do
      dir = tmp_dir("ensure_local")

      Access.ensure_started(dir, [connect: unreachable()] ++ recording_effects())

      assert_receive {:effect, :local, ^dir}
      refute_receive {:effect, :refuse, _}, 50
    end
  end

  describe "the refusal text" do
    test "names the sanctioned door, in the store layer's own words" do
      dir = tmp_dir("refusal_text")
      path = CommitStore.commits_lock_path(dir)
      File.write!(path, "31337 commonplace_dev@commonplace\n")

      text = LockRefusal.cli_refusal(dir, path)

      # One helper, not two copies: this is byte-identical to what
      # CommitStore's {:commits_store_locked, detail} carries.
      assert text =~ LockRefusal.sanctioned_access_message()
      assert text =~ "CommitStoreClient"
      assert text =~ path
      # The holder hint is surfaced, and labelled as a hint.
      assert text =~ "31337 commonplace_dev@commonplace"
      assert text =~ "NOT proof"
    end

    test "names each reach step and its observed return value" do
      dir = tmp_dir("refusal_reach_steps")
      path = CommitStore.commits_lock_path(dir)
      File.touch!(path)

      cases = [
        {{:read_node_name, nil}, "read_node_name(#{inspect(dir)}) returned nil"},
        {{:node_start, {:error, :eaddrnotavail}},
         "Node.start(cli_name, :shortnames) returned {:error, :eaddrnotavail}"},
        {{:node_connect, false}, "Node.connect(serve_node) returned false"},
        {{:verify_serves_this_dir, {:mismatch, "/other/data"}},
         "verify_serves_this_dir(serve_node, data_dir) returned {:mismatch, \"/other/data\"}"}
      ]

      assert length(cases) == 4

      for {failure, expected} <- cases do
        assert LockRefusal.cli_refusal(dir, path, failure) =~ expected
      end
    end

    test "an empty lock file does not produce a blank hint" do
      dir = tmp_dir("refusal_empty")
      path = CommitStore.commits_lock_path(dir)
      File.touch!(path)

      assert LockRefusal.holder_hint(path) == "(lock file empty or unreadable)"
      assert LockRefusal.cli_refusal(dir, path) =~ "(lock file empty or unreadable)"
    end
  end

  describe "connect_to_serve/2 — step-level outcomes" do
    test "four distinct failures preserve the step and actual return" do
      dir = tmp_dir("reach_failures")
      serve_node = :cx_a3fe_absent@commonplace
      File.write!(Path.join(dir, "node_name"), Atom.to_string(serve_node))
      started = fn _name -> {:ok, self()} end
      not_stopped = fn -> :ok end

      assert {:not_running, {:read_node_name, nil}} =
               Access.connect_to_serve(dir, read_node_name: fn _ -> nil end)

      assert {:not_running, {:node_start, {:error, :eaddrnotavail}}} =
               Access.connect_to_serve(dir,
                 start_node: fn _ -> {:error, :eaddrnotavail} end
               )

      assert {:not_running, {:node_connect, false}} =
               Access.connect_to_serve(dir,
                 start_node: started,
                 connect_node: fn ^serve_node -> false end,
                 stop_node: not_stopped
               )

      assert {:not_running, {:verify_serves_this_dir, {:mismatch, "/other/data"}}} =
               Access.connect_to_serve(dir,
                 start_node: started,
                 connect_node: fn ^serve_node -> true end,
                 verify_dir: fn ^serve_node, ^dir -> {:mismatch, "/other/data"} end,
                 stop_node: not_stopped
               )
    end

    test "a named fixture node is reachable while an absent node records false" do
      peer_name = :cx_a3fe_fixture

      peer =
        start_supervised!(%{
          id: :cx_a3fe_fixture_peer,
          start:
            {:peer, :start_link,
             [
               %{
                 name: peer_name,
                 connection: :standard_io,
                 args: [~c"-setcookie", ~c"cx_a3fe_fixture_cookie"]
               }
             ]}
        })

      dir = tmp_dir("named_fixture")
      peer_node = :peer.call(peer, :erlang, :node, [])
      :ok = :peer.call(peer, :application, :set_env, [:commonplace, :data_dir, dir])
      File.write!(Path.join(dir, "node_name"), Atom.to_string(peer_node))

      opts = [
        start_node: fn _ -> {:ok, self()} end,
        connect_node: fn node -> :peer.call(peer, :erlang, :node, []) == node end,
        verify_dir: fn node, expected_dir ->
          if node == peer_node and
               :peer.call(peer, :application, :get_env, [:commonplace, :data_dir]) ==
                 {:ok, expected_dir},
             do: :ok,
             else: {:mismatch, :fixture_control_failed}
        end,
        stop_node: fn -> :ok end
      ]

      assert {:ok, ^peer_node} = Access.connect_to_serve(dir, opts)

      File.write!(Path.join(dir, "node_name"), "cx_a3fe_absent@commonplace")

      assert {:not_running, {:node_connect, false}} =
               Access.connect_to_serve(dir, opts)
    end
  end
end
