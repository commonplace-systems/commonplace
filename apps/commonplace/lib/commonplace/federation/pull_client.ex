defmodule Commonplace.Federation.PullClient do
  @moduledoc """
  Pull-based federation sync (phase C, CX-orfw): `NodeSync.catch_up`'s
  CID-diff shape over HTTP instead of BEAM RPC — the non-cookie
  transport that makes two workspaces genuinely separate trust domains.

  Per configured peer and doc: fetch the peer's CID set, diff against
  the local store, fetch the missing commits as envelopes (commit +
  inlined cert chain), verify + store the certs, and route each commit
  through `NodeSync.import_with_translation/3` — the SAME ingress the
  BEAM-cluster path uses, so Gate A, cross-epoch translation (now
  node-signed, CX-tdkq.26), and the pending-import retry queue all
  apply unchanged. The transport is dumb on purpose: commits and certs
  are content-addressed and self-verifying; authorization-to-land is
  entirely the import gate's.

  Out-of-order arrivals self-heal: a commit rejected this cycle because
  its parent hadn't landed yet stays in the peer's diff and is re-pulled
  next cycle (plus R11's pending queue absorbs `:awaiting_capability`
  and namespace deferrals immediately).

  ## Configuration

      config :commonplace, :federation_pull,
        interval_ms: 30_000,
        peers: [
          %{name: "peer-a", base_url: "https://a.example", token: "s3cret",
            docs: ["<doc-uuid>", ...]}
        ]

  No config ⇒ the client is not started (federation off by default).
  The `transport` option is injectable for tests; the default speaks
  HTTP via `Req` against the `commonplace_web` federation endpoints.
  """
  use GenServer
  require Logger

  alias Commonplace.Federation.Envelope
  alias Commonplace.Store.{CommitStore, CommitStoreClient}
  alias Commonplace.Sync.NodeSync

  @empty_report %{imported: 0, deferred: 0, rejected: 0, errors: []}

  # --- API ---

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Run one pull cycle over `peers` synchronously. Options: `:store`
  (default global CommitStore), `:transport` (default HTTP). Returns
  `%{imported: n, deferred: n, rejected: n, errors: [{peer, doc, reason}]}`.
  """
  def pull_once(peers, opts \\ []) do
    store = Keyword.get(opts, :store, CommitStore)
    transport = Keyword.get(opts, :transport, &http_transport/3)

    Enum.reduce(peers, @empty_report, fn peer, acc ->
      Enum.reduce(peer.docs, acc, fn doc, acc -> pull_doc(peer, doc, store, transport, acc) end)
    end)
  end

  # --- GenServer (interval-driven wrapper around pull_once/2) ---

  @impl true
  def init(opts) do
    state = %{
      peers: Keyword.fetch!(opts, :peers),
      interval_ms: Keyword.get(opts, :interval_ms, 30_000),
      store: Keyword.get(opts, :store, CommitStore),
      transport: Keyword.get(opts, :transport, &http_transport/3)
    }

    schedule(state)
    {:ok, state}
  end

  @impl true
  def handle_info(:pull, state) do
    report = pull_once(state.peers, store: state.store, transport: state.transport)

    if report.imported + report.deferred + report.rejected > 0 or report.errors != [] do
      Logger.info("Federation.PullClient: #{inspect(report)}")
    end

    schedule(state)
    {:noreply, state}
  end

  defp schedule(%{interval_ms: ms}) when is_integer(ms) and ms > 0 do
    Process.send_after(self(), :pull, ms)
  end

  defp schedule(_), do: :ok

  # --- one peer × doc pull ---

  defp pull_doc(peer, doc, store, transport, acc) do
    with {:ok, %{"cids" => remote_b64}} <- transport.(:cids, peer, doc),
         missing = diff_missing(store, doc, remote_b64),
         {:ok, %{"envelopes" => envelopes}} <- fetch_missing(transport, peer, doc, missing) do
      Enum.reduce(envelopes, acc, fn encoded, acc ->
        import_envelope(store, encoded, acc, peer, doc)
      end)
    else
      {:error, reason} -> %{acc | errors: acc.errors ++ [{peer.name, doc, reason}]}
    end
  end

  defp diff_missing(store, doc, remote_b64) do
    local =
      CommitStoreClient.all_commit_ids_for_doc(store, doc)
      |> Enum.map(&Base.encode64/1)
      |> MapSet.new()

    Enum.reject(remote_b64, &MapSet.member?(local, &1))
  end

  defp fetch_missing(_transport, _peer, _doc, []), do: {:ok, %{"envelopes" => []}}

  defp fetch_missing(transport, peer, doc, missing),
    do: transport.(:commits, peer, {doc, missing})

  defp import_envelope(store, encoded, acc, peer, doc) do
    with {:ok, %{commit: commit, certs: certs, revocations: revocations}} <-
           Envelope.decode(encoded),
         :ok <- Envelope.verify_certs(certs),
         :ok <- Envelope.verify_revocations(revocations) do
      Enum.each(certs, &CommitStoreClient.store_capability(store, &1))
      # CX-bepn (design §6): store sig-consistent revocations on arrival
      # WITHOUT validating revoker authority here — see
      # `Commonplace.Trust.Revocation`'s moduledoc (§7.6) for why an
      # early-arriving revocation (before its target cert's chain is
      # known) must still be stored, not dropped.
      Enum.each(revocations, &CommitStoreClient.store_revocation(store, &1))

      case NodeSync.import_with_translation(store, commit) do
        :ok ->
          %{acc | imported: acc.imported + 1}

        :already_exists ->
          acc

        {:error, {:trust_rejected, :awaiting_capability}} ->
          %{acc | deferred: acc.deferred + 1}

        {:error, _reason} ->
          %{acc | rejected: acc.rejected + 1}
      end
    else
      {:error, reason} -> %{acc | errors: acc.errors ++ [{peer.name, doc, reason}]}
    end
  end

  # --- default HTTP transport (the commonplace_web federation routes) ---

  defp http_transport(:cids, peer, doc) do
    request(:get, peer, "/federation/docs/#{doc}/cids", nil)
  end

  defp http_transport(:commits, peer, {doc, cids}) do
    request(:post, peer, "/federation/docs/#{doc}/commits", %{cids: cids})
  end

  defp request(method, peer, path, body) do
    opts = [
      method: method,
      url: peer.base_url <> path,
      headers: [{"authorization", "Bearer " <> peer.token}],
      retry: false
    ]

    opts = if body, do: Keyword.put(opts, :json, body), else: opts

    case Req.request(opts) do
      {:ok, %Req.Response{status: 200, body: %{} = decoded}} -> {:ok, decoded}
      {:ok, %Req.Response{status: status}} -> {:error, {:http_status, status}}
      {:error, exception} -> {:error, exception}
    end
  end
end
