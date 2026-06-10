defmodule Commonplace.View.ComputeRunner do
  @moduledoc """
  CX-b52t (sub-bead i of CX-a9cv M7): substrate-tier compute caller.

  Reads an Elixir source-doc, compiles via `Commonplace.Code.SourceDoc`,
  and calls `module.compute(raw, ctx)`.

  Replaces M5 `Commonplace.View.ComputeSpec`. The XML compute-spec doc
  form is gone in M7; the Elixir source IS the spec.

  ## Author-side contract

  Source author writes a module with a `compute/2` function:

      defmodule Commonplace.UserCode.Chat.Compute do
        alias Commonplace.Compute

        def compute(raw, ctx) do
          raw
          |> Compute.decode_json_array()
          |> Compute.materialize(chains: [
            {:edit_of, :latest_replaces},
            {:tombstone_of, :marks_deleted}
          ])
          |> Commonplace.Chat.ChatViewBuilder.build_view_xml(ctx.room_name)
        end
      end

  ## Expected ctx fields

  Convention; not enforced. Authors pattern-match what they need.

    * `:room_name` — chat room name (binary), from compute-context derivation
    * `:root_uuid` — substrate root UUID (binary)
    * `:store` — CommitStore name
    * `:signing_context` — author identity for signed operations (future)

  `ctx` is a map for M7 flexibility; may promote to a typed struct
  (`%Commonplace.View.ComputeContext{}`) in a future arc once field
  surface stabilizes.

  ## Validate at supervisor-start (M5 banked discipline)

  `validate/2` is called by `Commonplace.ViewCompute` at supervisor-
  start; catches missing `compute/2` exports + compile errors BEFORE
  compute-time so failures don't fire as silent runtime crashes.

  Runtime correctness (return shape, edge-case behavior, side effects)
  is author responsibility — the (α) commit accepts looser substrate
  validation in exchange for full Elixir expressiveness. The runner is
  shape-agnostic: it passes `raw` straight through and returns whatever
  `compute/2` returns, untouched. So the input shape (set by the view's
  data wiring) and the output shape (e.g. view-XML) are contracts
  between the author's code and its consumers — not anything this module
  inspects or enforces.
  """

  alias Commonplace.Code.SourceDoc

  @doc """
  Read + compile the code-doc; call `module.compute(raw, ctx)`.

  Returns `{:ok, output}` from the compute fn, or `{:error, reason}`
  on read/compile/missing-export failure.

  Raises any exception the compute fn itself raises (substrate doesn't
  swallow author bugs at runtime).
  """
  @spec compute(binary(), term(), map(), GenServer.server()) ::
          {:ok, term()} | {:error, term()}
  def compute(code_uuid, raw, ctx, store)
      when is_binary(code_uuid) and is_map(ctx) do
    with {:ok, module} <- SourceDoc.compile(code_uuid, store),
         :ok <- validate_compute_exported(module) do
      {:ok, apply(module, :compute, [raw, ctx])}
    end
  end

  @doc """
  Validate the code-doc compiles + exports `compute/2`. Called by
  `Commonplace.ViewCompute` at supervisor-start to catch malformed
  compute-docs before compute-time.

  Returns `:ok` on success, `{:error, reason}` on read/compile/missing-
  export failure.
  """
  @spec validate(binary(), GenServer.server()) :: :ok | {:error, term()}
  def validate(code_uuid, store) when is_binary(code_uuid) do
    with {:ok, module} <- SourceDoc.compile(code_uuid, store) do
      validate_compute_exported(module)
    end
  end

  defp validate_compute_exported(module) do
    if :erlang.function_exported(module, :compute, 2) do
      :ok
    else
      {:error, "compute/2 not exported on #{inspect(module)}"}
    end
  end
end
