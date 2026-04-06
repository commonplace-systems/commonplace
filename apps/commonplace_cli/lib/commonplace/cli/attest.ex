defmodule Commonplace.CLI.Attest do
  @moduledoc """
  CLI command for gold chain attestation.

  Creates signed attestations that a document's current head commit
  is the canonical state. Attestations form a tamper-evident chain.
  """

  alias Commonplace.CLI
  alias Commonplace.Gold.Chain
  alias Commonplace.Tree.Walk

  def run(data_dir, relative_path, args) do
    CLI.ensure_started(data_dir)
    root = CLI.root_uuid(data_dir)

    unless root do
      IO.puts(:stderr, "Not a commonplace workspace.")
      System.halt(1)
    end

    case args do
      [path] ->
        attest_path(root, relative_path, path)

      ["verify", path] ->
        verify_path(root, relative_path, path)

      ["log", path] ->
        log_path(root, relative_path, path)

      [] ->
        # Attest the current directory (its schema doc)
        dir_uuid = resolve_dir(root, relative_path)
        attest_doc(dir_uuid)

      _ ->
        IO.puts("""
        Usage: commonplace attest [path]        Sign the head of a document
               commonplace attest verify <path> Verify attestation chain
               commonplace attest log <path>    Show attestation history
        """)
        System.halt(1)
    end
  end

  defp attest_path(root, relative_path, path) do
    full_path = if relative_path == "", do: path, else: relative_path <> "/" <> path
    loader = &CLI.load_schema/1

    case Walk.resolve_path(root, full_path, loader) do
      {:ok, uuid} -> attest_doc(uuid)
      {:error, _} ->
        IO.puts(:stderr, "Not found: #{path}")
        System.halt(1)
    end
  end

  defp attest_doc(uuid) do
    case Chain.attest(uuid) do
      {:ok, att} ->
        fp = Base.encode16(att.id, case: :lower) |> binary_part(0, 12)
        commit_fp = Base.encode16(att.commit_id, case: :lower) |> binary_part(0, 12)
        IO.puts("Attested: #{uuid}")
        IO.puts("  Commit:      #{commit_fp}...")
        IO.puts("  Attestation: #{fp}...")
        IO.puts("  Signer:      #{att.signer_id}")
        IO.puts("  Time:        #{att.timestamp}")

        if att.prev_attestation_id do
          prev_fp = Base.encode16(att.prev_attestation_id, case: :lower) |> binary_part(0, 12)
          IO.puts("  Previous:    #{prev_fp}...")
        else
          IO.puts("  Previous:    (first attestation)")
        end

      {:error, :no_commits} ->
        IO.puts(:stderr, "No commits to attest for #{uuid}")
        System.halt(1)

      {:error, :no_signing_key} ->
        IO.puts(:stderr, "No signing key configured. Run: commonplace keygen")
        System.halt(1)

      {:error, reason} ->
        IO.puts(:stderr, "Attestation failed: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp verify_path(root, relative_path, path) do
    full_path = if relative_path == "", do: path, else: relative_path <> "/" <> path
    loader = &CLI.load_schema/1

    case Walk.resolve_path(root, full_path, loader) do
      {:ok, uuid} -> verify_doc(uuid)
      {:error, _} ->
        IO.puts(:stderr, "Not found: #{path}")
        System.halt(1)
    end
  end

  defp verify_doc(uuid) do
    chain = Chain.chain(uuid)

    if chain == [] do
      IO.puts("No attestations for #{uuid}")
    else
      case Commonplace.Store.SecretStore.get("signing_pub:default") do
        {:ok, encoded} ->
          {:ok, pub} = Base.decode64(encoded)

          case Chain.verify_chain(uuid, pub) do
            :ok ->
              IO.puts("Chain verified: #{length(chain)} attestation(s)")

            {:error, att_id, reason} ->
              fp = Base.encode16(att_id, case: :lower) |> binary_part(0, 12)
              IO.puts(:stderr, "Verification failed at #{fp}...: #{inspect(reason)}")
              System.halt(1)
          end

        :not_found ->
          IO.puts(:stderr, "No public key to verify against. Run: commonplace keygen")
          System.halt(1)
      end
    end
  end

  defp log_path(root, relative_path, path) do
    full_path = if relative_path == "", do: path, else: relative_path <> "/" <> path
    loader = &CLI.load_schema/1

    case Walk.resolve_path(root, full_path, loader) do
      {:ok, uuid} -> show_log(uuid)
      {:error, _} ->
        IO.puts(:stderr, "Not found: #{path}")
        System.halt(1)
    end
  end

  defp show_log(uuid) do
    chain = Chain.chain(uuid)

    if chain == [] do
      IO.puts("No attestations for #{uuid}")
    else
      IO.puts("Gold attestation chain for #{uuid} (#{length(chain)} entries):\n")

      Enum.each(chain, fn att ->
        fp = Base.encode16(att.id, case: :lower) |> binary_part(0, 12)
        commit_fp = Base.encode16(att.commit_id, case: :lower) |> binary_part(0, 12)
        IO.puts("  #{fp}...  commit=#{commit_fp}...  signer=#{att.signer_id}  #{att.timestamp}")
      end)
    end
  end

  defp resolve_dir(root, ""), do: root

  defp resolve_dir(root, path) do
    loader = &CLI.load_schema/1
    case Walk.resolve_path(root, path, loader) do
      {:ok, uuid} -> uuid
      {:error, _} -> root
    end
  end
end
