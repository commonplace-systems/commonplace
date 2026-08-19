defmodule Commonplace.Chat.ChatViewBuilder do
  @moduledoc """
  CX-7kl3 (sub-bead ii of CX-04d8 M3): chat-tier view-XML emitter.

  Takes materialized chat entries (the output of
  `Commonplace.Materialize.materialize/2` run on `_messages` with
  M2's chain rules) + a room name and returns a view-XML string
  matching the M3 spec §3 "held shape":

      <view schema="1">
        <entity kind="chat_room" name="{room}" id="{room}">
          <body>
            <list id="messages">
              <entity kind="message" id="msg-uuid">
                <provenance signer="..." ts="..."/>
                <field name="author_path" value="..."/>
                <field name="reply_to" value="..."/>   (when present)
                <field name="edited" value="true|false"/>
                <field name="edited_at" value="..."/>  (when edited)
                <field name="deleted" value="true|false"/>
                <body>
                  <text format="plain">message text or [deleted]</text>
                </body>
              </entity>
              ...
            </list>
          </body>
        </entity>

        <action name="post_message" label="Send" args="text:string">
          <arg name="messages_uuid" from="../_messages"/>
          ...
        </action>
        ...
      </view>

  Chat-tier, NOT a substrate primitive. Future view kinds get their own
  builders. M4's template-instantiation keystone may lift this to a
  generic "render materialized list as view-XML using template T"
  primitive; M3 keeps it chat-specific.

  ## Decisions baked in

  * `kind="chat_room"` (underscore) per M3 spec.
  * `[deleted]` placeholder is hard-coded English per refinement #4
    (locale support deferred post-arc).
  * `<provenance commit="..."/>` deferred per refinement #5 — emit
    `<provenance signer ts/>` only; commit attr is a followup.
  * `<field>` for scalar metadata, `<body><text>` for the message body
    content. views.md attribute→entity escalation defaults.
  * Message `<entity>` children appear in input order (the materialize
    primitive returns entries in array-position order).
  """

  @doc """
  Build the chat-room view-XML string. `messages` is the list of
  materialized entries (per M2 substrate). `room_name` is the
  human-readable room identifier — used as the `<entity name>` and
  the schema `id` on the chat_room entity.
  """
  def build_view_xml(messages, room_name)
      when is_list(messages) and is_binary(room_name) do
    """
    <view schema="1">
      <entity kind="chat_room" name="#{escape_attr(room_name)}" id="#{escape_attr(room_name)}">
        <body>
          <list id="messages">
            #{Enum.map_join(messages, "\n          ", &render_message/1)}
          </list>
        </body>
      </entity>

      #{render_actions()}
    </view>
    """
  end

  # --- Per-message rendering ---

  defp render_message(%{} = msg) do
    id = Map.fetch!(msg, "id")
    deleted? = Map.get(msg, "deleted?", false)

    body_text = if deleted?, do: "[deleted]", else: Map.get(msg, "text", "")

    """
    <entity kind="message" id="#{escape_attr(id)}">
              #{render_provenance(msg)}
              #{render_fields(msg)}
              <body>
                <text format="plain">#{escape_text(body_text)}</text>
              </body>
            </entity>\
    """
  end

  defp render_provenance(msg) do
    signer = Map.get(msg, "author_signer_id")
    ts = Map.get(msg, "ts")

    attrs = [
      if(signer, do: ~s( signer="#{escape_attr(signer)}"), else: ""),
      if(ts, do: ~s( ts="#{escape_attr(ts)}"), else: "")
    ]

    "<provenance" <> Enum.join(attrs) <> "/>"
  end

  defp render_fields(msg) do
    fields = [
      maybe_field("author_path", Map.get(msg, "author_path")),
      maybe_field("reply_to", Map.get(msg, "reply_to")),
      field("edited", to_string(Map.get(msg, "edited?", false))),
      maybe_field("edited_at", Map.get(msg, "edited_at")),
      field("deleted", to_string(Map.get(msg, "deleted?", false)))
    ]

    fields
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n              ")
  end

  defp field(name, value),
    do: ~s(<field name="#{escape_attr(name)}" value="#{escape_attr(value)}"/>)

  defp maybe_field(_name, nil), do: ""
  defp maybe_field(_name, ""), do: ""
  defp maybe_field(name, value), do: field(name, value)

  # --- Action declarations (static per room) ---

  defp render_actions do
    """
    <action name="post_message" label="Send" args="text:string">
        <arg name="messages_uuid" from="../_messages"/>
        <arg name="messages_log_uuid" from="../_messages.log"/>
        <arg name="room" from=".."/>
        <arg name="author_path" from="$session.presence_path"/>
      </action>

      <action name="edit_message" label="Edit" args="message_id:string,text:string">
        <arg name="messages_uuid" from="../_messages"/>
        <arg name="messages_log_uuid" from="../_messages.log"/>
        <arg name="room" from=".."/>
        <arg name="author_path" from="$session.presence_path"/>
      </action>

      <action name="delete_message" label="Delete" args="message_id:string">
        <arg name="messages_uuid" from="../_messages"/>
        <arg name="messages_log_uuid" from="../_messages.log"/>
        <arg name="room" from=".."/>
        <arg name="author_path" from="$session.presence_path"/>
      </action>\
    """
  end

  # --- Escaping ---

  defp escape_attr(value) when is_binary(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end

  defp escape_attr(value), do: value |> to_string() |> escape_attr()

  defp escape_text(value) when is_binary(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp escape_text(value), do: value |> to_string() |> escape_text()
end
