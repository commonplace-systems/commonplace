defmodule Commonplace.MUD.HelpDoc do
  @moduledoc """
  CX-hbb2 (self-hosting slice A) — the in-world `help` text as a node-signed
  CRDT document, resolved via the `:help` entry of the `:mud_engine_manifest`
  trust root (the same manifest `Commonplace.MUD.EngineModule` resolves
  `:parser`/`:look`/etc through — see that module's moduledoc for why the
  manifest itself must be node/operator-only app-env, never player input).

  UNLIKE `EngineModule`, this is PLAIN TEXT, not code: there is nothing to
  compile, so this module does NOT route through `SourceDoc.compile/3` (which
  would try to `defmodule`-compile the help text and fail). It reuses only
  the Gate-B AUTHORITY WALK `SourceDoc.compile/3` runs before compiling —
  `Commonplace.Trust.authorized_to_execute?/2` — as the SAME content-defacement
  defense: a `help` doc whose latest commit is player-signed is refused, same
  as a player-signed engine doc is refused execution. Editing the doc still
  requires node authority; reading it never risks running anything.

  Non-brick: `text/1` NEVER raises. No manifest entry, an unreadable doc, or a
  Gate-B refusal all fall back to `floor/0` (the compiled-in text, identical
  to the pre-CX-hbb2 `Commonplace.MUD.Verbs.help_text/0`).
  """

  alias Commonplace.Code.SourceDoc
  alias Commonplace.Store.CommitStoreClient

  @floor_text """
  Commands:
    look [target]                    look at the room or a target
    n/s/e/w/u/d  or  go <direction>  move
    say <text>  ('<text>)            speak in the room
    emote <text>                     act out
    take <obj> / drop <obj>          pick up / drop an object
    take/get <obj> from <container>  get something out of a container
    put <obj> in <container>         put something into a container
    look in <container>              see what's inside a container
    give <obj> <player>              give an object to someone here
    mine <vein>                      extract ore from a vein here
    recipes                          list what you can craft + inputs
    smith <recipe>                   craft a recipe from inputs you carry
    i / inventory                    list what you carry
    who                              list players online
    where                            show THIS room's name + uuid (its address)
    home                             return to your own home room
    help                             this help
    quit                             disconnect

  Builders:
    @dig <dir> <name>                carve a new room in <dir> (refuses if
                                     <dir> already has an exit)
    @link <dir> <room-uuid>          point <dir> at an existing room
                                     (repoint/recovery; see @dump for uuids)
    @unlink <dir>                    remove the exit in <dir>
    @teleport <room-uuid> (@go)      jump directly to a room by uuid
    @create object|container|room <name>  create here (a container holds
                                     other objects)
    @container <object>              make an existing object a container
    @desc <target> <text>            set description (target: here, or obj name)
    @name <target> <new name>        rename
    @verb <target>:<verbname>        edit a verb on a room/object (line editor;
                                     finish with '.' on its own line, '@abort'
                                     cancels)
    @unverb <target>:<verbname>      remove a verb from a room/object
    @private                         make the current room read-visible to you only
    @public                          make the current room read-visible to everyone
    @listen                          subscribe to debug events
    @dump [target]                   dump raw struct (a room dump leads with
                                     its own uuid; or use 'where')
  """

  @doc "The compiled-in floor text — non-brick fallback, identical to the pre-CX-hbb2 hardcoded help screen."
  @spec floor() :: String.t()
  def floor, do: @floor_text

  @doc """
  The current `help` text: the node-signed doc if the manifest points at one
  and its latest commit passes Gate B, else the compiled-in `floor/0`. Never
  raises.
  """
  @spec text(GenServer.server()) :: String.t()
  def text(store \\ CommitStoreClient) do
    case manifest_uuid() do
      nil -> floor()
      uuid -> doc_text_or_floor(uuid, store)
    end
  rescue
    _ -> floor()
  catch
    _, _ -> floor()
  end

  defp manifest_uuid do
    :commonplace
    |> Application.get_env(:mud_engine_manifest, %{})
    |> Map.get(:help)
  end

  # Same authority walk `Commonplace.Code.SourceDoc.compile/3` runs before
  # compiling a doc-hosted engine module (Gate B) — the content-defacement
  # defense, applied here to plain text instead of code. A player-signed
  # latest commit is refused, same as a player-signed engine doc's execution
  # would be.
  defp doc_text_or_floor(uuid, store) do
    case Commonplace.Trust.authorized_to_execute?(store, uuid) do
      :ok ->
        case SourceDoc.read(uuid, store) do
          {:ok, content, _hash} -> content
          {:error, _} -> floor()
        end

      {:error, _} ->
        floor()
    end
  end
end
