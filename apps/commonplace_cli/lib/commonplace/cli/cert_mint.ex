defmodule Commonplace.CLI.CertMint do
  @moduledoc """
  One-shot HTTP client for:

      commonplace cert-mint --scope REF --verbs LIST --audience PRINCIPAL [--expiry E]

  Key material is never loaded by this module. The local serve resolves the
  audience key and executes the mint under the node signing authority.
  """

  import Commonplace.CLI.Helpers, only: [join_paths: 2]

  # The serve's HTTP port comes from the same PORT env the serve itself
  # reads (config/runtime.exs — the live serve exports PORT=5199, default
  # 4000). COMMONPLACE_SERVE_URL overrides the whole base URL.
  defp default_endpoint do
    base =
      System.get_env("COMMONPLACE_SERVE_URL") ||
        "http://127.0.0.1:#{System.get_env("PORT", "4000")}"

    base <> "/api/cert-mint"
  end

  @verb_omission "cert-mint refused: --verbs is required (closed by default; no verbs are implied)"
  @verbs %{
    "write" => :write,
    "execute" => :execute,
    "delegate" => :delegate,
    "read" => :read,
    "bless" => :bless,
    "define_verb" => :define_verb
  }

  def run(data_dir, relative_path, args) do
    case request(data_dir, relative_path, args) do
      {:ok, cid} ->
        IO.puts(cid)

      {:error, message} ->
        IO.puts(:stderr, message)
        System.halt(1)
    end
  end

  @doc false
  def request(_data_dir, relative_path, args, opts \\ []) do
    with {:ok, parsed} <- parse_argv(args),
         body <- request_body(parsed, relative_path),
         {:ok, response} <-
           post(Keyword.get_lazy(opts, :endpoint, &default_endpoint/0), body, opts) do
      decode_response(response)
    end
  end

  @doc false
  def parse_argv(argv) do
    {opts, positional, invalid} =
      OptionParser.parse(argv,
        strict: [scope: :string, verbs: :string, audience: :string, expiry: :string]
      )

    cond do
      invalid != [] or positional != [] ->
        {:error, usage_refusal()}

      is_nil(opts[:verbs]) ->
        {:error, @verb_omission}

      is_nil(opts[:scope]) ->
        {:error, "cert-mint refused: --scope is required"}

      is_nil(opts[:audience]) ->
        {:error, "cert-mint refused: --audience is required"}

      not uuid?(opts[:audience]) ->
        {:error, "cert-mint refused: --audience must be a principal identity UUID"}

      true ->
        with {:ok, verbs} <- parse_verbs(opts[:verbs]),
             {:ok, expiry} <- parse_expiry(opts[:expiry]) do
          {:ok,
           %{
             scope: opts[:scope],
             verbs: verbs,
             audience: opts[:audience],
             expiry: expiry
           }}
        end
    end
  end

  defp parse_verbs(verbs) do
    names = String.split(verbs, ",", trim: true)

    cond do
      names == [] ->
        {:error, @verb_omission}

      true ->
        Enum.reduce_while(names, {:ok, []}, fn name, {:ok, acc} ->
          case Map.fetch(@verbs, name) do
            {:ok, verb} ->
              {:cont, {:ok, [verb | acc]}}

            :error ->
              {:halt, {:error, "cert-mint refused: unknown verb #{inspect(name)} in --verbs"}}
          end
        end)
        |> case do
          {:ok, parsed} -> {:ok, parsed |> Enum.uniq() |> Enum.sort()}
          error -> error
        end
    end
  end

  defp parse_expiry(nil), do: {:ok, nil}

  defp parse_expiry(expiry) do
    case DateTime.from_iso8601(expiry) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      {:error, _reason} -> {:error, "cert-mint refused: --expiry must be ISO8601"}
    end
  end

  defp request_body(parsed, relative_path) do
    scope =
      case parsed.scope do
        <<prefix, _rest::binary>> = ref when prefix in [?:, ?@] -> ref
        path -> join_paths(relative_path, path)
      end

    %{
      "scope" => scope,
      "verbs" => Enum.map(parsed.verbs, &Atom.to_string/1),
      "audience" => parsed.audience,
      "expiry" => encode_expiry(parsed.expiry)
    }
  end

  defp encode_expiry(nil), do: nil
  defp encode_expiry(expiry), do: DateTime.to_iso8601(expiry)

  defp post(endpoint, body, opts) do
    case Keyword.get(opts, :post) do
      nil ->
        with {:ok, _apps} <- Application.ensure_all_started(:req) do
          Req.post(endpoint, json: body)
        end

      post when is_function(post, 2) ->
        post.(endpoint, body)
    end
  end

  defp decode_response(%{status: status, body: %{"cid" => cid}})
       when status in 200..299 and is_binary(cid),
       do: {:ok, cid}

  defp decode_response(%{body: %{"error" => message}}) when is_binary(message),
    do: {:error, message}

  defp decode_response(%{status: status}),
    do: {:error, "cert-mint transport failed: HTTP #{status}"}

  defp usage_refusal do
    "cert-mint refused: usage: commonplace cert-mint --scope REF --verbs LIST --audience PRINCIPAL [--expiry E]"
  end

  defp uuid?(str) do
    Regex.match?(~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i, str)
  end
end
