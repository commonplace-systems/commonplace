defmodule CommonplaceWebWeb.FederationController do
  @moduledoc """
  The federation HTTP surface (phase C, CX-orfw): pull-based commit
  exchange between separate-rooted workspaces — the thin transport the
  trust arc was built to make sufficient.

  Three endpoints, mirroring `NodeSync.catch_up`'s shape over HTTP:

    * `GET  /federation/docs/:uuid/cids`    — the doc's commit-CID set,
      for the puller's diff.
    * `POST /federation/docs/:uuid/commits` — requested CIDs → envelopes
      (commit + inlined cert chain, `Envelope.for_commit/2`).
    * `POST /federation/import`             — envelope in: certs are
      verified (id + sig — self-verifying values) and stored, then the
      commit goes through `import_commit` — Gate A UNCHANGED, the only
      door. The per-peer deferral budget 429s a peer that keeps sending
      commits which defer on `:awaiting_capability`, bounding its
      pending-queue contribution (CX-orfw.1 scope note).

  Nothing here weakens or substitutes for the import gate: a request
  that passes bearer auth still lands ONLY what Gate A verifies.
  """
  use CommonplaceWebWeb, :controller

  alias Commonplace.Federation.Envelope
  alias Commonplace.Store.CommitStoreClient
  alias CommonplaceWebWeb.FederationPeerBudget

  def cids(conn, %{"uuid" => uuid}) do
    cids =
      CommitStoreClient.commit_ids_for_doc(CommitStoreClient, uuid)
      |> Enum.map(&Base.encode64/1)

    json(conn, %{cids: cids})
  end

  def commits(conn, %{"uuid" => _uuid, "cids" => cids}) when is_list(cids) do
    {envelopes, missing} =
      Enum.reduce(cids, {[], []}, fn b64, {envs, miss} ->
        with {:ok, id} <- Base.decode64(b64),
             {:ok, commit} <- CommitStoreClient.get_commit(CommitStoreClient, id) do
          {[Envelope.for_commit(CommitStoreClient, commit) | envs], miss}
        else
          _ -> {envs, [b64 | miss]}
        end
      end)

    json(conn, %{envelopes: Enum.reverse(envelopes), missing: Enum.reverse(missing)})
  end

  def import(conn, %{"envelope" => encoded}) when is_binary(encoded) do
    peer = conn.assigns.federation_peer

    with {:ok, %{commit: commit, certs: certs}} <- Envelope.decode(encoded),
         :ok <- Envelope.verify_certs(certs) do
      if FederationPeerBudget.over_budget?(peer) do
        conn
        |> put_status(429)
        |> json(%{result: "over_deferral_budget"})
      else
        Enum.each(certs, &CommitStoreClient.store_capability(CommitStoreClient, &1))
        respond_import(conn, peer, CommitStoreClient.import_commit(CommitStoreClient, commit))
      end
    else
      {:error, reason} ->
        conn
        |> put_status(422)
        |> json(%{result: "bad_envelope", reason: to_string(reason)})
    end
  end

  defp respond_import(conn, _peer, :ok), do: json(conn, %{result: "ok"})

  defp respond_import(conn, peer, {:error, {:trust_rejected, :awaiting_capability}}) do
    # Queued in pending_imports — count it against this peer's budget.
    FederationPeerBudget.record_deferral(peer)
    json(conn, %{result: "deferred"})
  end

  defp respond_import(conn, _peer, {:error, reason}) do
    json(conn, %{result: "rejected", reason: inspect(reason)})
  end
end
