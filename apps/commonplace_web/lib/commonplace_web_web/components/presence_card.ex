defmodule CommonplaceWebWeb.PresenceCard do
  @moduledoc """
  Function component for rendering a presence document (.bot/.usr/.exe/.who).

  Takes the loaded presence YMap (already converted to a plain Elixir map) plus
  optional identity info and renders:

    * Header strip — name + honorific badge, liveness pill (green/yellow/red),
      status text, uptime since `started_at`.
    * Identity panel (right column) — first_seen / last_seen from the cold
      identity record, plus owner / cwd / capabilities if present in the
      presence YMap.
    * Activity panel (middle) — current `activity` field, with empty-state.
    * Recent commits (bottom) — placeholder until per-signer commit feed
      lands (CX-4ba follow-up).

  Liveness uses the presence record's owner-signed TTL (or the declared class
  default for a legacy-absent record), matching `Commonplace.Presence.Reaper`:

    * younger than the entry TTL -> green ("live")
    * entry TTL..5m -> yellow ("idle")
    * `> 5m` -> red ("stale")

  Inputs that may be `nil` or absent are tolerated — the component renders
  graceful empty states instead of raising.
  """
  use Phoenix.Component

  import CommonplaceWebWeb.CoreComponents, only: [icon: 1]

  @idle_threshold_ms 5 * 60_000

  @doc """
  Render a presence card.

  ## Assigns

    * `:presence` — the YMap content as a plain Elixir map. Keys it looks at:
      `"name"`, `"type"`, `"status"`, `"started_at"`, `"heartbeat"`,
      `"activity"`, `"owner"`, `"cwd"`, `"capabilities"`.
    * `:name` — display name (fallback to `presence["name"]`).
    * `:honorific` — atom or string (`:bot`/`:usr`/`:exe`/`:who`).
    * `:identity` — optional cold identity map (keys: `"first_seen"`,
      `"last_seen"`, `"public_keys"`); may be `nil` if no identity record
      could be resolved.
    * `:now` — DateTime used to compute liveness/uptime. Defaults to
      `DateTime.utc_now/0`. Allows deterministic tests.
  """
  attr :presence, :map, required: true
  attr :name, :string, default: nil
  attr :honorific, :any, default: nil
  attr :identity, :map, default: nil
  attr :now, :any, default: nil

  def presence_card(assigns) do
    presence = assigns.presence || %{}
    now = assigns.now || DateTime.utc_now()
    name = assigns.name || presence["name"] || "(unknown)"
    honorific = honorific_string(assigns.honorific || presence["type"])
    heartbeat_dt = parse_iso8601(presence["heartbeat"])
    started_dt = parse_iso8601(presence["started_at"])

    live_threshold_ms =
      case Commonplace.Presence.lease_terms(presence) do
        {:ok, terms} -> terms.ttl_ms
        {:error, _reason} -> 0
      end

    {liveness, liveness_label, heartbeat_age} = liveness(heartbeat_dt, now, live_threshold_ms)
    uptime = humanize_age(started_dt, now)

    assigns =
      assigns
      |> assign(:presence, presence)
      |> assign(:now, now)
      |> assign(:name, name)
      |> assign(:honorific, honorific)
      |> assign(:liveness, liveness)
      |> assign(:liveness_label, liveness_label)
      |> assign(:heartbeat_age, heartbeat_age)
      |> assign(:uptime, uptime)
      |> assign(:status_text, presence["status"])
      |> assign(:activity, presence["activity"])
      |> assign(:owner, presence["owner"])
      |> assign(:cwd, presence["cwd"])
      |> assign(:capabilities, normalize_capabilities(presence["capabilities"]))
      |> assign(:identity, assigns.identity)

    ~H"""
    <div class="cp-presence-card space-y-4" data-testid="presence-card">
      <!-- Header strip -->
      <header class="flex flex-wrap items-center gap-3 border-b border-base-300 pb-3">
        <h2 class="text-2xl font-bold cp-presence-name">{@name}</h2>
        <span class={"badge badge-outline cp-presence-honorific honorific-" <> @honorific}>
          .{@honorific}
        </span>
        <span class={"badge gap-1 cp-presence-liveness liveness-" <> Atom.to_string(@liveness)}>
          <span class={"size-2 rounded-full " <> liveness_dot_class(@liveness)}></span>
          {@liveness_label}
        </span>
        <%= if @status_text do %>
          <span class="text-sm text-base-content/70 cp-presence-status">
            status: <span class="font-medium">{@status_text}</span>
          </span>
        <% end %>
        <%= if @uptime do %>
          <span class="text-sm text-base-content/60 cp-presence-uptime">uptime {@uptime}</span>
        <% end %>
        <%= if @heartbeat_age do %>
          <span class="text-xs text-base-content/50 ml-auto cp-presence-heartbeat">
            heartbeat {@heartbeat_age} ago
          </span>
        <% end %>
      </header>

      <div class="grid grid-cols-1 md:grid-cols-3 gap-4">
        <!-- Activity panel -->
        <section class="md:col-span-2 cp-presence-activity">
          <h3 class="text-xs font-semibold uppercase tracking-wide text-base-content/50 mb-2">
            Current activity
          </h3>
          <%= if @activity && @activity != "" do %>
            <p class="text-base">{@activity}</p>
          <% else %>
            <p class="text-base-content/40 italic">no activity reported</p>
          <% end %>
        </section>
        
    <!-- Identity panel -->
        <aside class="cp-presence-identity bg-base-200/40 rounded-lg p-3 space-y-2 text-sm">
          <h3 class="text-xs font-semibold uppercase tracking-wide text-base-content/50">
            Identity
          </h3>
          <%= if @identity do %>
            <%= if @identity["first_seen"] do %>
              <div>
                <span class="text-base-content/50">first seen:</span>
                <span class="font-mono text-xs">{@identity["first_seen"]}</span>
              </div>
            <% end %>
            <%= if @identity["last_seen"] do %>
              <div>
                <span class="text-base-content/50">last seen:</span>
                <span class="font-mono text-xs">{@identity["last_seen"]}</span>
              </div>
            <% end %>
            <%= if @identity["public_keys"] do %>
              <div class="cp-presence-pubkeys">
                <span class="text-base-content/50">public keys:</span>
                <span class="font-mono text-xs">{summarize_keys(@identity["public_keys"])}</span>
              </div>
            <% end %>
          <% else %>
            <p class="text-base-content/40 italic">no cold identity record</p>
          <% end %>

          <%= if @owner do %>
            <div>
              <span class="text-base-content/50">owner:</span> {@owner}
            </div>
          <% end %>
          <%= if @cwd do %>
            <div class="cp-presence-cwd">
              <span class="text-base-content/50">cwd:</span>
              <span class="font-mono text-xs break-all">{@cwd}</span>
            </div>
          <% end %>
          <%= if @capabilities != [] do %>
            <div class="cp-presence-capabilities">
              <span class="text-base-content/50">capabilities:</span>
              <div class="flex flex-wrap gap-1 mt-1">
                <%= for cap <- @capabilities do %>
                  <span class="badge badge-sm badge-ghost">{cap}</span>
                <% end %>
              </div>
            </div>
          <% end %>
        </aside>
      </div>
      
    <!-- Recent commits placeholder -->
      <section class="cp-presence-commits border-t border-base-300 pt-3">
        <h3 class="text-xs font-semibold uppercase tracking-wide text-base-content/50 mb-2">
          <.icon name="hero-clock-micro" class="size-3 inline" /> Recent commits by this actor
        </h3>
        <p class="text-base-content/40 italic text-sm">
          (coming soon)
        </p>
      </section>
    </div>
    """
  end

  # --- Helpers ---

  defp honorific_string(t) when is_atom(t) and not is_nil(t), do: Atom.to_string(t)
  defp honorific_string(t) when is_binary(t) and t != "", do: t
  defp honorific_string(_), do: "who"

  defp liveness_dot_class(:green), do: "bg-success"
  defp liveness_dot_class(:yellow), do: "bg-warning"
  defp liveness_dot_class(:red), do: "bg-error"
  defp liveness_dot_class(_), do: "bg-base-300"

  defp liveness(nil, _now, _live_threshold_ms), do: {:red, "no heartbeat", nil}

  defp liveness(%DateTime{} = hb, %DateTime{} = now, live_threshold_ms) do
    age_ms = DateTime.diff(now, hb, :millisecond)
    label = humanize_ms(age_ms)

    cond do
      age_ms < live_threshold_ms -> {:green, "live", label}
      age_ms < @idle_threshold_ms -> {:yellow, "idle", label}
      true -> {:red, "stale", label}
    end
  end

  defp humanize_age(nil, _), do: nil

  defp humanize_age(%DateTime{} = then, %DateTime{} = now) do
    diff_s = DateTime.diff(now, then, :second)
    if diff_s < 0, do: nil, else: humanize_seconds(diff_s)
  end

  defp humanize_ms(ms) when ms < 1_000, do: "#{ms}ms"
  defp humanize_ms(ms), do: humanize_seconds(div(ms, 1_000))

  defp humanize_seconds(s) when s < 60, do: "#{s}s"

  defp humanize_seconds(s) when s < 3_600 do
    minutes = div(s, 60)
    seconds = rem(s, 60)
    if seconds == 0, do: "#{minutes}m", else: "#{minutes}m #{seconds}s"
  end

  defp humanize_seconds(s) when s < 86_400 do
    hours = div(s, 3_600)
    minutes = div(rem(s, 3_600), 60)
    if minutes == 0, do: "#{hours}h", else: "#{hours}h #{minutes}m"
  end

  defp humanize_seconds(s) do
    days = div(s, 86_400)
    hours = div(rem(s, 86_400), 3_600)
    if hours == 0, do: "#{days}d", else: "#{days}d #{hours}h"
  end

  defp parse_iso8601(nil), do: nil

  defp parse_iso8601(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_iso8601(_), do: nil

  defp normalize_capabilities(nil), do: []
  defp normalize_capabilities(list) when is_list(list), do: Enum.map(list, &to_string/1)

  defp normalize_capabilities(s) when is_binary(s) do
    case Jason.decode(s) do
      {:ok, list} when is_list(list) -> Enum.map(list, &to_string/1)
      _ -> [s]
    end
  end

  defp normalize_capabilities(_), do: []

  defp summarize_keys(keys) when is_binary(keys) do
    case Jason.decode(keys) do
      {:ok, list} when is_list(list) -> summarize_keys(list)
      _ -> truncate_key(keys)
    end
  end

  defp summarize_keys([]), do: "(none)"

  defp summarize_keys(list) when is_list(list) do
    list
    |> Enum.map(&truncate_key/1)
    |> Enum.join(", ")
  end

  defp summarize_keys(_), do: "(unknown)"

  defp truncate_key(k) when is_binary(k) do
    if byte_size(k) > 16,
      do: binary_part(k, 0, 8) <> "…" <> binary_part(k, byte_size(k) - 4, 4),
      else: k
  end

  defp truncate_key(k), do: inspect(k)
end
