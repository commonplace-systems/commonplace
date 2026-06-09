defmodule Commonplace.Dataflow.Channel do
  @moduledoc """
  The color-channel taxonomy — canonical names for Commonplace's
  pub/sub dataflows.

  Commonplace runs several distinct *kinds* of message flow over one
  Phoenix PubSub instance. Rather than scatter ad-hoc topic strings
  across the codebase, each kind is assigned a **color**, and topics
  follow the convention `color:{key}` (the topic builders and
  subscribe/broadcast helpers live in `Commonplace.Dataflow.PubSub`).
  The color names the *semantics* of the flow, so a subscriber knows
  what a message means from its topic alone. This module is the small
  source of truth for *which* colors exist (`colors/0`, `valid?/1`);
  the meaning of each:

    * `:blue` — **CRDT state.** A document's content changed: the write
      path broadcasts on `blue:{uuid}` for every commit. Subscribers
      react to the document itself moving forward (read caches
      invalidate, views recompute). This is the "what the document IS
      now" channel.
    * `:cyan` — **directed writes into blue.** A request *to* a document
      to change, as opposed to `:blue`'s announcement that it *has*
      changed. Cyan is the command edge; blue is the resulting state
      edge.
    * `:red` — **persistent event logs.** Durable, append-only event
      records (topic `red:{uuid}`) — e.g. provenance and audit events
      such as a checkout reroot. Where blue is current state, red is a
      *history of things that happened*.
    * `:magenta` — **ephemeral fire-and-forget.** Transient messages
      with no durability, keyed by **path** (`magenta:{path}`) rather
      than by document uuid, because they address a location/mailbox
      rather than a CRDT. If nothing is listening, the message is simply
      gone.
    * `:green` — **exclusive locks.** Pure control traffic for the lock
      manager (bursar): acquisition and release on `green:{uuid}`. It
      carries coordination, not data.

  Two axes separate the colors: **state vs. command** (blue is the
  state, cyan is the command that produces it) and **durable vs.
  ephemeral** (red persists, magenta does not); green stands apart as
  control-only.

  Note: the `sync:{uuid}` topic used for cross-node commit replication
  is a separate, non-color channel and is intentionally absent from
  `colors/0` — see `Commonplace.Dataflow.PubSub`.
  """

  @type color :: :blue | :cyan | :red | :magenta | :green

  @colors [:blue, :cyan, :red, :magenta, :green]

  def colors, do: @colors

  def valid?(color) when color in @colors, do: true
  def valid?(_), do: false
end
