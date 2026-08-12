defmodule Commonplace.Cell.Manifest do
  @moduledoc """
  The cell birth-certificate document (`__cell.json`) for CX-brxx.

  A manifest records governance facts and references authority certificates by
  immutable CID. It never grants, proves, constructs, or substitutes for a
  capability. Certificate existence and validity belong to the later mint
  ceremony, not to this static validator.

  Pre-field workspaces have no manifest entry. `read/2` reports that temporal
  exception explicitly as `:pre_field_default`; a stored post-field manifest is
  reported as `:stored`.
  """

  alias Commonplace.Document.ContentType
  alias Commonplace.GitBridge.CanonicalJson
  alias Commonplace.Store.{Commit, CommitStoreClient}
  alias Commonplace.Tree.{DocBuilder, Schema}
  alias Yelixer.{Doc, Encoding}

  @filename "__cell.json"
  @workspace_classes ~w(default minimal)
  @sla_tiers ~w(durable ephemeral)
  @cid_pattern ~r/\A[0-9a-f]{64}\z/

  defstruct [
    :id,
    :parent,
    :mission,
    :principal,
    :workspace_class,
    :root_entries,
    :authority,
    :sync_scope,
    :sla,
    :environments,
    :stewards,
    :auditors,
    :escalate_to,
    :outputs,
    :environment_faced
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          parent: String.t() | nil,
          mission: String.t(),
          principal: String.t(),
          workspace_class: String.t(),
          root_entries: [String.t()],
          authority: map(),
          sync_scope: map(),
          sla: map(),
          environments: map(),
          stewards: [String.t()],
          auditors: [String.t()],
          escalate_to: String.t() | nil,
          outputs: [String.t()],
          environment_faced: [String.t()]
        }

  @doc "Validate every statically-checkable cell-manifest constraint."
  @spec validate(t() | map()) :: :ok | {:error, {:invalid_manifest, String.t(), String.t()}}
  def validate(manifest) when is_map(manifest) do
    with :ok <- required_binary(manifest, :id, "id"),
         :ok <- required_nullable_binary(manifest, :parent, "parent"),
         :ok <- required_binary(manifest, :mission, "mission"),
         :ok <- required_binary(manifest, :principal, "principal"),
         :ok <- validate_workspace_class(manifest),
         :ok <- required_string_list(manifest, :root_entries, "root_entries"),
         {:ok, authority} <- required_map(manifest, :authority, "authority"),
         :ok <- validate_authority(authority),
         {:ok, sync_scope} <- required_map(manifest, :sync_scope, "sync_scope"),
         :ok <- validate_sync_scope(sync_scope),
         {:ok, sla} <- required_map(manifest, :sla, "sla"),
         :ok <- validate_sla(sla),
         {:ok, environments} <- required_map(manifest, :environments, "environments"),
         :ok <- validate_environments(environments),
         :ok <- required_string_list(manifest, :stewards, "stewards"),
         :ok <- required_string_list(manifest, :auditors, "auditors"),
         :ok <- validate_auditor_independence(manifest),
         :ok <- required_nullable_binary(manifest, :escalate_to, "escalate_to"),
         :ok <- required_string_list(manifest, :outputs, "outputs"),
         :ok <- required_string_list(manifest, :environment_faced, "environment_faced") do
      :ok
    end
  end

  def validate(_manifest), do: invalid("manifest", "must be an object")

  @doc "Encode a valid manifest as deterministic JSON text."
  @spec encode(t() | map()) :: {:ok, String.t()} | {:error, term()}
  def encode(manifest) do
    with :ok <- validate(manifest) do
      {:ok, manifest |> normalized_manifest() |> CanonicalJson.encode()}
    end
  end

  @doc "Decode JSON text and validate it before returning a manifest struct."
  @spec decode(String.t()) :: {:ok, t()} | {:error, term()}
  def decode(json) when is_binary(json) do
    with {:ok, decoded} <- Jason.decode(json),
         :ok <- validate(decoded) do
      {:ok, struct(__MODULE__, atomized_manifest(decoded))}
    end
  end

  @doc "Read the temporal pre-field default or a stored post-field manifest."
  @spec read(String.t(), GenServer.server()) ::
          {:ok, %{case: :pre_field_default, workspace_class: :default}}
          | {:ok, %{case: :stored, manifest: t()}}
          | {:error, term()}
  def read(root_uuid, store \\ CommitStoreClient) when is_binary(root_uuid) do
    with {:ok, root_doc} <- load_root(root_uuid, store) do
      case Schema.get_entry(root_doc, @filename) do
        :error ->
          {:ok, %{case: :pre_field_default, workspace_class: :default}}

        {:ok, entry} ->
          with {:ok, doc} <- load_manifest_doc(entry.node_id, store),
               json when is_binary(json) <- ContentType.get_content(doc),
               {:ok, manifest} <- decode(json) do
            {:ok, %{case: :stored, manifest: manifest}}
          else
            nil -> {:error, {:empty_manifest_doc, entry.node_id}}
            {:error, _reason} = error -> error
            other -> {:error, {:invalid_manifest_content, other}}
          end
      end
    end
  end

  @doc "Create and attach a manifest through the existing governed commit seams."
  @spec create(String.t(), t() | map(), GenServer.server(), keyword()) ::
          {:ok, t()} | {:error, term()}
  def create(root_uuid, manifest, store \\ CommitStoreClient, opts \\ []) do
    with {:ok, encoded} <- encode(manifest),
         {:ok, decoded} <- decode(encoded),
         {:ok, root_doc} <- load_root(root_uuid, store),
         :error <- Schema.get_entry(root_doc, @filename),
         {:ok, doc_uuid} <- create_text_doc(encoded, store, opts),
         :ok <- attach_manifest(root_uuid, root_doc, doc_uuid, store, opts),
         {:ok, %{case: :stored, manifest: verified}} <- read(root_uuid, store),
         true <- verified == decoded do
      {:ok, verified}
    else
      {:ok, _entry} -> {:error, :manifest_already_present}
      false -> {:error, :manifest_reread_mismatch}
      {:error, _reason} = error -> error
    end
  end

  @doc "Amend the existing manifest doc through the normal signed content write path."
  @spec amend(String.t(), t() | map(), GenServer.server(), keyword()) ::
          {:ok, t()} | {:error, term()}
  def amend(root_uuid, manifest, store \\ CommitStoreClient, opts \\ []) do
    with {:ok, encoded} <- encode(manifest),
         {:ok, decoded} <- decode(encoded),
         {:ok, root_doc} <- load_root(root_uuid, store),
         {:ok, entry} <- fetch_manifest_entry(root_doc),
         :ok <- write_text_doc(entry.node_id, encoded, store, opts),
         {:ok, %{case: :stored, manifest: verified}} <- read(root_uuid, store),
         true <- verified == decoded do
      {:ok, verified}
    else
      false -> {:error, :manifest_reread_mismatch}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Confirmation-gated backfill for an existing workspace.

  The caller supplies every manifest value. A byte-identical rerun is a visible
  `:already_present` no-op; this function never invents missing governance data.
  """
  @spec backfill(String.t(), t() | map(), GenServer.server(), keyword()) ::
          {:ok, %{result: :backfilled | :already_present, manifest: t()}} | {:error, term()}
  def backfill(root_uuid, manifest, store \\ CommitStoreClient, opts \\ []) do
    if Keyword.get(opts, :confirm, false) do
      with {:ok, encoded} <- encode(manifest) do
        case read(root_uuid, store) do
          {:ok, %{case: :pre_field_default}} ->
            with {:ok, created} <- create(root_uuid, manifest, store, opts) do
              {:ok, %{result: :backfilled, manifest: created}}
            end

          {:ok, %{case: :stored, manifest: stored}} ->
            with {:ok, stored_encoded} <- encode(stored),
                 true <- stored_encoded == encoded do
              {:ok, %{result: :already_present, manifest: stored}}
            else
              false -> {:error, :different_manifest_already_present}
              {:error, _reason} = error -> error
            end

          {:error, _reason} = error ->
            error
        end
      end
    else
      {:error, :confirmation_required}
    end
  end

  defp validate_workspace_class(manifest) do
    with {:ok, value} <- fetch(manifest, :workspace_class),
         true <- value in @workspace_classes do
      :ok
    else
      :error -> invalid("workspace_class", "is required")
      false -> invalid("workspace_class", "must be one of #{Enum.join(@workspace_classes, ", ")}")
    end
  end

  defp validate_authority(authority) do
    with :ok <- required_string_list(authority, :certs, "authority.certs"),
         :ok <- required_boolean(authority, :authors_code, "authority.authors_code"),
         :ok <- required_nullable_binary(authority, :scope_note, "authority.scope_note"),
         {:ok, certs} <- fetch(authority, :certs),
         true <- Enum.all?(certs, &Regex.match?(@cid_pattern, &1)) do
      :ok
    else
      false -> invalid("authority.certs", "must contain only lowercase 64-hex CID references")
      {:error, _reason} = error -> error
    end
  end

  defp validate_sync_scope(sync_scope) do
    with :ok <- required_binary(sync_scope, :rule, "sync_scope.rule"),
         :ok <- required_string_list(sync_scope, :excludes, "sync_scope.excludes"),
         :ok <-
           required_string_list(sync_scope, :binary_extensions, "sync_scope.binary_extensions") do
      :ok
    else
      {:error, {:invalid_manifest, "sync_scope.excludes", _reason}} = error ->
        case fetch(sync_scope, :rule) do
          {:ok, "git-tracked-set"} ->
            invalid("sync_scope.excludes", "is required when sync_scope.rule is git-tracked-set")

          _ ->
            error
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp validate_sla(sla) do
    with {:ok, tier} <- fetch(sla, :tier),
         true <- tier in @sla_tiers,
         :ok <- required_nullable_binary(sla, :retention, "sla.retention"),
         :ok <- required_nullable_binary(sla, :note, "sla.note"),
         :ok <- validate_ephemeral_retention(tier, sla) do
      :ok
    else
      :error -> invalid("sla.tier", "is required")
      false -> invalid("sla.tier", "must be one of #{Enum.join(@sla_tiers, ", ")}")
      {:error, _reason} = error -> error
    end
  end

  defp validate_ephemeral_retention("ephemeral", sla) do
    case fetch(sla, :retention) do
      {:ok, value} when is_binary(value) and value != "" -> :ok
      _ -> invalid("sla.retention", "is required for ephemeral SLA")
    end
  end

  defp validate_ephemeral_retention(_tier, _sla), do: :ok

  defp validate_environments(environments) do
    with :ok <- required_boolean(environments, :may_declare, "environments.may_declare"),
         :ok <-
           required_string_list(
             environments,
             :requires_allowed,
             "environments.requires_allowed"
           ) do
      :ok
    end
  end

  defp validate_auditor_independence(manifest) do
    {:ok, principal} = fetch(manifest, :principal)
    {:ok, auditors} = fetch(manifest, :auditors)

    if principal in auditors,
      do: invalid("auditors", "must be disjoint from principal"),
      else: :ok
  end

  defp required_binary(map, key, field) do
    case fetch(map, key) do
      {:ok, value} when is_binary(value) and value != "" -> :ok
      {:ok, _value} -> invalid(field, "must be a non-empty string")
      :error -> invalid(field, "is required")
    end
  end

  defp required_nullable_binary(map, key, field) do
    case fetch(map, key) do
      {:ok, value} when is_binary(value) or is_nil(value) -> :ok
      {:ok, _value} -> invalid(field, "must be a string or null")
      :error -> invalid(field, "is required")
    end
  end

  defp required_boolean(map, key, field) do
    case fetch(map, key) do
      {:ok, value} when is_boolean(value) -> :ok
      {:ok, _value} -> invalid(field, "must be a boolean")
      :error -> invalid(field, "is required")
    end
  end

  defp required_string_list(map, key, field) do
    case fetch(map, key) do
      {:ok, values} when is_list(values) ->
        if Enum.all?(values, &is_binary/1),
          do: :ok,
          else: invalid(field, "must be a list of strings")

      {:ok, _value} ->
        invalid(field, "must be a list of strings")

      :error ->
        invalid(field, "is required")
    end
  end

  defp required_map(map, key, field) do
    case fetch(map, key) do
      {:ok, value} when is_map(value) -> {:ok, value}
      {:ok, _value} -> invalid(field, "must be an object")
      :error -> invalid(field, "is required")
    end
  end

  defp fetch(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(map, Atom.to_string(key))
    end
  end

  defp invalid(field, reason), do: {:error, {:invalid_manifest, field, reason}}

  defp normalized_manifest(manifest) do
    manifest
    |> map_from_struct_if_needed()
    |> stringify_keys()
  end

  defp map_from_struct_if_needed(%__MODULE__{} = manifest), do: Map.from_struct(manifest)
  defp map_from_struct_if_needed(manifest), do: manifest

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp atomized_manifest(map) do
    %{
      id: map["id"],
      parent: map["parent"],
      mission: map["mission"],
      principal: map["principal"],
      workspace_class: map["workspace_class"],
      root_entries: map["root_entries"],
      authority: atomize_nested(map["authority"], [:certs, :authors_code, :scope_note]),
      sync_scope: atomize_nested(map["sync_scope"], [:rule, :excludes, :binary_extensions]),
      sla: atomize_nested(map["sla"], [:tier, :retention, :note]),
      environments: atomize_nested(map["environments"], [:may_declare, :requires_allowed]),
      stewards: map["stewards"],
      auditors: map["auditors"],
      escalate_to: map["escalate_to"],
      outputs: map["outputs"],
      environment_faced: map["environment_faced"]
    }
  end

  defp atomize_nested(map, keys) do
    known_keys = Map.new(keys, fn key -> {Atom.to_string(key), key} end)
    Map.new(map, fn {key, value} -> {Map.get(known_keys, key, key), value} end)
  end

  defp load_root(root_uuid, store) do
    case DocBuilder.reconstruct_snapshot(store, root_uuid) do
      {:ok, root_doc} -> {:ok, root_doc}
      :none -> {:error, :no_root_schema}
      {:error, _reason} = error -> error
    end
  end

  defp load_manifest_doc(doc_uuid, store) do
    case DocBuilder.reconstruct_snapshot(store, doc_uuid) do
      {:ok, doc} -> {:ok, doc}
      :none -> {:error, :no_manifest_doc}
      {:error, _reason} = error -> error
    end
  end

  defp create_text_doc(encoded, store, opts) do
    uuid = UUID.uuid4()
    doc = Doc.new() |> ContentType.create(:text, @filename) |> ContentType.insert_text(0, encoded)

    case CommitStoreClient.create_commit(
           store,
           uuid,
           Encoding.encode_update(doc),
           nil,
           %{},
           write_opts(opts)
         ) do
      %Commit{} -> {:ok, uuid}
      {:error, _reason} = error -> error
    end
  end

  defp attach_manifest(root_uuid, root_doc, doc_uuid, store, opts) do
    updated = Schema.add_file(root_doc, @filename, doc_uuid)

    case CommitStoreClient.create_chained_commit(
           store,
           root_uuid,
           Encoding.encode_update(updated),
           %{},
           write_opts(opts)
         ) do
      %Commit{} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp fetch_manifest_entry(root_doc) do
    case Schema.get_entry(root_doc, @filename) do
      {:ok, entry} -> {:ok, entry}
      :error -> {:error, :manifest_missing}
    end
  end

  defp write_text_doc(doc_uuid, encoded, store, opts) do
    doc = Doc.new() |> ContentType.create(:text, @filename) |> ContentType.insert_text(0, encoded)

    case CommitStoreClient.create_chained_commit(
           store,
           doc_uuid,
           Encoding.encode_update(doc),
           %{},
           write_opts(opts)
         ) do
      %Commit{} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp write_opts(opts), do: Keyword.take(opts, [:signing_context])
end
