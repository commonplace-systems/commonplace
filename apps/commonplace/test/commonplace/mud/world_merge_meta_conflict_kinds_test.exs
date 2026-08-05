defmodule Commonplace.MUD.WorldMergeMetaConflictKindsTest do
  @moduledoc """
  CX-g8s9 — WHICH refusal does a contended meta write actually produce?

  `World.merge_meta/5`'s CAS loop retries `{:error, :parent_moved}`. But
  that is not the only way a concurrent write is refused. `write_meta_doc`
  ALSO calls `verify_meta_roundtrip/4`, which RE-READS the doc from the
  store, applies the positional diff it just computed, and checks the
  result equals the intended JSON:

      with {:ok, base} <- DocBuilder.reconstruct_doc(store, uuid),
           {:ok, merged} <- Encoding.apply_update(base, update),
           ^intended <- ContentType.get_content(merged) do

  If a concurrent writer commits between `write_meta_doc`'s own read and
  THAT read, `base` is newer than the text the diff was computed against,
  applying the diff yields something other than `intended`, and the write
  is refused with `:meta_write_roundtrip_failed`. That refusal is the
  guard WORKING — it catches the splice before it can commit.

  The question this file answers by measurement: is that refusal RETRIED?
  It is not — `merge_meta_cas` only retries `:parent_moved`. So the same
  concurrency can be refused two different ways, one recoverable and one
  terminal, decided purely by which read happened to lose the race.

  These tests are CONCURRENT and therefore stochastic. They assert only
  what is invariant (no silent loss, no corruption, refusals are one of a
  known set) and REPORT the distribution rather than asserting a
  particular mix — a count that varies run to run must not be an
  assertion. See the report lines in the output.
  """
  use ExUnit.Case

  alias Commonplace.Document.ContentType
  alias Commonplace.MUD.Schemas
  alias Commonplace.MUD.Schemas.Room
  alias Commonplace.MUD.World
  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.{DocBuilder, Schema}

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_mud_conflict_kinds_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    store_name = :"commit_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store_name})
    on_exit(fn -> File.rm_rf!(dir) end)
    %{store: store_name}
  end

  # Fire `n` concurrent merge_meta calls, each appending its own key.
  # Returns {results, final_parsed_or_error}.
  defp fire(dir_uuid, store, n) do
    results =
      1..n
      |> Task.async_stream(
        fn i ->
          World.merge_meta(
            dir_uuid,
            Schemas.room_filename(),
            %{"w#{i}" => "v#{i}"},
            store
          )
        end,
        max_concurrency: n,
        timeout: 60_000
      )
      |> Enum.map(fn {:ok, r} -> r end)

    {results, read_raw(dir_uuid, store)}
  end

  # Read the meta RAW (stopping before Jason.decode) so a corrupt blob is
  # visible instead of being swallowed into an {:error, _}.
  defp read_raw(dir_uuid, store) do
    {:ok, schema} = Schemas.load_dir_schema(dir_uuid, store)
    {:ok, entry} = Schema.get_entry(schema, Schemas.room_filename())

    case DocBuilder.reconstruct_doc(store, entry.node_id) do
      {:ok, doc} -> {:ok, ContentType.get_content(doc)}
      other -> {:error, other}
    end
  end

  defp tally(results) do
    Enum.reduce(results, %{}, fn r, acc ->
      key =
        case r do
          :ok -> :ok
          {:error, reason} -> reason
          other -> {:unexpected, other}
        end

      Map.update(acc, key, 1, &(&1 + 1))
    end)
  end

  for n <- [8, 16] do
    test "#{n}-way contended merge_meta: which refusals appear, and is the doc intact?", %{
      store: store
    } do
      n = unquote(n)
      json = Schemas.encode_room(%Room{name: "Start", description: "A room."})
      {:ok, dir_uuid} = Schemas.create_dir_with_meta(Schemas.room_filename(), json, store)

      {results, raw} = fire(dir_uuid, store, n)
      counts = tally(results)

      IO.puts("\n[CX-g8s9 #{n}-way] refusal tally: #{inspect(counts)}")

      # The doc must still be READABLE and PARSEABLE. This is the
      # non-negotiable one: a refused write must leave nothing behind.
      assert {:ok, blob} = raw
      assert is_binary(blob)

      parsed =
        case Jason.decode(blob) do
          {:ok, map} -> map
          {:error, e} -> flunk("CORRUPT meta blob (#{inspect(e)}): #{inspect(blob)}")
        end

      # NO SILENT LOSS: every writer that got :ok must be present.
      acked =
        1..n
        |> Enum.zip(results)
        |> Enum.filter(fn {_i, r} -> r == :ok end)
        |> Enum.map(fn {i, _r} -> "w#{i}" end)

      missing = Enum.reject(acked, &Map.has_key?(parsed, &1))

      assert missing == [],
             "SILENT LOSS: acked but absent: #{inspect(missing)}"

      # Every refusal must be a KNOWN refusal kind — not a crash, not a
      # surprise. This is what turns a stochastic test into a useful one:
      # it pins the SHAPE of failure without pinning its frequency.
      unknown =
        counts
        |> Map.keys()
        |> Enum.reject(&(&1 in [:ok, :write_conflict, :meta_write_roundtrip_failed]))

      assert unknown == [],
             "unexpected refusal kind(s): #{inspect(unknown)} (full tally #{inspect(counts)})"

      # Report the finding this file exists to measure, without asserting
      # a frequency that legitimately varies.
      if Map.has_key?(counts, :meta_write_roundtrip_failed) do
        IO.puts(
          "[CX-g8s9 #{n}-way] ⚠️  #{counts[:meta_write_roundtrip_failed]} writer(s) refused with " <>
            ":meta_write_roundtrip_failed — a CONCURRENCY refusal that merge_meta_cas does NOT retry " <>
            "(it only retries :parent_moved), so it reaches the caller as a hard error."
        )
      end
    end
  end
end
