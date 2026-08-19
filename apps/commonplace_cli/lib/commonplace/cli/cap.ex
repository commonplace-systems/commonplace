defmodule Commonplace.CLI.Cap do
  @moduledoc """
  `commonplace cap` — issue, inspect, and revoke capability certs
  (CX-tdkq.22f phase 3; `revoke`/`supersede` added CX-bepn). A thin CLI
  wrapper over `Commonplace.Trust.Capability`.

      commonplace cap issue     --audience ID:PUBKEY_B64 --verbs write,delegate \\
                                --docs d1,d2 [--not-after 2030-01-01T00:00:00Z]
      commonplace cap delegate  --parent CID_HEX --audience ID:PUBKEY_B64 \\
                                --verbs write --docs d1 [--not-after ...]
      commonplace cap show CID_HEX
      commonplace cap revoke CID_HEX
      commonplace cap supersede --parent CID_HEX --audience ID:PUBKEY_B64 \\
                                --verbs write --docs d1 --revoke OLD_CID_HEX [--not-after ...]

  `issue` mints a ROOT cert signed by the local signing key (the workspace
  anchor); `delegate` attenuates an existing cert (fetched by CID),
  enforcing `child ⊆ parent` at mint. Both store the cert content-addressed
  and print its CID.

  ## `revoke` (CX-bepn — design doc §1/§8 step 5)

  Mints and stores a `Commonplace.Trust.Revocation` naming CID_HEX as
  void, signed by the local key. No local authority check happens here
  — per design §7.6/§2, whether this signer actually has revocation
  authority over that cert (issuer on its proof path, or its own
  audience) is validated at VERIFY time (`Trust.VerifyChain`), not at
  mint/store time; an unauthorized record is simply inert everywhere it
  is later checked.

  ## `supersede` (CX-bepn — design §5, pin P3)

  Supersession = **reissue THEN revoke**, in that exact order, so the
  holder never crosses a deny-gap: this mints+stores the NEW
  (narrower-or-equal) cert first via the same path as `delegate`, and
  ONLY THEN mints+stores a revocation of `--revoke`'s CID. Partial
  narrowing ("drop this doc from the grant") is supersession, never
  revocation-alone — revocation-alone would open a window where the
  holder has no valid cert at all.
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
      ["revoke", cid_hex] -> revoke(cid_hex)
      ["supersede" | rest] -> supersede(rest)
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

      {:ok,
       %{verbs: verbs, scope: {:docs, docs}, caveats: %{not_before: nil, not_after: not_after}}}
    end
  end

  defp parse_verbs(nil), do: {:ok, []}

  defp parse_verbs(str) do
    str
    |> String.split(",", trim: true)
    |> Enum.reduce_while({:ok, []}, fn v, {:ok, acc} ->
      atom = String.to_atom(v)

      if atom in @verbs,
        do: {:cont, {:ok, [atom | acc]}},
        else: {:halt, {:error, {:unknown_verb, v}}}
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

  @mint_switches [
    audience: :string,
    verbs: :string,
    docs: :string,
    not_after: :string,
    parent: :string,
    # CX-tdkq.28: override the mint-time write-without-execute-on-code-doc guard.
    allow_write_without_execute: :boolean,
    # CX-bepn: `cap supersede`'s old-cert CID, revoked AFTER the reissue.
    revoke: :string
  ]

  @doc false
  def parse_mint_argv(argv) do
    {opts, _, _} = OptionParser.parse(argv, strict: @mint_switches)
    opts
  end

  @doc false
  # Opts forwarded into Capability.issue/delegate: the store the code-doc
  # heuristic reads, plus the explicit override flag (CX-tdkq.28).
  def mint_opts(opts) do
    [store: CommitStoreClient, allow_write_without_execute: !!opts[:allow_write_without_execute]]
  end

  defp mint(kind, argv) do
    opts = parse_mint_argv(argv)

    with {:ok, audience} <- parse_audience(opts[:audience] || ""),
         {:ok, claim} <- parse_claim(opts),
         {:ok, ctx} <- local_signing_context(),
         {:ok, cap} <- do_mint(kind, ctx, audience, claim, opts) do
      :ok = CommitStoreClient.store_capability(CommitStoreClient, cap)
      IO.puts("Issued capability: #{Base.encode16(cap.id, case: :lower)}")
      IO.puts("  issuer:   #{elem(cap.issuer, 0)}")
      IO.puts("  audience: #{elem(cap.audience, 0)}")
      IO.puts("  verbs:    #{Enum.join(cap.claim.verbs, ",")}")
      {:docs, docs} = cap.claim.scope
      IO.puts("  scope:    #{Enum.join(docs, ",")}")
      if cap.proof, do: IO.puts("  proof:    #{Base.encode16(cap.proof, case: :lower)}")
    else
      {:error, {:write_without_execute_on_code_doc, uuid}} ->
        IO.puts(:stderr, """
        cap #{kind} refused: doc #{uuid} looks like CODE, and a :write-without-:execute
        cert on a code doc is the execute-baseline laundering input (CX-tdkq.28).
        Grant :execute too, or pass --allow-write-without-execute to override (best-effort
        heuristic; the Gate-B execute-clean walk is the airtight backstop).
        """)

        System.halt(1)

      {:error, :subtree_scope_not_delegable} ->
        IO.puts(:stderr, Commonplace.CertMint.refusal_text(:subtree_scope_not_delegable))
        System.halt(1)

      {:error, reason} ->
        IO.puts(:stderr, "cap #{kind} failed: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp do_mint(:issue, ctx, audience, claim, opts),
    do: Capability.issue(ctx, audience, claim, nil, mint_opts(opts))

  defp do_mint(:delegate, ctx, audience, claim, opts) do
    with {:ok, parent_cid} <- decode_cid(opts[:parent]),
         {:ok, parent} <- fetch_parent(parent_cid) do
      Capability.delegate(ctx, audience, claim, parent_cid, [parent: parent] ++ mint_opts(opts))
    end
  end

  defp decode_revoke_cid(nil), do: {:error, :missing_revoke_cid}
  defp decode_revoke_cid(hex), do: decode_cid(hex)

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

  defp revoke(cid_hex) do
    with {:ok, revoked_cid} <- decode_cid(cid_hex),
         {:ok, ctx} <- local_signing_context(),
         {:ok, rev} <- Capability.revoke(ctx, revoked_cid),
         :ok <- CommitStoreClient.store_revocation(CommitStoreClient, rev) do
      IO.puts("Revoked capability: #{Base.encode16(revoked_cid, case: :lower)}")
      IO.puts("  revocation id: #{Base.encode16(rev.id, case: :lower)}")
      IO.puts("  revoker:       #{Base.encode64(rev.revoker_pubkey)}")
    else
      {:error, reason} ->
        IO.puts(:stderr, "cap revoke failed: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp supersede(argv) do
    opts = parse_mint_argv(argv)

    with {:ok, old_cid} <- decode_revoke_cid(opts[:revoke]),
         {:ok, audience} <- parse_audience(opts[:audience] || ""),
         {:ok, claim} <- parse_claim(opts),
         {:ok, ctx} <- local_signing_context(),
         {:ok, parent_cid} <- decode_cid(opts[:parent]),
         {:ok, parent} <- fetch_parent(parent_cid),
         # Step 1 (P3, design §5): mint + store the NEW cert FIRST — the
         # holder must never cross a deny-gap between old and new.
         {:ok, new_cap} <-
           Capability.delegate(
             ctx,
             audience,
             claim,
             parent_cid,
             [parent: parent] ++ mint_opts(opts)
           ),
         :ok <- CommitStoreClient.store_capability(CommitStoreClient, new_cap),
         # Step 2: ONLY THEN revoke the old cert.
         {:ok, rev} <- Capability.revoke(ctx, old_cid),
         :ok <- CommitStoreClient.store_revocation(CommitStoreClient, rev) do
      IO.puts("Superseded capability: #{Base.encode16(old_cid, case: :lower)}")
      IO.puts("  new cert: #{Base.encode16(new_cap.id, case: :lower)}")
      IO.puts("    verbs:    #{Enum.join(new_cap.claim.verbs, ",")}")
      {:docs, docs} = new_cap.claim.scope
      IO.puts("    scope:    #{Enum.join(docs, ",")}")
      IO.puts("  revocation of old cert: #{Base.encode16(rev.id, case: :lower)}")
    else
      {:error, :missing_parent} ->
        IO.puts(:stderr, "cap supersede failed: --parent CID_HEX is required")
        System.halt(1)

      {:error, reason} ->
        IO.puts(:stderr, "cap supersede failed: #{inspect(reason)}")
        System.halt(1)
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
      uuid =
        case SecretStore.get("signing_identity") do
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
      commonplace cap issue     --audience ID:PUBKEY_B64 --verbs write,delegate --docs d1,d2 [--not-after ISO8601] [--allow-write-without-execute]
      commonplace cap delegate  --parent CID_HEX --audience ID:PUBKEY_B64 --verbs write --docs d1 [--not-after ISO8601] [--allow-write-without-execute]
      commonplace cap show CID_HEX
      commonplace cap revoke CID_HEX
      commonplace cap supersede --parent CID_HEX --audience ID:PUBKEY_B64 --verbs write --docs d1 --revoke OLD_CID_HEX [--not-after ISO8601] [--allow-write-without-execute]

      --allow-write-without-execute  override the CX-tdkq.28 guard that refuses a
                                     :write-without-:execute cert scoped to a code doc
    """)

    System.halt(1)
  end
end
