defmodule Commonplace.Bd.ClaimTest do
  @moduledoc """
  Bd P2 Slice S4 — claim/release via the green possession token.

  Claiming a ticket takes the Bursar's exclusive token (custody axis),
  NOT presence. Claiming does not move the ticket. `claimed_by` is a
  display MIRROR of the token; the token is authoritative — on
  divergence, `Frontier.eligible/2` (and a fresh `ticket_claim`) resolve
  toward the token, never the field.

  Fixture setup mirrors `Commonplace.Bd.TicketVerbsTest` /
  `Commonplace.Bd.CloseGateTest` — the dispatcher's verbs talk to the
  default-named `CommitStore` via `CommitStoreClient`, so this needs the
  "root pointer file + running default CommitStore" fixture. The Bursar
  is ALSO started under its default name (`Commonplace.Green.Bursar`,
  the name `BursarClient` routes to locally) against the SAME default
  store, mirroring `Commonplace.MUD.PlayerSessionTest`'s bursar-start
  pattern.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Bd.{Frontier, Issue}
  alias Commonplace.Crypto.Signing
  alias Commonplace.Crypto.SigningContext
  alias Commonplace.Green.Bursar
  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.Schema
  alias Commonplace.ViewActionDispatch

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_bd_claim_test_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    prior_data_dir = Application.get_env(:commonplace, :data_dir)
    Application.put_env(:commonplace, :data_dir, dir)

    sup = Commonplace.Store.CommitStoreSupervisor
    _ = Supervisor.terminate_child(sup, Commonplace.Store.CommitStore)
    _ = Supervisor.delete_child(sup, Commonplace.Store.CommitStore)

    {:ok, _pid} =
      Supervisor.start_child(sup, {Commonplace.Store.CommitStore, data_dir: dir})

    root_uuid = UUID.uuid4()
    root_doc = Schema.new_schema()
    update = Yelixer.Encoding.encode_update(root_doc)
    CommitStore.create_commit(Commonplace.Store.CommitStore, root_uuid, update, nil)
    File.write!(Path.join(dir, "root"), root_uuid)

    case GenServer.whereis(Bursar) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end

    {:ok, bursar_pid} =
      Bursar.start_link(
        root_uuid: UUID.uuid4(),
        store: Commonplace.Store.CommitStore,
        sweep_interval: 60_000
      )

    on_exit(fn ->
      if Process.alive?(bursar_pid) do
        try do
          GenServer.stop(bursar_pid)
        catch
          :exit, _ -> :ok
        end
      end

      Application.put_env(:commonplace, :data_dir, prior_data_dir || "tmp/test_data")
      File.rm_rf!(dir)
    end)

    {pub_a, priv_a} = Signing.generate_keypair()
    {pub_b, priv_b} = Signing.generate_keypair()

    ctx_a = %SigningContext{identity_uuid: "claim-test-a", private_key: priv_a, public_key: pub_a}
    ctx_b = %SigningContext{identity_uuid: "claim-test-b", private_key: priv_b, public_key: pub_b}

    %{root: root_uuid, ctx_a: ctx_a, ctx_b: ctx_b}
  end

  defp create_ticket(root_uuid, title) do
    {:ok, issue, _dir} = Issue.create(root_uuid, %{title: title})
    issue
  end

  defp claim(ticket_id, ctx) do
    context = %{
      args: %{"ticket" => ticket_id},
      signing_context: ctx,
      source: "test"
    }

    ViewActionDispatch.dispatch("ticket_claim", context)
  end

  defp release(ticket_id, ctx) do
    context = %{
      args: %{"ticket" => ticket_id},
      signing_context: ctx,
      source: "test"
    }

    ViewActionDispatch.dispatch("ticket_release", context)
  end

  defp principal(%SigningContext{identity_uuid: id, public_key: pub}) do
    Signing.signer_id(id, pub)
  end

  describe "claim happy path" do
    test "signed caller claims a ready ticket", %{root: root, ctx_a: ctx_a} do
      ticket = create_ticket(root, "claimable")

      assert {:ok, :tree_mutation, details} = claim(ticket.id, ctx_a)
      assert details.action == "ticket_claim"
      assert details.ticket == ticket.id
      assert details.claimed_by == principal(ctx_a)

      {:ok, reloaded} = Issue.show(root, ticket.id)
      assert reloaded.claimed_by == principal(ctx_a)

      claim_path = Commonplace.Bd.Workspace.claim_path!(root, ticket.id)
      assert {:held, %{holder: holder}} = Commonplace.Green.BursarClient.query(claim_path)
      assert holder == principal(ctx_a)
    end
  end

  describe "exclusivity pin" do
    test "a different claimant is refused while the token is held", %{
      root: root,
      ctx_a: ctx_a,
      ctx_b: ctx_b
    } do
      ticket = create_ticket(root, "contested")

      assert {:ok, :tree_mutation, _} = claim(ticket.id, ctx_a)
      assert {:error, reason} = claim(ticket.id, ctx_b)
      assert reason =~ "already claimed"
      refute reason =~ "{:denied"

      {:ok, reloaded} = Issue.show(root, ticket.id)
      assert reloaded.claimed_by == principal(ctx_a)

      claim_path = Commonplace.Bd.Workspace.claim_path!(root, ticket.id)
      assert {:held, %{holder: holder}} = Commonplace.Green.BursarClient.query(claim_path)
      assert holder == principal(ctx_a)
    end
  end

  describe "release" do
    test "the holder releases: token available, claimed_by cleared", %{
      root: root,
      ctx_a: ctx_a
    } do
      ticket = create_ticket(root, "releasable")
      assert {:ok, :tree_mutation, _} = claim(ticket.id, ctx_a)

      assert {:ok, :tree_mutation, details} = release(ticket.id, ctx_a)
      assert details.action == "ticket_release"

      {:ok, reloaded} = Issue.show(root, ticket.id)
      assert reloaded.claimed_by == nil

      claim_path = Commonplace.Bd.Workspace.claim_path!(root, ticket.id)
      assert Commonplace.Green.BursarClient.query(claim_path) == :available
    end

    test "a non-holder release is refused", %{root: root, ctx_a: ctx_a, ctx_b: ctx_b} do
      ticket = create_ticket(root, "guarded")
      assert {:ok, :tree_mutation, _} = claim(ticket.id, ctx_a)

      assert {:error, _reason} = release(ticket.id, ctx_b)

      {:ok, reloaded} = Issue.show(root, ticket.id)
      assert reloaded.claimed_by == principal(ctx_a)

      claim_path = Commonplace.Bd.Workspace.claim_path!(root, ticket.id)
      assert {:held, %{holder: holder}} = Commonplace.Green.BursarClient.query(claim_path)
      assert holder == principal(ctx_a)
    end
  end

  describe "eligible = ready minus claimed" do
    test "a claimed ready ticket drops out of eligible; releasing restores it", %{
      root: root,
      ctx_a: ctx_a
    } do
      a = create_ticket(root, "ready-a")
      b = create_ticket(root, "ready-b")

      eligible_ids = Frontier.eligible(root) |> Enum.map(& &1.id)
      assert a.id in eligible_ids
      assert b.id in eligible_ids

      assert {:ok, :tree_mutation, _} = claim(a.id, ctx_a)

      eligible_ids = Frontier.eligible(root) |> Enum.map(& &1.id)
      refute a.id in eligible_ids
      assert b.id in eligible_ids

      assert {:ok, :tree_mutation, _} = release(a.id, ctx_a)

      eligible_ids = Frontier.eligible(root) |> Enum.map(& &1.id)
      assert a.id in eligible_ids
      assert b.id in eligible_ids
    end
  end

  describe "token-authoritative-over-field divergence" do
    test "a stale claimed_by with no held token does not block eligible or a fresh claim", %{
      root: root,
      ctx_a: ctx_a,
      ctx_b: ctx_b
    } do
      ticket = create_ticket(root, "stale-field")

      assert {:ok, :tree_mutation, _} = claim(ticket.id, ctx_a)

      claim_path = Commonplace.Bd.Workspace.claim_path!(root, ticket.id)
      assert :ok = Commonplace.Green.BursarClient.force_release(claim_path)

      # claimed_by is still stamped "A" on the ticket, but the token is
      # free — the token wins, so the ticket is still eligible...
      {:ok, still_stamped} = Issue.show(root, ticket.id)
      assert still_stamped.claimed_by == principal(ctx_a)

      eligible_ids = Frontier.eligible(root) |> Enum.map(& &1.id)
      assert ticket.id in eligible_ids

      # ...and a fresh claim by a DIFFERENT principal succeeds, because
      # the real custody token (not the display mirror) is what's checked.
      assert {:ok, :tree_mutation, details} = claim(ticket.id, ctx_b)
      assert details.claimed_by == principal(ctx_b)

      {:ok, reloaded} = Issue.show(root, ticket.id)
      assert reloaded.claimed_by == principal(ctx_b)
    end
  end

  describe "claimed_by stays gate-exclusive" do
    test "ticket_update still refuses a direct claimed_by write", %{root: root, ctx_a: ctx_a} do
      ticket = create_ticket(root, "guarded-field")

      context = %{
        args: %{"ticket" => ticket.id, "changes" => %{"claimed_by" => "x@y"}},
        signing_context: ctx_a,
        source: "test"
      }

      assert {:error, reason} = ViewActionDispatch.dispatch("ticket_update", context)
      assert reason =~ "claimed_by"

      {:ok, reloaded} = Issue.show(root, ticket.id)
      assert reloaded.claimed_by == nil
    end
  end
end
