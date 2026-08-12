# cp-erpc-guard.exs — the resident-module gate for scripts that erpc a live serve.
#
# WHY THIS EXISTS (2026-08-12)
#
# CLAUDE.md's rule is that an RPC to an UNLOADED module is a WRITE: the serve
# runs interactive with its code path on the working tree's _build, so calling
# a module it has not loaded yet force-loads YOUR tree's version into the live
# node — including uncommitted code.
#
# Every erpc script I write opens with an is_loaded line. On 2026-08-12 one of
# them printed
#
#     is_loaded Commonplace.ViewActionDispatch: false
#
# and then called it anyway, because the line was an IO.puts and nothing
# branched on it. The load was harmless that time (the tree differed from the
# deployed sha by two markdown files and zero code, measured with a control),
# but the defect is structural and it is the day's recurring one:
#
#   ⭐ A CHECK WHOSE RESULT DOES NOT CHANGE WHAT HAPPENS NEXT IS DECORATION.
#
# The same shape appeared twice more the same day in other agents' tools: a
# watchdog that killed a healthy serve, and a quota gate that fired correctly
# and continuously. In all three the signal was TRUE and no action followed
# from it. A printed fact is not a gate.
#
# WHAT IT DOES
#
#   Guard.require_resident!(node, [Mod, ...])
#
#   HALTS the script if any module is not already loaded on the target node.
#   It does not warn, and it does not proceed.
#
# THE OVERRIDE LEAVES A TRACE ON PURPOSE
#
#   CP_ERPC_ALLOW_LAZY_LOAD="<why>" makes the guard proceed — and it prints
#   the stated authority and the exact modules it is about to force-load,
#   at runtime, into the run's own output. An override that leaves no trace
#   is a removed check with extra steps; this one puts the reason in the
#   transcript next to the consequence.
#
# USAGE
#
#   Code.require_file("bin/cp-erpc-guard.exs", "/home/jes/commonplace")
#   node = :commonplace_dev@commonplace
#   true = Node.connect(node)
#   CPErpcGuard.require_resident!(node, [Commonplace.ViewActionDispatch,
#                                        Commonplace.Bd.Issue])
#
# ⚠️ Uses :code.is_loaded/1 — a code-server QUERY that does not itself load
# anything. Do not "improve" it to Code.ensure_loaded?/1 or module_info/1:
# those AUTO-LOAD, so the check would cause the very thing it is checking for.

defmodule CPErpcGuard do
  @doc """
  Halt unless every module is already resident on `node`.

  Returns `:ok` when all are loaded. Halts with status 1 otherwise, unless
  `CP_ERPC_ALLOW_LAZY_LOAD` states a reason — in which case it proceeds and
  prints that reason together with the modules being force-loaded.
  """
  def require_resident!(node, modules) when is_list(modules) do
    {resident, absent} =
      Enum.split_with(modules, fn mod ->
        :erpc.call(node, :code, :is_loaded, [mod]) != false
      end)

    Enum.each(resident, &IO.puts("resident on #{node}: #{inspect(&1)}"))

    case {absent, System.get_env("CP_ERPC_ALLOW_LAZY_LOAD")} do
      {[], _} ->
        :ok

      {absent, nil} ->
        IO.puts(:stderr, """

        ⛔ HALTED — these modules are NOT loaded on #{node}:
        #{Enum.map_join(absent, "\n", &"     #{inspect(&1)}")}

        Calling them would force-load THIS working tree's version into the
        live node (CLAUDE.md: an RPC to an unloaded module is a WRITE).

        Decide deliberately, then either:
          • deploy first, so the serve loads its own build; or
          • confirm your tree matches the deployed sha for these modules and
            re-run with the reason recorded:

            CP_ERPC_ALLOW_LAZY_LOAD="tree == deployed sha for these (measured: ...)" \\
              elixir --sname ... script.exs
        """)

        System.halt(1)

      {absent, reason} ->
        IO.puts("""

        ⚠️ LAZY LOAD ALLOWED BY OVERRIDE — proceeding will load this tree's
        version of these modules into #{node}:
        #{Enum.map_join(absent, "\n", &"     #{inspect(&1)}")}
        stated authority: #{reason}
        """)

        :ok
    end
  end
end
