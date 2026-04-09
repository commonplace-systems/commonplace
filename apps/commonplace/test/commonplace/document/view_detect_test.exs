defmodule Commonplace.Document.ViewDetectTest do
  use ExUnit.Case, async: true

  alias Commonplace.Document.ViewDetect

  describe "is_view?/1" do
    test "returns true for a minimal view document" do
      assert ViewDetect.is_view?("<view></view>")
    end

    test "returns true for a view with attributes" do
      assert ViewDetect.is_view?(~s(<view schema="1"><body/></view>))
    end

    test "returns true for a self-closing view" do
      assert ViewDetect.is_view?("<view/>")
    end

    test "returns true with leading whitespace" do
      assert ViewDetect.is_view?("\n\n  <view></view>")
    end

    test "returns true after an XML declaration" do
      assert ViewDetect.is_view?(~s(<?xml version="1.0"?>\n<view/>))
    end

    test "returns false for markdown content" do
      refute ViewDetect.is_view?("# Hello\n\nSome text")
    end

    test "returns false for html that isn't a view" do
      refute ViewDetect.is_view?("<html><body>hi</body></html>")
    end

    test "returns false for elements whose name starts with 'view' but isn't 'view'" do
      refute ViewDetect.is_view?("<viewer/>")
      refute ViewDetect.is_view?("<viewport>")
    end

    test "returns false for empty string" do
      refute ViewDetect.is_view?("")
    end

    test "returns false for nil and non-binaries" do
      refute ViewDetect.is_view?(nil)
      refute ViewDetect.is_view?(123)
      refute ViewDetect.is_view?([])
      refute ViewDetect.is_view?(%{})
    end

    test "returns false for a plain text doc that happens to mention <view>" do
      refute ViewDetect.is_view?("This doc mentions <view> but isn't one")
    end
  end
end
