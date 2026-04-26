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
      # Restore to the test-config default ("tmp/test_data") instead of
      # the captured prior_data_dir — captured-prior is racy under
      # parallel async:false execution (test A captures prior; test B's
      # setup mutates :data_dir; B's on_exit restores to a since-deleted
      # scratch dir, leaving production CommitStore dead).
      _ = Supervisor.terminate_child(sup, Commonplace.Store.CommitStore)
      _ = Supervisor.delete_child(sup, Commonplace.Store.CommitStore)

      Application.put_env(:commonplace, :data_dir, "tmp/test_data")

      {:ok, _pid} =
        Supervisor.start_child(
          sup,
          {Commonplace.Store.CommitStore, data_dir: "tmp/test_data"}
        )

      File.rm_rf!(dir)
      DocCache.clear()
    end)

    %{root: root_uuid}
  end

  describe "presence identity enrichment" do
    test "collision-renamed presence file still resolves cold identity (CX-5gp)",
         %{conn: conn, root: root_uuid} do
      # Register one cold identity. There's only ONE Identity per actor
      # name+type, regardless of how many presence files end up renamed.
      {:ok, _identity_uuid} = Identity.register("claude-code", :bot, root_uuid)

      # Two presence files for the same actor — second one collision-
      # renames to "claude-code-<suffix>.bot", but the doc's `name` field
      # still stores the original "claude-code".
      {:ok, _first_uuid} = Presence.create("claude-code", :bot, root_uuid)
      {:ok, second_uuid} = Presence.create("claude-code", :bot, root_uuid)

      # Find the suffixed filename so we can navigate to it.
      schema_doc = read_root_schema(root_uuid)
      suffixed_name =
        schema_doc
        |> Schema.list_entries()
        |> Enum.find(fn entry ->
          entry.node_id == second_uuid and entry.name != "claude-code.bot"
        end)
        |> Map.fetch!(:name)

      assert suffixed_name != "claude-code.bot",
             "test fixture invariant: second create must collision-rename"

      {:ok, _view, html} = live(conn, "/wiki/#{suffixed_name}")

      assert html =~ ~s(data-testid="presence-card"),
             "presence card should render for collision-renamed file"

      assert html =~ "cp-presence-identity",
             "identity panel missing on collision-renamed presence file"

      assert html =~ "first seen:",
             "Identity.lookup should find the cold identity via stored content[name], not the parsed filename"

      refute html =~ "no cold identity record",
             "wiki_live used the parsed filename for Identity.lookup and missed the cold identity"
    end

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

  defp read_root_schema(root_uuid) do
    {:ok, commit} = CommitStore.latest_commit(Commonplace.Store.CommitStore, root_uuid)
    doc = Schema.new_schema()
    {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)
    doc
  end
end
