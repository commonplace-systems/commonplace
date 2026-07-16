defmodule Commonplace.MUD.WorldMeta do
  @moduledoc """
  CX-lr73 (self-hosting slice 2, part C) — the MUD world's own TITLE
  (previously hardcoded as the `<h1>The Emberlight Vault</h1>` literal
  in `CommonplaceWebWeb.MudLive`'s template) as a node-signed CRDT
  document, resolved via the `:world_meta` entry of the
  `:mud_engine_manifest` trust root — the SAME manifest
  `Commonplace.MUD.HelpDoc`/`Commonplace.MUD.HomeTemplate` resolve their
  own entries through.

  Same shape as `HelpDoc`: PLAIN TEXT (a JSON body), never compiled;
  `title/1` applies the SAME Gate-B authority walk
  (`Commonplace.Trust.authorized_to_execute?/2`) as a content-defacement
  defense, and NEVER raises — no manifest entry, an unreadable/
  unparseable doc, or a Gate-B refusal all fall back to `floor/0` (the
  compiled-in title, identical to the pre-CX-lr73 hardcoded string).
  """

  alias Commonplace.Code.SourceDoc
  alias Commonplace.Store.CommitStoreClient

  @floor_title "The Emberlight Vault"

  @doc "The compiled-in floor title — non-brick fallback, identical to the pre-CX-lr73 hardcoded `<h1>`."
  @spec floor() :: String.t()
  def floor, do: @floor_title

  @doc "The compiled-in floor title, as the JSON text seeded into the doc at bootstrap."
  @spec floor_json() :: String.t()
  def floor_json, do: Jason.encode!(%{"title" => @floor_title})

  @doc """
  The current world title: the node-signed doc's `"title"` if the
  manifest points at one and its latest commit passes Gate B, else the
  compiled-in `floor/0`. Never raises.
  """
  @spec title(GenServer.server()) :: String.t()
  def title(store \\ CommitStoreClient) do
    case manifest_uuid() do
      nil -> floor()
      uuid -> doc_title_or_floor(uuid, store)
    end
  rescue
    _ -> floor()
  catch
    _, _ -> floor()
  end

  defp manifest_uuid do
    :commonplace
    |> Application.get_env(:mud_engine_manifest, %{})
    |> Map.get(:world_meta)
  end

  defp doc_title_or_floor(uuid, store) do
    case Commonplace.Trust.authorized_to_execute?(store, uuid) do
      :ok ->
        case SourceDoc.read(uuid, store) do
          {:ok, content, _hash} -> decode_title(content)
          {:error, _} -> floor()
        end

      {:error, _} ->
        floor()
    end
  end

  defp decode_title(json) do
    case Jason.decode(json) do
      {:ok, %{"title" => title}} when is_binary(title) -> title
      _ -> floor()
    end
  end
end
