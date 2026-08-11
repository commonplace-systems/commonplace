defmodule Commonplace.Sync.BinaryClassifier do
  @moduledoc """
  Classifies imports from facts only.

  A declared extension is binary regardless of content. Otherwise invalid
  UTF-8 is measured incrementally and routes binary; valid UTF-8 with an
  undeclared extension is text. There is no content sniffing in either
  direction.
  """

  @declared_extensions ~w(
    png jpg jpeg gif bmp ico webp tiff tif
    mp3 wav flac aac ogg m4a wma
    mp4 avi mkv mov wmv flv webm
    zip tar gz bz2 xz 7z rar
    pdf doc docx xls xlsx ppt pptx odt ods odp
    dll so dylib app
    wasm class pyc pyo o a lib
    ttf otf woff woff2 eot
    db sqlite sqlite3 cub
  )

  @chunk_size 64 * 1024

  @spec declared_extensions() :: [String.t()]
  def declared_extensions, do: @declared_extensions

  @spec classify(String.t(), keyword()) ::
          :text | {:binary, :invalid_utf8 | :declared_extension} | {:error, term()}
  def classify(path, opts \\ []) when is_binary(path) do
    extensions = Keyword.get(opts, :binary_extensions, @declared_extensions)

    if declared?(path, extensions) do
      {:binary, :declared_extension}
    else
      classify_utf8(path)
    end
  end

  defp declared?(path, extensions) do
    extension = path |> Path.extname() |> String.trim_leading(".") |> String.downcase()
    extension != "" and extension in extensions
  end

  defp classify_utf8(path) do
    case File.open(path, [:read, :binary]) do
      {:ok, io} ->
        try do
          validate_chunks(io, <<>>)
        after
          File.close(io)
        end

      {:error, reason} ->
        {:error, {:read_failed, reason}}
    end
  end

  defp validate_chunks(io, carry) do
    case IO.binread(io, @chunk_size) do
      :eof -> if carry == <<>>, do: :text, else: {:binary, :invalid_utf8}
      {:error, reason} -> {:error, {:read_failed, reason}}
      chunk -> validate_chunk(io, carry <> chunk)
    end
  end

  defp validate_chunk(io, bytes) do
    case :unicode.characters_to_binary(bytes, :utf8, :utf8) do
      valid when is_binary(valid) -> validate_chunks(io, <<>>)
      {:incomplete, _valid, rest} -> validate_chunks(io, rest)
      {:error, _valid, _rest} -> {:binary, :invalid_utf8}
    end
  end
end
