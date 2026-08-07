defmodule Commonplace.CLI.EscriptNif do
  @moduledoc false

  @archive_entry ~c"commonplace/priv/flock_nif.so"

  @doc "Extract the flock NIF from an escript archive before Flock is loaded."
  @spec prepare() :: :ok
  def prepare do
    case :escript.script_name() do
      script when is_list(script) and script != [] -> prepare_from_archive(script)
      _not_an_escript -> :ok
    end
  end

  defp prepare_from_archive(script) do
    extraction_dir =
      Path.join(
        System.tmp_dir!(),
        "commonplace-escript-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    nif_base = Path.join(extraction_dir, "flock_nif")
    Application.put_env(:commonplace, :flock_nif_path, nif_base)

    with {:ok, sections} <- :escript.extract(script, []),
         {:ok, archive} <- fetch_archive(sections),
         {:ok, files} <- :zip.extract(archive, [:memory]),
         {:ok, nif_binary} <- fetch_nif(files),
         :ok <- File.mkdir_p(extraction_dir),
         :ok <- File.chmod(extraction_dir, 0o700),
         :ok <- File.write(nif_base <> ".so", nif_binary, [:binary]),
         :ok <- File.chmod(nif_base <> ".so", 0o700) do
      System.at_exit(fn _status -> File.rm_rf(extraction_dir) end)
      :ok
    else
      {:error, reason} ->
        # Do not halt here: a command may still route to a live serve and
        # never need the local NIF. If it does need a local CommitStore, its
        # fail-closed gate returns the named :flock_unavailable refusal.
        IO.puts(
          :stderr,
          "commonplace: flock NIF extraction unavailable (#{inspect(reason)}); " <>
            "local store opens will be refused"
        )

        :ok
    end
  end

  defp fetch_archive(sections) do
    case List.keyfind(sections, :archive, 0) do
      {:archive, archive} when is_binary(archive) -> {:ok, archive}
      nil -> {:error, :missing_archive_section}
    end
  end

  defp fetch_nif(files) do
    case List.keyfind(files, @archive_entry, 0) do
      {@archive_entry, binary} when is_binary(binary) -> {:ok, binary}
      nil -> {:error, {:missing_archive_entry, List.to_string(@archive_entry)}}
    end
  end
end
