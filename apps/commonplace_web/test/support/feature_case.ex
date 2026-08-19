defmodule CommonplaceWebWeb.FeatureCase do
  @moduledoc """
  CX-xwh4: ExUnit case template for end-to-end browser tests via Wallaby.

  Each feature test:

    * Repoints the production-named CommitStore at a per-test scratch
      data dir (mirrors `wiki_live_test.exs` setup pattern). Restores
      on exit. Keeps the running serve / dev workspace untouched.
    * Flips `config :commonplace_web, CommonplaceWebWeb.Endpoint, server: true`
      for the test duration so Bandit binds and Wallaby can drive the
      LiveView via real HTTP. Restores on exit. Other tests in the
      suite still see the endpoint with `server: false`, so unit-test
      isolation is preserved.
    * Resets `Commonplace.Chat.OnrampSupervisor` so per-room red-onramp
      state doesn't leak between feature tests.
    * Spawns a Wallaby session under headless Chrome (configured in
      `config/test.exs`).

  Tests use the standard Wallaby DSL (`visit/2`, `find/2`, `fill_in/2`,
  `click/2`, etc.) and can call `take_screenshot/1` for demo capture.
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      use Wallaby.Feature

      alias Commonplace.Chat.{Actions, Rooms}
      alias Commonplace.Store.CommitStore
      alias Commonplace.Tree.{DocCache, Schema}

      import Wallaby.Browser
      import Wallaby.Query

      @endpoint CommonplaceWebWeb.Endpoint
    end
  end

  setup _tags do
    # Mirror the wiki_live_test.exs CommitStore-repoint pattern so each
    # feature test runs against a fresh workspace.
    #
    # Restore to the test-config default ("tmp/test_data") in on_exit —
    # NOT a captured prior_data_dir. Captured-prior is racy under
    # parallel async:false execution (test A captures prior=tmp/test_data
    # then sets scratch1; test B's setup runs before A's on_exit and
    # captures prior=scratch1; B's on_exit then restores to a deleted
    # scratch dir, leaving production CommitStore dead).
    dir = Path.join(System.tmp_dir!(), "cp_feature_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    Application.put_env(:commonplace, :data_dir, dir)

    sup = Commonplace.Store.CommitStoreSupervisor
    _ = Supervisor.terminate_child(sup, Commonplace.Store.CommitStore)
    _ = Supervisor.delete_child(sup, Commonplace.Store.CommitStore)

    {:ok, _pid} =
      Supervisor.start_child(sup, {Commonplace.Store.CommitStore, data_dir: dir})

    Commonplace.Tree.DocCache.clear()
    Commonplace.Chat.OnrampSupervisor.reset()
    Commonplace.Chat.ChatViewComputeSupervisor.reset()

    root_uuid = UUID.uuid4()
    root_doc = Commonplace.Tree.Schema.new_schema()
    update = Yelixer.Encoding.encode_update(root_doc)

    Commonplace.Store.CommitStore.create_commit(
      Commonplace.Store.CommitStore,
      root_uuid,
      update,
      nil
    )

    File.write!(Path.join(dir, "root"), root_uuid)

    on_exit(fn ->
      _ = Supervisor.terminate_child(sup, Commonplace.Store.CommitStore)
      _ = Supervisor.delete_child(sup, Commonplace.Store.CommitStore)
      Application.put_env(:commonplace, :data_dir, "tmp/test_data")

      {:ok, _pid} =
        Supervisor.start_child(sup, {Commonplace.Store.CommitStore, data_dir: "tmp/test_data"})

      File.rm_rf!(dir)
      Commonplace.Tree.DocCache.clear()
      Commonplace.Chat.OnrampSupervisor.reset()
      Commonplace.Chat.ChatViewComputeSupervisor.reset()
    end)

    %{root: root_uuid, data_dir: dir}
  end
end
