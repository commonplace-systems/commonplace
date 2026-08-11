defmodule Commonplace.CLI.CertMintTest do
  use ExUnit.Case, async: true

  alias Commonplace.CLI.CertMint

  test "verb omission refuses and names --verbs" do
    assert {:error, text} =
             CertMint.parse_argv(["--scope", "notes.txt", "--audience", UUID.uuid4()])

    assert text ==
             "cert-mint refused: --verbs is required (closed by default; no verbs are implied)"
  end

  test "dictated grammar parses without inventing defaults" do
    audience = UUID.uuid4()

    assert {:ok,
            %{
              scope: ":doc-uuid",
              verbs: [:execute, :write],
              audience: ^audience,
              expiry: ~U[2030-01-02 03:04:05Z]
            }} =
             CertMint.parse_argv([
               "--scope",
               ":doc-uuid",
               "--verbs",
               "write,execute",
               "--audience",
               audience,
               "--expiry",
               "2030-01-02T03:04:05Z"
             ])
  end

  test "serve transport is exercised at its injected HTTP seam" do
    audience = UUID.uuid4()
    parent = self()

    post = fn url, body ->
      send(parent, {:posted, url, body})
      {:ok, %{status: 201, body: %{"cid" => String.duplicate("ab", 32)}}}
    end

    assert {:ok, cid} =
             CertMint.request(
               "/fixture/.commonplace",
               "subdir",
               ["--scope", "notes.txt", "--verbs", "write", "--audience", audience],
               post: post,
               endpoint: "http://127.0.0.1:4000/cert-mint"
             )

    assert cid == String.duplicate("ab", 32)

    assert_receive {:posted, "http://127.0.0.1:4000/cert-mint",
                    %{
                      "scope" => "subdir/notes.txt",
                      "verbs" => ["write"],
                      "audience" => ^audience,
                      "expiry" => nil
                    }}
  end
end
