defmodule CommonplaceWebWeb.WikiLiveTest do
  @moduledoc """
  LiveView tests for the wiki surface.

  CX-4ba codex P1: presence identity enrichment must survive live PubSub
  refreshes. The initial page load attaches `:__identity__` to the presence
  YMap via `maybe_enrich_presence/3`, but before this fix, any subsequent
  heartbeat/status/activity commit (or a Edit -> View toggle) replaced
  `page_content` with the raw `read_doc_content/1` result and the identity
  panel disappeared until the next full navigation. This test pins the
  regression: the Identity panel must still show the cold identity
  first_seen/last_seen after a `Presence.heartbeat/1` landed on the doc.
  """
  use CommonplaceWebWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Commonplace.Presence
  alias Commonplace.Presence.Identity
  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.{DocCache, Schema}

  setup do
    # The web app boots the commonplace app which starts a default
    # CommitStore at `Application.get_env(:commonplace, :data_dir)`. For
    # LiveView tests we point that default store at a scratch directory,
    # restart it, and clean up on exit. This keeps the test fully
    # self-contained without introducing a dedicated test store.
    prior_data_dir = Application.get_env(:commonplace, :data_dir)
    dir = Path.join(System.tmp_dir!(), "cp_wiki_live_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    Application.put_env(:commonplace, :data_dir, dir)

    # Restart the default CommitStore pointing at the scratch dir.
    sup = Commonplace.Store.CommitStoreSupervisor
    _ = Supervisor.terminate_child(sup, Commonplace.Store.CommitStore)
    _ = Supervisor.delete_child(sup, Commonplace.Store.CommitStore)

    {:ok, _pid} =
      Supervisor.start_child(
        sup,
        {Commonplace.Store.CommitStore, data_dir: dir}
      )

    # The DocCache subscribes to new-commit invalidations; clear any stale
    # snapshots from prior tests.
    DocCache.clear()

    # Seed the root schema + root pointer file so WikiLive.mount/3 can
    # locate it via `read_root_uuid/1`.
    root_uuid = UUID.uuid4()
    root_doc = Schema.new_schema()
    update = Yelixer.Encoding.encode_update(root_doc)
    CommitStore.create_commit(Commonplace.Store.CommitStore, root_uuid, update, nil)
    File.write!(Path.join(dir, "root"), root_uuid)

    on_exit(fn ->
      # Restore the previous data_dir and point the store back at it so
      # subsequent tests aren't affected.
      _ = Supervisor.terminate_child(sup, Commonplace.Store.CommitStore)
      _ = Supervisor.delete_child(sup, Commonplace.Store.CommitStore)

      Application.put_env(:commonplace, :data_dir, prior_data_dir)

      _ =
        Supervisor.start_child(
          sup,
          {Commonplace.Store.CommitStore, data_dir: prior_data_dir}
        )

      File.rm_rf!(dir)
      DocCache.clear()
    end)

    %{root: root_uuid}
  end

  describe "presence identity enrichment" do
    test "renders identity panel on initial load and preserves it across live refreshes",
         %{conn: conn, root: root_uuid} do
      # Register a cold identity (creates __identities__/bartleby.bot with
      # first_seen / last_seen timestamps) and a presence file for the
      # same actor under the root schema.
      {:ok, _identity_uuid} = Identity.register("bartleby", :bot, root_uuid)
      {:ok, presence_uuid} = Presence.create("bartleby", :bot, root_uuid)

      {:ok, view, html} = live(conn, "/wiki/bartleby.bot")

      # Initial load: presence card with identity panel is visible and
      # shows the cold-identity first_seen line from the __identities__
      # record.
      assert html =~ ~s(data-testid="presence-card")
      assert html =~ "cp-presence-identity"
      assert html =~ "first seen:"
      refute html =~ "no cold identity record"

      # Trigger a heartbeat commit on the presence doc. The WikiLive is
      # subscribed to blue:<presence_uuid> and will receive
      # {:commit, uuid, commit_id, meta}.
      Presence.heartbeat(presence_uuid)

      # After the live refresh the identity panel must STILL be present.
      # Before the fix, handle_info({:commit,...}) replaced page_content
      # with read_doc_content/1 (no enrichment), so :__identity__ was
      # dropped and the aside fell back to "no cold identity record".
      refreshed = render(view)
      assert refreshed =~ ~s(data-testid="presence-card")
      assert refreshed =~ "cp-presence-identity"
      assert refreshed =~ "first seen:"
      refute refreshed =~ "no cold identity record"
    end
  end
end
