defmodule CommonplaceWebWeb.ViewRendererGuardTest do
  @moduledoc """
  Tests for the `guard-write` render guard (design doc
  docs/plans/2026-07-16-intra-repo-pull-request-design.md §7.5,
  commonplace-plan repo): an `<action guard-write="UUID">` element
  renders only when the viewing session's principal passes
  `Commonplace.Trust.writer_authorized?/6` for a `:write` at UUID.

  A SEPARATE file from `CommonplaceWebWeb.ViewRendererTest` (which
  runs `async: true` and never touches global trust config) because
  the enforce-mode case here mutates `Application.get_env(:commonplace,
  :trust)` / `:local_write_gate` — global, process-independent state
  that would race other async tests (the CX-c93b flaky-CI class).
  """
  use ExUnit.Case, async: false

  alias CommonplaceWebWeb.ViewRenderer
  alias Commonplace.Crypto.{NodeIdentity, Signing}

  defp render(xml, path, identity) do
    {:safe, iodata} = ViewRenderer.render_view(xml, path, identity)
    IO.iodata_to_binary(iodata)
  end

  describe "render_view/2 (no identity arg) stays back-compat" do
    test "a guard-write action still renders under the permissive default" do
      xml =
        ~s(<view><action name="pr_accept" label="Accept" guard-write="some-target-uuid"/></view>)

      {:safe, iodata} = ViewRenderer.render_view(xml, "")
      html = IO.iodata_to_binary(iodata)
      assert html =~ "Accept"
    end
  end

  describe "render_view/3 guard-write — permissive default" do
    test "renders for an anonymous (nil) viewer under the fully-permissive trust config" do
      xml =
        ~s(<view><action name="pr_accept" label="Accept" guard-write="some-target-uuid"/></view>)

      html = render(xml, "", nil)
      assert html =~ "Accept"
      assert html =~ "phx-value-action=\"pr_accept\""
    end

    test "a plain action with no guard-write attribute is unaffected" do
      xml = ~s(<view><action name="fork" label="Fork"/></view>)
      html = render(xml, "", nil)
      assert html =~ "Fork"
    end
  end

  describe "render_view/3 guard-write — enforce mode" do
    setup do
      dir = Path.join(System.tmp_dir!(), "cp_view_renderer_guard_#{:rand.uniform(1_000_000_000)}")
      File.mkdir_p!(dir)

      old_data_dir = Application.get_env(:commonplace, :data_dir)
      old_trust = Application.get_env(:commonplace, :trust)

      Application.put_env(:commonplace, :data_dir, dir)

      {:ok, node_ctx} = NodeIdentity.signing_context()

      Application.put_env(:commonplace, :trust, %{
        accept_unsigned: false,
        trusted_identities: %{}
      })

      on_exit(fn ->
        case old_data_dir do
          nil -> Application.delete_env(:commonplace, :data_dir)
          v -> Application.put_env(:commonplace, :data_dir, v)
        end

        case old_trust do
          nil -> Application.delete_env(:commonplace, :trust)
          v -> Application.put_env(:commonplace, :trust, v)
        end

        File.rm_rf!(dir)
      end)

      %{node_ctx: node_ctx}
    end

    test "authorized (node-trusted) viewer sees the guard-write action", %{node_ctx: node_ctx} do
      xml =
        ~s(<view><action name="pr_accept" label="Accept" guard-write="any-target-uuid"/></view>)

      html = render(xml, "", {node_ctx.identity_uuid, node_ctx.public_key})
      assert html =~ "Accept"
    end

    test "an unauthorized viewer (no cert, not pinned) does not see the guard-write action" do
      {pub, _priv} = Signing.generate_keypair()

      xml =
        ~s(<view><action name="pr_accept" label="Accept" guard-write="any-target-uuid"/></view>)

      html = render(xml, "", {"some-other-identity", pub})
      refute html =~ "Accept"
    end

    test "an anonymous (nil) viewer does not see the guard-write action" do
      xml =
        ~s(<view><action name="pr_accept" label="Accept" guard-write="any-target-uuid"/></view>)

      html = render(xml, "", nil)
      refute html =~ "Accept"
    end

    test "a plain action with no guard-write attribute still renders for anyone" do
      xml = ~s(<view><action name="fork" label="Fork"/></view>)
      html = render(xml, "", nil)
      assert html =~ "Fork"
    end
  end
end
