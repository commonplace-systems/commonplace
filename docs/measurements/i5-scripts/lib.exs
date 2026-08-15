# I5 shared setup — deliberately NO shared runtime state between deployments.
# The ONLY channel from A to B is the store on disk and the key custody file.
defmodule I5 do
  alias Commonplace.Crypto.{Signing, SigningContext}

  def base, do: System.fetch_env!("I5_BASE")
  def data_dir, do: Path.join(base(), "store")
  def custody, do: Path.join(base(), "custody.json")

  def ctx_from_keys(uuid, pub, priv),
    do: %SigningContext{identity_uuid: uuid, public_key: pub, private_key: priv}

  # Key custody: A mints, writes to disk; B reloads. Simulates the child
  # workspace SecretStore surviving a deployment boundary.
  def save_ctx(name, %SigningContext{} = c) do
    existing = if File.exists?(custody()), do: Jason.decode!(File.read!(custody())), else: %{}

    File.write!(
      custody(),
      Jason.encode!(
        Map.put(existing, name, %{
          "uuid" => c.identity_uuid,
          "pub" => Base.encode64(c.public_key),
          "priv" => Base.encode64(c.private_key)
        })
      )
    )
  end

  def load_ctx(name) do
    %{"uuid" => u, "pub" => pub, "priv" => priv} =
      Jason.decode!(File.read!(custody())) |> Map.fetch!(name)

    ctx_from_keys(u, Base.decode64!(pub), Base.decode64!(priv))
  end

  def new_ctx(name) do
    {pub, priv} = Signing.generate_keypair()
    c = ctx_from_keys(UUID.uuid4(), pub, priv)
    save_ctx(name, c)
    c
  end

  def start_store!(tag, trusted) do
    # --no-start is deliberate (a bare `mix run` orphans :global singletons),
    # so the store's own dependencies are started explicitly here.
    {:ok, _} = Application.ensure_all_started(:telemetry)
    {:ok, _} = Application.ensure_all_started(:phoenix_pubsub)
    case Phoenix.PubSub.Supervisor.start_link(name: Commonplace.PubSub) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    File.mkdir_p!(data_dir())

    File.write!(
      Path.join(data_dir(), "trust.json"),
      Jason.encode!(%{
        "accept_unsigned" => false,
        "trusted_identities" =>
          Map.new(trusted, fn c -> {c.identity_uuid, Signing.encode_key(c.public_key)} end)
      })
    )

    n = :erlang.unique_integer([:positive])
    store = :"i5_store_#{tag}_#{n}"

    {:ok, _} =
      Commonplace.Store.Supervisor.start_link(
        data_dir: data_dir(),
        name: :"i5_sup_#{tag}_#{n}",
        commit_store_name: store,
        trust_side_store_name: :"i5_tss_#{tag}_#{n}",
        pending_imports_name: :"i5_pi_#{tag}_#{n}",
        local_write_gate: :enforce
      )

    store
  end

  def say(k, v), do: IO.puts("#{k}=#{inspect(v)}")

  # The understanding record carries a PROTECTED `zone` field; a subtree cert
  # refuses a write that drops it (subtree_carve_ok?). So updates MERGE.
  def merged(ref, store, changes) do
    {:ok, current} = Commonplace.Identity.Root.read_record(ref, store)
    Map.merge(current, changes)
  end
end
