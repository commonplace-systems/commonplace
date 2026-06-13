defmodule Commonplace.Trust.CodeDocHeuristic do
  @moduledoc """
  Best-effort, defense-in-depth classifier: does this doc UUID *look like*
  executable code or a process declaration? Used by the mint-time guard
  (CX-tdkq.28) to refuse a `:write`-without-`:execute` cert scoped to a code
  doc — closing the laundering INPUT (a peer landing code bytes under `:write`
  that a later node-signed snapshot could absorb into the execute baseline).

  NOT airtight. The content-sniff misses non-`defmodule` code, view-XML /
  compute-spec docs, and remote/future docs not present locally. That is
  acceptable: the airtight backstop is the execute-clean Gate-B walk
  (CX-tdkq.27, `Commonplace.Trust.authorized_to_execute?`). A doc we can't
  reconstruct → `false` (we can't prove it's code; the backstop covers a miss).
  """

  alias Commonplace.Document.ContentType
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.DocBuilder

  @doc "Best-effort: true if the doc at `uuid` content-sniffs as code / process-decl."
  @spec code_doc?(String.t(), GenServer.server()) :: boolean()
  def code_doc?(uuid, store \\ CommitStoreClient) when is_binary(uuid) do
    case safe_reconstruct(store, uuid) do
      {:ok, doc} -> classify(ContentType.get_content(doc))
      _ -> false
    end
  end

  # Reconstruct defensively: a doc not present locally (or no running store)
  # must degrade to "can't classify", never crash the mint path.
  defp safe_reconstruct(store, uuid) do
    DocBuilder.reconstruct_snapshot(store, uuid)
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  defp classify(content) when is_binary(content),
    do: elixir_source?(content) or process_decl_json?(content)

  defp classify(_), do: false

  # An Elixir source doc self-names with `defmodule X` — the SourceDoc.compile
  # vector. Anchor to line-start + a capitalized module head so prose mentioning
  # "defmodule" doesn't trip it.
  defp elixir_source?(content), do: Regex.match?(~r/^\s*defmodule\s+[A-Z]/m, content)

  # A `__processes.json` declaration is a JSON object of named process specs
  # (the Orchestrator's second execute ingress). Best-effort: parses as a
  # non-empty JSON map whose values are themselves maps (process specs).
  defp process_decl_json?(content) do
    case Jason.decode(content) do
      {:ok, map} when is_map(map) and map_size(map) > 0 -> Enum.all?(Map.values(map), &is_map/1)
      _ -> false
    end
  end
end
