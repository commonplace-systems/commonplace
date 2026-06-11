defmodule Commonplace.CLI.Cap do
  @moduledoc """
  `commonplace cap` — issue and inspect capability certs (CX-tdkq.22f,
  phase 3). A thin CLI wrapper over `Commonplace.Trust.Capability`.

      commonplace cap issue    --audience ID:PUBKEY_B64 --verbs write,delegate \\
                               --docs d1,d2 [--not-after 2030-01-01T00:00:00Z]
      commonplace cap delegate --parent CID_HEX --audience ID:PUBKEY_B64 \\
                               --verbs write --docs d1 [--not-after ...]
      commonplace cap show CID_HEX

  `issue` mints a ROOT cert signed by the local signing key (the workspace
  anchor); `delegate` attenuates an existing cert (fetched by CID),
  enforcing `child ⊆ parent` at mint. Both store the cert content-addressed
  and print its CID.
  """

  alias Commonplace.CLI
  alias Commonplace.Crypto.SigningContext
  alias Commonplace.Store.{CommitStoreClient, SecretStore}
  alias Commonplace.Trust.Capability

  @verbs ~w(write execute delegate read bless)a

  def run(data_dir, _relative_path, args) do
    CLI.ensure_started(data_dir)

    case args do
      ["show", cid_hex] -> show(cid_hex)
      ["issue" | rest] -> mint(:issue, rest)
      ["delegate" | rest] -> mint(:delegate, rest)
      _ -> usage()
    end
  end

  # --- parsing (tested) ---

  @doc "Parse `identity:base64pubkey` into `{:ok, {id, pubkey}}`."
  def parse_audience(arg) do
    case String.split(arg, ":", parts: 2) do
      [id, b64] when id != "" ->
        case Base.decode64(b64) do
          {:ok, pub} -> {:ok, {id, pub}}
          :error -> {:error, :bad_pubkey}
        end

      _ ->
        {:error, :malformed_audience}
    end
  end

  @doc "Build a claim map from the parsed flags."
  def parse_claim(opts) do
    with {:ok, verbs} <- parse_verbs(opts[:verbs]),
         {:ok, not_after} <- parse_ts(opts[:not_after]) do
      docs = (opts[:docs] || "") |> String.split(",", trim: true)
      {:ok, %{verbs: verbs, scope: {:docs, docs}, caveats: %{not_before: nil, not_after: not_after}}}
    end
  end

  defp parse_verbs(nil), do: {:ok, []}

  defp parse_verbs(str) do
    str
    |> String.split(",", trim: true)
    |> Enum.reduce_while({:ok, []}, fn v, {:ok, acc} ->
      atom = String.to_atom(v)
      if atom in @verbs, do: {:cont, {:ok, [atom | acc]}}, else: {:halt, {:error, {:unknown_verb, v}}}
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.sort(list)}
      err -> err
    end
  end

  defp parse_ts(nil), do: {:ok, nil}

  defp parse_ts(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> {:ok, dt}
      {:error, reason} -> {:error, {:bad_timestamp, reason}}
    end
  end

  # --- commands ---

  defp mint(kind, argv) do
    {opts, _, _} =
      OptionParser.parse(argv,
        strict: [audience: :string, verbs: :string, docs: :string, not_after: :string, parent: :string]
      )

    with {:ok, audience} <- parse_audience(opts[:audience] || ""),
         {:ok, claim} <- parse_claim(opts),
         {:ok, ctx} <- local_signing_context(),
         {:ok, cap} <- do_mint(kind, ctx, audience, claim, opts[:parent]) do
      :ok = CommitStoreClient.store_capability(CommitStoreClient, cap)
      IO.puts("Issued capability: #{Base.encode16(cap.id, case: :lower)}")
      IO.puts("  issuer:   #{elem(cap.issuer, 0)}")
      IO.puts("  audience: #{elem(cap.audience, 0)}")
      IO.puts("  verbs:    #{Enum.join(cap.claim.verbs, ",")}")
      {:docs, docs} = cap.claim.scope
      IO.puts("  scope:    #{Enum.join(docs, ",")}")
      if cap.proof, do: IO.puts("  proof:    #{Base.encode16(cap.proof, case: :lower)}")
    else
      {:error, reason} ->
        IO.puts(:stderr, "cap #{kind} failed: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp do_mint(:issue, ctx, audience, claim, _parent), do: Capability.issue(ctx, audience, claim, nil)

  defp do_mint(:delegate, ctx, audience, claim, parent_hex) do
    with {:ok, parent_cid} <- decode_cid(parent_hex),
         {:ok, parent} <- fetch_parent(parent_cid) do
      Capability.delegate(ctx, audience, claim, parent_cid, parent: parent)
    end
  end

  defp decode_cid(nil), do: {:error, :missing_parent}

  defp decode_cid(hex) do
    case Base.decode16(hex, case: :mixed) do
      {:ok, cid} -> {:ok, cid}
      :error -> {:error, :bad_parent_cid}
    end
  end

  defp fetch_parent(cid) do
    case CommitStoreClient.get_capability(CommitStoreClient, cid) do
      {:ok, parent} -> {:ok, parent}
      :none -> {:error, :parent_not_found}
    end
  end

  defp show(cid_hex) do
    with {:ok, cid} <- decode_cid(cid_hex),
         {:ok, cap} <- fetch_parent(cid) do
      IO.inspect(cap, label: "capability")
    else
      _ ->
        IO.puts(:stderr, "no such capability: #{cid_hex}")
        System.halt(1)
    end
  end

  defp local_signing_context do
    with pid when is_pid(pid) <- Process.whereis(SecretStore),
         {:ok, enc_priv} <- SecretStore.get("signing_key:default"),
         {:ok, priv} <- Base.decode64(enc_priv),
         {:ok, enc_pub} <- SecretStore.get("signing_pub:default"),
         {:ok, pub} <- Base.decode64(enc_pub) do
      uuid = case SecretStore.get("signing_identity") do
        {:ok, id} -> id
        :not_found -> "anonymous"
      end

      {:ok, %SigningContext{identity_uuid: uuid, private_key: priv, public_key: pub}}
    else
      _ -> {:error, :no_signing_key}
    end
  end

  defp usage do
    IO.puts(:stderr, """
    Usage:
      commonplace cap issue    --audience ID:PUBKEY_B64 --verbs write,delegate --docs d1,d2 [--not-after ISO8601]
      commonplace cap delegate --parent CID_HEX --audience ID:PUBKEY_B64 --verbs write --docs d1 [--not-after ISO8601]
      commonplace cap show CID_HEX
    """)

    System.halt(1)
  end
end
