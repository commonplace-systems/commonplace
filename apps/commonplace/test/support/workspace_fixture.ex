defmodule Commonplace.Test.WorkspaceFixture do
  @moduledoc """
  Complete workspace fixtures built by the real workspace initialization path.

  Callers start a commit store against `data_dir`, set the application's
  `:data_dir`, and pass that store here. The helper delegates to
  `Commonplace.Workspace.initialize/2`, the same function used by CLI `init`,
  so signing identity, published public keys, root/prior-world marker,
  checkout metadata, and commit-store layout evolve together.
  """

  @type degradation ::
          :without_node_signing_key
          | :without_public_key_artifact
          | {:corrupt_trust_json, String.t()}

  @spec complete_workspace!(Path.t(), keyword()) :: map()
  def complete_workspace!(data_dir, opts \\ []) do
    store = Keyword.get(opts, :store, Commonplace.Store.CommitStore)
    checkout_dir = Keyword.get(opts, :checkout_dir, Path.join(data_dir, "checkout"))
    degradations = Keyword.get(opts, :degrade, [])

    File.mkdir_p!(checkout_dir)

    {:ok, initialized} =
      Commonplace.Workspace.initialize(data_dir,
        store: store,
        checkout_dir: checkout_dir
      )

    Enum.each(degradations, &degrade!(data_dir, &1))

    Map.merge(initialized, %{data_dir: data_dir, checkout_dir: checkout_dir})
  end

  defp degrade!(data_dir, :without_node_signing_key) do
    File.rm!(Path.join(data_dir, "node_signing_key"))
  end

  defp degrade!(data_dir, :without_public_key_artifact) do
    File.rm!(Path.join(data_dir, "node_signing_public_keys.json"))
  end

  defp degrade!(data_dir, {:corrupt_trust_json, contents}) when is_binary(contents) do
    File.write!(Path.join(data_dir, "trust.json"), contents)
  end
end
