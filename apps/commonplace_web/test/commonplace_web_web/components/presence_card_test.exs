defmodule CommonplaceWebWeb.PresenceCardTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias CommonplaceWebWeb.PresenceCard

  defp render_card(assigns_map) do
    assigns = Map.put(assigns_map, :__changed__, nil)
    rendered_to_string(PresenceCard.presence_card(assigns))
  end

  describe "presence_card/1" do
    test "renders name, honorific badge, status, and live liveness pill" do
      now = ~U[2026-04-16 12:00:00Z]

      html =
        render_card(%{
          presence: %{
            "name" => "bartleby",
            "type" => "bot",
            "status" => "running",
            "started_at" => "2026-04-16T11:55:00Z",
            "heartbeat" => "2026-04-16T11:59:55Z"
          },
          name: "bartleby",
          honorific: :bot,
          identity: nil,
          now: now
        })

      assert html =~ "bartleby"
      assert html =~ "honorific-bot"
      assert html =~ ".bot"
      assert html =~ "running"
      assert html =~ "liveness-green"
      assert html =~ "live"
      # uptime humanized as "5m"
      assert html =~ "5m"
    end

    test "yellow liveness in idle window" do
      now = ~U[2026-04-16 12:00:00Z]

      html =
        render_card(%{
          presence: %{
            "name" => "idler",
            "heartbeat" => "2026-04-16T11:59:00Z"
          },
          name: "idler",
          honorific: :exe,
          identity: nil,
          now: now
        })

      assert html =~ "liveness-yellow"
      assert html =~ "idle"
    end

    test "red liveness for stale heartbeat" do
      now = ~U[2026-04-16 12:00:00Z]

      html =
        render_card(%{
          presence: %{
            "name" => "ghost",
            "heartbeat" => "2026-04-16T11:30:00Z"
          },
          name: "ghost",
          honorific: :who,
          identity: nil,
          now: now
        })

      assert html =~ "liveness-red"
      assert html =~ "stale"
    end

    test "graceful empty state when no activity, identity, or owner present" do
      now = ~U[2026-04-16 12:00:00Z]

      html =
        render_card(%{
          presence: %{
            "name" => "blank",
            "type" => "usr",
            "heartbeat" => "2026-04-16T11:59:55Z"
          },
          name: "blank",
          honorific: :usr,
          identity: nil,
          now: now
        })

      assert html =~ "no activity reported"
      assert html =~ "no cold identity record"
    end

    test "shows activity, owner, cwd, and capabilities when populated" do
      now = ~U[2026-04-16 12:00:00Z]

      html =
        render_card(%{
          presence: %{
            "name" => "doer",
            "type" => "bot",
            "heartbeat" => "2026-04-16T11:59:55Z",
            "activity" => "writing presence card",
            "owner" => "jes",
            "cwd" => "/srv/commonplace",
            "capabilities" => ~s(["fs","irc"])
          },
          name: "doer",
          honorific: :bot,
          identity: %{
            "first_seen" => "2026-04-01T00:00:00Z",
            "last_seen" => "2026-04-16T11:00:00Z"
          },
          now: now
        })

      assert html =~ "writing presence card"
      assert html =~ "jes"
      assert html =~ "/srv/commonplace"
      assert html =~ "fs"
      assert html =~ "irc"
      assert html =~ "first seen"
      assert html =~ "2026-04-01"
    end

    test "no heartbeat field renders red liveness without crashing" do
      html =
        render_card(%{
          presence: %{"name" => "no-hb"},
          name: "no-hb",
          honorific: :exe,
          identity: nil,
          now: ~U[2026-04-16 12:00:00Z]
        })

      assert html =~ "liveness-red"
      assert html =~ "no heartbeat"
    end
  end
end
