defmodule Commonplace.Test.FileRmRfGuard do
  @moduledoc false

  # Test files call File directly, so install one test-only shim rather than
  # relying on hundreds of teardown sites to remember a helper. The original
  # stdlib module is retained under a private name and every function except
  # the two recursive deletions delegates to it unchanged.

  @original_file Commonplace.Test.OriginalFile
  @commit_store Commonplace.Store.CommitStore

  def install! do
    unless Code.ensure_loaded?(@original_file) do
      original_exports = File.module_info(:exports)
      load_original_file!()
      load_guarded_file!(original_exports)
    end

    :ok
  end

  def assert_safe!(path) do
    case Process.whereis(@commit_store) do
      nil ->
        :ok

      _pid ->
        deletion_path = path |> IO.chardata_to_string() |> Path.expand()
        captured_path = captured_dir!()

        # ⚠️ BOTH DIRECTIONS. Refusing only the captured directory and its
        # ANCESTORS leaves the shorter path to the same harm wide open:
        # `File.rm_rf!("<store>/0.cub")` deletes CubDB's actual data file and
        # destroys the store exactly as thoroughly as removing the directory,
        # while sailing through an ancestor-only check.
        if overlapping?(deletion_path, captured_path) do
          raise ExUnit.AssertionError,
            message: """
            File.rm_rf refused to delete the live CommitStore's directory or its contents
            deletion path: #{deletion_path}
            captured path: #{captured_path}
            """
        end
    end
  end

  def captured_dir! do
    # Read the CubDB directory through the live CommitStore handle. The app env
    # is deliberately not consulted: tests are allowed to replace it after boot.
    @commit_store
    |> @commit_store.db_handle()
    |> CubDB.data_dir()
    |> Path.expand()
  end

  # True when either path contains the other, or they are equal:
  #
  #   deleting an ANCESTOR of the store  -> takes the directory with it
  #   deleting the store directory       -> obviously fatal
  #   deleting a CHILD (e.g. `0.cub`)    -> destroys the store's data in place
  #
  # All three are the same defect. Comparing on split path segments rather than
  # string prefixes so that `/tmp/test_data_other` is NOT treated as living
  # inside `/tmp/test_data`.
  defp overlapping?(a, b) do
    ancestor_or_equal?(a, b) or ancestor_or_equal?(b, a)
  end

  defp ancestor_or_equal?(ancestor, descendant) do
    ancestor_parts = Path.split(ancestor)
    descendant_parts = Path.split(descendant)

    Enum.take(descendant_parts, length(ancestor_parts)) == ancestor_parts
  end

  defp load_original_file! do
    {File, file_beam, _filename} = :code.get_object_code(File)

    {:ok, {File, [abstract_code: {:raw_abstract_v1, forms}]}} =
      :beam_lib.chunks(file_beam, [:abstract_code])

    renamed_forms =
      Enum.map(forms, fn
        {:attribute, line, :module, File} ->
          {:attribute, line, :module, @original_file}

        form ->
          form
      end)

    original_beam =
      case :compile.forms(renamed_forms, [:return]) do
        {:ok, @original_file, beam} -> beam
        {:ok, @original_file, beam, _warnings} -> beam
      end

    {:module, @original_file} = :code.load_binary(@original_file, ~c"file.ex", original_beam)
  end

  defp load_guarded_file!(original_exports) do
    delegates =
      original_exports
      |> Enum.reject(fn {name, _arity} ->
        name in [:__info__, :module_info, :rm_rf, :rm_rf!]
      end)
      |> Enum.map(fn {name, arity} ->
        args = Macro.generate_arguments(arity, __MODULE__)

        quote do
          def unquote(name)(unquote_splicing(args)) do
            apply(unquote(@original_file), unquote(name), [unquote_splicing(args)])
          end
        end
      end)

    guarded_file =
      quote do
        defmodule File do
          @moduledoc false

          unquote_splicing(delegates)

          def rm_rf(path) do
            Commonplace.Test.FileRmRfGuard.assert_safe!(path)
            unquote(@original_file).rm_rf(path)
          end

          def rm_rf!(path) do
            Commonplace.Test.FileRmRfGuard.assert_safe!(path)
            unquote(@original_file).rm_rf!(path)
          end
        end
      end

    compiler_options = Code.compiler_options()
    Code.compiler_options(ignore_module_conflict: true)

    try do
      [{File, _guarded_beam}] = Code.compile_quoted(guarded_file, __ENV__.file)
    after
      Code.compiler_options(compiler_options)
    end
  end
end

Commonplace.Test.FileRmRfGuard.install!()
