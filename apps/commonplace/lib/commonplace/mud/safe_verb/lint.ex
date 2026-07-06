defmodule Commonplace.MUD.SafeVerb.Lint do
  @moduledoc """
  CX-ndvi §3 — Lint v1: an AST scan over a safe-verb `run/1` BODY (the
  raw text an author submits, BEFORE `Commonplace.MUD.SafeVerb` wraps it
  in a substrate-controlled module).

  ## HONESTY BOUNDARY (load-bearing — read before relying on this)

  This is DEFENSE IN DEPTH, not a sandbox. It raises the bar against
  accidental misuse and unsophisticated hostile code by banning the
  obvious escape hatches (process spawning, dynamic atom creation, OS/
  file/module access, self-authoring a new module). It does NOT, and
  cannot, make the BEAM contain a determined hostile Elixir author —
  there is no such boundary short of OS-level process isolation
  (phase-4, banked; see `Commonplace.MUD.World.Facade`'s moduledoc for
  the matching honesty note on the effect-surface side). Treat a lint
  pass as "raised bar," never as "safe to run untrusted."

  ## What's banned (build spec §3)

    * `apply/2,3` — dynamic dispatch that could reach any exported
      function, including ones this lint can't see literally in source.
    * `spawn`/`spawn_link`/`spawn_monitor`, and any reference to the
      `Process` or `Task` modules — no independent execution contexts
      outside the bounded `Commonplace.MUD.SafeVerb.Bounds.run/1` Task
      the substrate already wraps every invocation in.
    * `String.to_atom/1` / raw `:erlang.binary_to_atom` — dynamic atom
      creation from player-influenced strings (unbounded atom-table
      growth / atom exhaustion).
    * `defmodule` — a safe verb authors a `run/1` BODY, not a module;
      the substrate controls module identity/naming (reuses CX-9f62).
    * The modules `Code`, `File`, `System`, `Node` — reflection/eval,
      filesystem, OS environment, and distributed-node access.
    * Raw `:os` / `:erlang` remote calls.

  Author code that doesn't touch any of the above compiles as normal
  Elixir; the facade (`Commonplace.MUD.World.Facade`) is still the only
  thing bound in scope, so even lint-clean code has no ambient reach
  beyond what the facade grants.
  """

  @banned_alias_modules ~w(Process Task Code File System Node)a

  @doc """
  Scan `source` (the raw `run/1` body text). Returns `:ok` or
  `{:error, {:lint_violation, [String.t()]}}` (one message per distinct
  violation found) or `{:error, {:lint_syntax_error, message}}` if the
  body itself doesn't parse as Elixir.
  """
  @spec check(String.t()) :: :ok | {:error, term()}
  def check(source) when is_binary(source) do
    case Code.string_to_quoted(source) do
      {:ok, ast} ->
        case collect_violations(ast) |> Enum.uniq() do
          [] -> :ok
          violations -> {:error, {:lint_violation, violations}}
        end

      {:error, {_meta, message, token}} ->
        {:error, {:lint_syntax_error, "#{inspect(message)}#{inspect(token)}"}}
    end
  end

  defp collect_violations(ast) do
    {_ast, hits} = Macro.prewalk(ast, [], fn node, acc -> {node, acc ++ violation_for(node)} end)
    hits
  end

  # `defmodule` — authors write a body, not a module.
  defp violation_for({:defmodule, _meta, _args}) do
    ["defmodule is banned in safe verbs — write a run/1 body, not a module"]
  end

  # Bare/local apply, spawn, spawn_link, spawn_monitor calls.
  defp violation_for({name, _meta, args})
       when name in [:apply, :spawn, :spawn_link, :spawn_monitor] and is_list(args) do
    ["#{name} is banned in safe verbs"]
  end

  # Kernel.apply/2,3 (or Kernel.spawn*) via explicit module qualification.
  defp violation_for({{:., _, [{:__aliases__, _, [:Kernel]}, name]}, _, _})
       when name in [:apply, :spawn, :spawn_link, :spawn_monitor] do
    ["Kernel.#{name} is banned in safe verbs"]
  end

  # Any reference to a banned module alias (Process/Task/Code/File/System/Node),
  # whether as `Process.sleep(1)` (visits the inner __aliases__ node) or bare.
  defp violation_for({:__aliases__, _meta, [mod | _rest]}) when mod in @banned_alias_modules do
    ["#{mod} is banned in safe verbs"]
  end

  # String.to_atom/1
  defp violation_for({{:., _, [{:__aliases__, _, [:String]}, :to_atom]}, _, _}) do
    ["String.to_atom is banned in safe verbs"]
  end

  # Raw :erlang.* calls (e.g. :erlang.binary_to_atom/1,2).
  defp violation_for({{:., _, [:erlang, fun]}, _, _}) do
    ["raw :erlang.#{fun} calls are banned in safe verbs"]
  end

  # Raw :os.* calls.
  defp violation_for({{:., _, [:os, fun]}, _, _}) do
    [":os.#{fun} calls are banned in safe verbs"]
  end

  defp violation_for(_node), do: []
end
