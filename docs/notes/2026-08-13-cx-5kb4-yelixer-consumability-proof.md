# CX-5kb4: published yelixer consumability proof

## Verdict

**CONSUMABLE.** A standalone consumer fetched the published yelixer repository over HTTPS at locked SHA `691a4f44a91039ecc02a8824a1a5fafa79d9c253`, compiled it from an empty build directory, inserted text into one `Yelixer.Doc`, encoded an update, applied it to a second independently-created `Yelixer.Doc`, and asserted that both documents rendered the same text.

This proves the HTTPS dependency form only:

`https://github.com/commonplace-systems/yelixer.git`

It does not prove an eventual `git@github.com:commonplace-systems/yelixer.git` declaration. The sandbox's intentional SSH host-key refusal was not exercised and is not a deviation.

## Resolved source and toolchain

- Consumer root: `/tmp/cx-5kb4-consumer.ZjNO3d`
- Resolved yelixer dependency path: `/tmp/cx-5kb4-consumer.ZjNO3d/deps/yelixer`
- Resolved checkout origin: `https://github.com/commonplace-systems/yelixer.git`
- Resolved checkout HEAD: `691a4f44a91039ecc02a8824a1a5fafa79d9c253`
- Definitive empty build path: `/tmp/cx-5kb4-build.XFwANf`
- Erlang/OTP: 27 (`erts-15.2.7.6`)
- Elixir/Mix: Mix 1.18.4, compiled with Erlang/OTP 27

`mix deps` positively identified the resolved dependency as:

```text
* yelixer (https://github.com/commonplace-systems/yelixer.git - 691a4f44a91039ecc02a8824a1a5fafa79d9c253) (mix)
  locked at 691a4f4 (ref)
```

The checkout independently reported:

```text
resolved_yelixer_path=/tmp/cx-5kb4-consumer.ZjNO3d/deps/yelixer
yelixer_checkout_sha=691a4f44a91039ecc02a8824a1a5fafa79d9c253
yelixer_origin=https://github.com/commonplace-systems/yelixer.git
```

## Exact consumer `mix.exs`

```elixir
defmodule Cx5kb4Consumer.MixProject do
  use Mix.Project

  def project do
    [
      app: :cx_5kb4_consumer,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:yelixer,
       git: "https://github.com/commonplace-systems/yelixer.git",
       ref: "691a4f44a91039ecc02a8824a1a5fafa79d9c253"}
    ]
  end
end
```

The generated lock entry was:

```elixir
"yelixer": {:git, "https://github.com/commonplace-systems/yelixer.git", "691a4f44a91039ecc02a8824a1a5fafa79d9c253", [ref: "691a4f44a91039ecc02a8824a1a5fafa79d9c253"]},
```

## Exact convergence call

The standalone consumer ran this `proof.exs`:

```elixir
alias Yelixer.{Doc, Encoding}
alias Yelixer.Types.Text

type_name = "proof-text"
expected = "published artifact converges"

source = Doc.new(client_id: 101)
{source, _text_ref} = Doc.get_or_create_type(source, type_name, :text)
source = Text.insert(source, type_name, 0, expected)

update = Encoding.encode_update(source)

receiver = Doc.new(client_id: 202)
{:ok, receiver} = Encoding.apply_update(receiver, update)

source_text = Text.to_string(source, type_name)
receiver_text = Text.to_string(receiver, type_name)
converged? = source_text == expected and receiver_text == source_text

IO.puts("source_client_id=#{source.client_id}")
IO.puts("receiver_client_id=#{receiver.client_id}")
IO.puts("source_text=#{inspect(source_text)}")
IO.puts("receiver_text=#{inspect(receiver_text)}")
IO.puts("update_bytes=#{byte_size(update)}")
IO.puts("converged?=#{converged?}")

unless converged?, do: raise("independently-created receiver did not converge")
```

The distinct fixed client IDs make the independent document construction visible. The receiver was created separately before the encoded update was applied.

## Commands and actual output

The project was created outside the repository. Because an external directory has no repository `.tool-versions`, the installed ASDF runtime versions were selected explicitly. This selected the executable only; it did not alter dependency resolution.

```sh
ASDF_ELIXIR_VERSION=1.18.4-otp-27 \
ASDF_ERLANG_VERSION=27.3.4.8 \
MIX_HOME=/tmp/cx-5kb4-mix-home \
HEX_HOME=/tmp/cx-5kb4-hex-home \
MIX_BUILD_PATH=/tmp/cx-5kb4-build \
mix new . --app cx_5kb4_consumer --module Cx5kb4Consumer
```

The dependency was then fetched from the network:

```sh
ASDF_ELIXIR_VERSION=1.18.4-otp-27 \
ASDF_ERLANG_VERSION=27.3.4.8 \
MIX_HOME=/tmp/cx-5kb4-mix-home \
HEX_HOME=/tmp/cx-5kb4-hex-home \
MIX_BUILD_PATH=/tmp/cx-5kb4-build \
mix deps.get
```

The relevant actual fetch output was:

```text
* Getting yelixer (https://github.com/commonplace-systems/yelixer.git - 691a4f44a91039ecc02a8824a1a5fafa79d9c253)
remote: Enumerating objects: 914, done.
remote: Total 914 (delta 532), reused 879 (delta 498), pack-reused 0 (from 0)
==> yelixer
Resolving Hex dependencies...
Resolution completed in 0.039s
New:
  jason 1.4.5
  telemetry 1.4.2
* Getting jason (Hex package)
* Getting telemetry (Hex package)
```

For the definitive no-cache run, `mktemp` allocated a new build directory and `find` showed no entries before compilation:

```sh
proof_build=$(mktemp -d /tmp/cx-5kb4-build.XXXXXX)
printf 'fresh_build_path=%s\n' "$proof_build"
find "$proof_build" -mindepth 1 -maxdepth 1 -printf '%P\n'

ASDF_ELIXIR_VERSION=1.18.4-otp-27 \
ASDF_ERLANG_VERSION=27.3.4.8 \
MIX_HOME=/tmp/cx-5kb4-mix-home \
HEX_HOME=/tmp/cx-5kb4-hex-home \
MIX_BUILD_PATH="$proof_build" \
mix deps.compile

ASDF_ELIXIR_VERSION=1.18.4-otp-27 \
ASDF_ERLANG_VERSION=27.3.4.8 \
MIX_HOME=/tmp/cx-5kb4-mix-home \
HEX_HOME=/tmp/cx-5kb4-hex-home \
MIX_BUILD_PATH="$proof_build" \
mix run proof.exs
```

Actual output (the empty line after the path is the empty-directory `find` result):

```text
fresh_build_path=/tmp/cx-5kb4-build.XFwANf
===> Analyzing applications...
===> Compiling telemetry
==> jason
Compiling 10 files (.ex)
Generated jason app
==> yelixer
Compiling 19 files (.ex)
Generated yelixer app
Compiling 1 file (.ex)
Generated cx_5kb4_consumer app
source_client_id=101
receiver_client_id=202
source_text="published artifact converges"
receiver_text="published artifact converges"
update_bytes=47
converged?=true
```

The convergence assertion therefore passed once: `receiver_text` equaled both the inserted expected value and `source_text`. The command exited 0. An earlier compilation and identical call also exited 0; the recorded run above repeated it solely to make the empty build origin mechanically explicit.

## Fence audit with positive controls

The inspected corpus was non-empty before any zero was trusted: `mix.exs` had 29 lines and `mix.lock` had 5 lines. Searches used `rg --fixed-strings` across both files. A present value returned exit 0; an absent value returned the expected no-match exit 1.

| Check | Count | `rg` exit | Meaning |
|---|---:|---:|---|
| positive control: `commonplace-systems` | 2 | 0 | the audit sees the declared and locked URL |
| positive control: full locked SHA | 2 | 0 | the audit sees the declared and locked ref |
| forbidden owner `jes5199` | 0 | 1 | absent with expected no-match error shape |
| forbidden `in_umbrella:` | 0 | 1 | no umbrella dependency |
| forbidden `path:` | 0 | 1 | no local path dependency |
| forbidden `override:` | 0 | 1 | no dependency override |

Every fence was honored positively:

- **No umbrella:** the consumer was a new standalone Mix project rooted at `/tmp/cx-5kb4-consumer.ZjNO3d`, outside `/home/jes/sol-s37b/wt`. It had one direct dependency and did not reference the umbrella.
- **No local path dependency:** the exact `mix.exs`, lock entry, origin URL, and resolved path above show a git checkout fetched under the external consumer's own `deps/`. The `path:` count was 0 with no-match exit 1.
- **No override:** the `override:` count was 0 with no-match exit 1.
- **No cached build:** `/tmp/cx-5kb4-build.XFwANf` was newly allocated and empty immediately before `mix deps.compile`; the output shows all 19 yelixer files compiling.
- **No copied deps:** no dependency directory was copied or symlinked. `mix deps.get` created the consumer's own `deps/yelixer` by fetching 914 objects from the HTTPS remote. Neither `/home/jes/commonplace/deps` nor any repository dependency directory was used.
- **No in-tree dependency path:** `MIX_DEPS_PATH` was unset, and the positively resolved yelixer path was `/tmp/cx-5kb4-consumer.ZjNO3d/deps/yelixer`, outside the worktree.
- **No repository build path:** both explicit `MIX_BUILD_PATH` values were under `/tmp`; the definitive one was `/tmp/cx-5kb4-build.XFwANf`.
- **No yelixer mutation:** operations against yelixer were fetch/read/compile only. Nothing was committed or pushed there.

There were **no workarounds** to dependency fetching, source selection, compilation, or convergence. No path override, vendoring, copied dependency, alternative ref, or API substitution was used. Explicit ASDF version selection was ordinary external-project toolchain setup after the first bare `mix new` invocation reported that no version was selected; it did not repair or bypass any yelixer failure. The first convergence run passed, and the second fresh-build run repeated that pass unchanged.

## Remote postcondition

An HTTPS `git ls-remote` after the proof returned a non-empty two-line corpus:

```text
691a4f44a91039ecc02a8824a1a5fafa79d9c253  HEAD
691a4f44a91039ecc02a8824a1a5fafa79d9c253  refs/heads/main
```

- Remote ref count: 2
- Positive control matching locked `refs/heads/main`: count 1, `rg` exit 0
- Tag count: 0, with the expected no-match `rg` exit 1
- Tip: `691a4f44a91039ecc02a8824a1a5fafa79d9c253`

## Deviations

None. HTTPS was required and is the URL form proved. The known SSH refusal is an intentional sandbox fence, was not worked around, and is not a deviation. The atomic delete-and-flip round was not started; no umbrella app, dependency declaration, or lockfile in this repository was changed.
