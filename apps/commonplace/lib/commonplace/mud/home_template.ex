defmodule Commonplace.MUD.HomeTemplate do
  @moduledoc """
  CX-gkqk (self-hosting slice 2, part B) — the citizenship starter-home
  room's name + prose as a node-signed CRDT document, resolved via the
  `:home_template` entry of the `:mud_engine_manifest` trust root (the
  SAME manifest `Commonplace.MUD.HelpDoc`/`Commonplace.MUD.EngineModule`
  resolve other entries through).

  Like `HelpDoc`, this is PLAIN TEXT (a JSON body), not a `defmodule` —
  `render/3` never compiles anything, it applies the SAME Gate-B
  authority walk (`Commonplace.Trust.authorized_to_execute?/2`) as a
  content-defacement defense before trusting the doc's JSON: a template
  whose latest commit is player-signed is refused, same as a
  player-signed engine doc is refused execution. `render/3` NEVER
  raises — no manifest entry, an unreadable/unparseable doc, or a Gate-B
  refusal all fall back to the compiled-in floor strings (identical to
  the pre-CX-gkqk hardcoded `Citizenship.home_room_json/3` prose).

  ## Hard boundary — prose-only, never security fields

  The template can only ever restyle a home's NAME and DESCRIPTION. It
  is used by `Commonplace.MUD.Citizenship.home_room_json/3` to fill in
  those two strings; `home_room_json/3` keeps building the room's
  security fields itself — `owner`, `visibility: :capability_gated`,
  the `"out"` exit target — from its own arguments, exactly as before.
  `render/3`'s return shape (`%{name: _, description: _}`) has no room
  for those fields to leak into, by construction: a doc-hosted template
  can reskin a home's flavor text; it can NEVER flip who owns a home,
  its visibility, or its exits.
  """

  alias Commonplace.Code.SourceDoc
  alias Commonplace.Store.CommitStoreClient

  @floor_name "{name}'s Home"
  @floor_description "A quiet room that is yours to shape — this is your own corner of the world.{exit_note}"
  @floor_exit_note " An exit leads <out> to the rest of the demesne."

  @doc "The compiled-in floor template — non-brick fallback, identical to the pre-CX-gkqk hardcoded strings."
  @spec floor() :: %{name: String.t(), description: String.t(), exit_note: String.t()}
  def floor do
    %{name: @floor_name, description: @floor_description, exit_note: @floor_exit_note}
  end

  @doc "The compiled-in floor template, as the JSON text seeded into the doc at bootstrap."
  @spec floor_json() :: String.t()
  def floor_json do
    Jason.encode!(%{
      "name" => @floor_name,
      "description" => @floor_description,
      "exit_note" => @floor_exit_note
    })
  end

  @doc """
  Render the starter-home name/description for a citizen named `name`.
  `has_exit?` controls whether the exit-note fragment is appended to the
  description (mirrors the pre-CX-gkqk `is_binary(start_room_uuid)`
  conditional in `Citizenship.home_room_json/3`). Never raises — falls
  back to `floor/0`'s strings on any failure.
  """
  @spec render(String.t(), boolean(), GenServer.server()) :: %{
          name: String.t(),
          description: String.t()
        }
  def render(name, has_exit?, store \\ CommitStoreClient)
      when is_binary(name) and is_boolean(has_exit?) do
    template =
      case manifest_uuid() do
        nil -> floor()
        uuid -> doc_template_or_floor(uuid, store)
      end

    apply_template(template, name, has_exit?)
  rescue
    _ -> apply_template(floor(), name, has_exit?)
  catch
    _, _ -> apply_template(floor(), name, has_exit?)
  end

  defp manifest_uuid do
    :commonplace
    |> Application.get_env(:mud_engine_manifest, %{})
    |> Map.get(:home_template)
  end

  # Same authority walk `HelpDoc.text/1` runs — the content-defacement
  # defense, applied here to a JSON template instead of plain help text.
  defp doc_template_or_floor(uuid, store) do
    case Commonplace.Trust.authorized_to_execute?(store, uuid) do
      :ok ->
        case SourceDoc.read(uuid, store) do
          {:ok, content, _hash} -> decode_template(content)
          {:error, _} -> floor()
        end

      {:error, _} ->
        floor()
    end
  end

  defp decode_template(json) do
    case Jason.decode(json) do
      {:ok, m} ->
        %{
          name: Map.get(m, "name", @floor_name),
          description: Map.get(m, "description", @floor_description),
          exit_note: Map.get(m, "exit_note", @floor_exit_note)
        }

      {:error, _} ->
        floor()
    end
  end

  defp apply_template(template, name, has_exit?) do
    exit_note = if has_exit?, do: Map.get(template, :exit_note, @floor_exit_note), else: ""

    %{
      name: String.replace(Map.get(template, :name, @floor_name), "{name}", name),
      description:
        template
        |> Map.get(:description, @floor_description)
        |> String.replace("{name}", name)
        |> String.replace("{exit_note}", exit_note)
    }
  end
end
