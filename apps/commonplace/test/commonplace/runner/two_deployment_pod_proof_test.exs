defmodule Commonplace.Runner.TwoDeploymentPodProofTest do
  @moduledoc """
  The joining arc's §5 demonstration: TWO DEPLOYMENTS, EACH IN ITS OWN POD.

  ## What this proves, and the one thing it must not assume

  `I5` proved the two-deployment continuity model on the HOST, where
  "B has no context continuity with A" was **structural**: A and B were separate
  OS processes sharing ONE CubDB store, and CubDB is single-opener, so A HAD TO
  EXIT before B could open the store at all. The guarantee came from the
  substrate, not from a test convention.

  ⛔ **In pods that mechanism is GONE.** Under the §4d ruling the pod never opens
  the durable store: it receives a PROJECTION at birth (materialised into the
  checkout it is given) and emits SIGNED ARTIFACTS. Two pods therefore never
  contend for anything, so nothing structural forces the handoff.

  ⇒ The property must now be **asserted rather than inherited**:

    * B's projection is built only AFTER A's signed artifact is ingested;
    * B runs in a FRESH pod with no bind to A's checkout / data / home; and
    * this test asserts those paths DIFFER BY VALUE.

  ## The control that carries the thesis

  `I5`'s control is non-negotiable and is reproduced here: a B-shaped deployment
  whose projection NEVER SAW A's yield MUST FAIL. Without it, "B succeeded"
  cannot distinguish READING A'S RESULT from RE-DERIVING IT BY DEFAULT — and a
  demonstration that cannot fail is a demonstration of nothing.

  ## Bounds

  * The pod never queries the store. This does NOT prove a pod can query it live;
    that would be new work and a new ruling.
  * The runner does the store read because THE RUNNER IS TRUSTED AND THE POD IS
    NOT. The pod stays unprivileged, holds no durable key, gains no query path.
  """

  use ExUnit.Case, async: false

  alias Commonplace.Crypto.Signing
  alias Commonplace.Runner.Launcher

  @moduletag :tmp_dir
  # Three sequential pod launches, each awaiting a real artifact.
  @moduletag timeout: 600_000

  # A's yield is a value B cannot compute: a random nonce minted INSIDE the pod
  # at run time. ⇒ If B reports it, B READ it. If B could derive it, the control
  # would be satisfiable by re-derivation and would prove nothing.

  setup %{tmp_dir: tmp_dir} do
    pods_root = Path.join(tmp_dir, "pods")
    File.mkdir_p!(pods_root)

    {principal_pubkey, _priv} = Signing.generate_keypair()

    {:ok,
     pods_root: pods_root,
     tmp_dir: tmp_dir,
     principal_pubkey: principal_pubkey,
     principal_uuid: UUID.uuid4()}
  end

  test "two deployments in separate pods: B resolves A's yield, and cannot without it", ctx do
    launcher = start_launcher!(ctx.pods_root)

    # ── DEPLOYMENT A ────────────────────────────────────────────────────────
    # A's projection carries no prior yield. A mints its own key, produces a
    # yield only it could produce, and signs it.
    a_repo = projection_repo!(ctx, "a", %{"role" => "producer", "prior_yield" => "", "principal" => ctx.principal_uuid})

    a = launch_deployment!(launcher, ctx, a_repo)
    a_report = await_report!(a, "deployment-report")

    assert a_report["role"] == "producer"
    a_pub = Base.decode64!(a_report["pod_public_key"])

    # A signed its own artifact with a key IT minted inside its pod.
    assert :crypto.verify(
             :eddsa,
             :none,
             a_report["yield"],
             Base.decode64!(a_report["signature"]),
             [a_pub, :ed25519]
           )

    # ── HOST INGEST ─────────────────────────────────────────────────────────
    # The runner is trusted; the pod is not. The host verifies A's signature
    # and only then admits the yield into B's projection.
    ingested_yield = a_report["yield"]
    assert byte_size(ingested_yield) > 0

    # ── DEPLOYMENT B ────────────────────────────────────────────────────────
    # ⭐ Built AFTER ingest, in a FRESH pod, with A's yield BY REFERENCE.
    b_repo = projection_repo!(ctx, "b", %{"role" => "resolver", "prior_yield" => ingested_yield, "principal" => ctx.principal_uuid})

    b = launch_deployment!(launcher, ctx, b_repo)
    b_report = await_report!(b, "deployment-report")

    assert b_report["role"] == "resolver"
    b_pub = Base.decode64!(b_report["pod_public_key"])

    # ⭐⭐ THE NEW GUARANTEE, asserted because it is no longer structural:
    # B shares no filesystem with A. On the host this was enforced by CubDB's
    # single-opener; two pods never contend, so it is asserted BY VALUE here.
    assert a.pod_home != b.pod_home
    assert checkout_dir(a) != checkout_dir(b)
    assert data_dir(a) != data_dir(b)
    assert home_dir(a) != home_dir(b)

    # ⭐ Different signers, ONE durable identity. Deliberately NOT "same
    # principal": that phrasing would make two deployments sharing a key read
    # as success.
    assert a_pub != b_pub
    assert a_report["principal"] == b_report["principal"]

    # ⭐⭐⭐ B RESOLVED A'S YIELD — a value B could not have computed.
    assert b_report["resolved_yield"] == ingested_yield

    assert :crypto.verify(
             :eddsa,
             :none,
             b_report["resolved_yield"],
             Base.decode64!(b_report["signature"]),
             [b_pub, :ed25519]
           )

    # ⛔⛔ THE MUST-FAIL CONTROL — I5's thesis, reproduced.
    # Same shape, same code, same custody: a resolver whose projection NEVER
    # SAW A's yield. If this SUCCEEDED, "B succeeded" above would not
    # distinguish reading from re-deriving.
    c_repo = projection_repo!(ctx, "c", %{"role" => "resolver", "prior_yield" => "", "principal" => ctx.principal_uuid})
    c = launch_deployment!(launcher, ctx, c_repo)
    c_report = await_report!(c, "deployment-report")

    assert c_report["role"] == "resolver"
    assert c_report["resolved_yield"] == "UNRESOLVED"
    refute c_report["resolved_yield"] == ingested_yield

    IO.puts("""
    TWO_DEPLOYMENT_POD_PROOF
      A pod_home        = #{a.pod_home}
      B pod_home        = #{b.pod_home}
      paths differ      = #{a.pod_home != b.pod_home}
      A pubkey != B     = #{a_pub != b_pub}
      one identity      = #{a_report["principal"] == b_report["principal"]}
      B resolved yield  = #{b_report["resolved_yield"] == ingested_yield}
      CONTROL (no A)    = #{c_report["resolved_yield"]}
    """)

    assert :ok = Launcher.reap(a)
    assert :ok = Launcher.reap(b)
    assert :ok = Launcher.reap(c)
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  # The PROJECTION: the runner materialises what the deployment needs into the
  # checkout it will be given. No new bind, no new provisioner surface — the
  # checkout directory already exists and is already writable.
  defp projection_repo!(ctx, name, projection) do
    repo = Path.join(ctx.tmp_dir, "projection-#{name}")
    File.mkdir_p!(repo)

    File.write!(
      Path.join(repo, "projection.txt"),
      Enum.map_join(projection, "\n", fn {k, v} -> "#{k}=#{v}" end) <> "\n"
    )

    File.write!(Path.join(repo, "deployment-worker.exs"), worker_source())

    git!(repo, ["init", "--quiet"])
    git!(repo, ["config", "user.email", "runner@example.invalid"])
    git!(repo, ["config", "user.name", "Runner Fixture"])
    git!(repo, ["add", "projection.txt", "deployment-worker.exs"])
    git!(repo, ["commit", "--quiet", "-m", "projection-#{name}"])

    %{path: repo, name: name, sha: git!(repo, ["rev-parse", "HEAD"])}
  end

  # Runs INSIDE the pod. Mints its own key, reads only its projection, and
  # signs what it produced. It never opens a store.
  defp worker_source do
    ~S"""
    data_dir = System.fetch_env!("COMMONPLACE_DATA_DIR")
    secrets_dir = Path.join(data_dir, "secrets")
    File.mkdir_p!(secrets_dir)

    projection =
      "projection.txt"
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Map.new(fn line ->
        [k, v] = String.split(line, "=", parts: 2)
        {k, v}
      end)

    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)
    key_path = Path.join(secrets_dir, "deployment_signing_key")
    File.write!(key_path, Base.encode64(private_key))
    File.chmod!(key_path, 0o600)
    stored_private = key_path |> File.read!() |> Base.decode64!()

    prior = Map.get(projection, "prior_yield", "")

    {payload, resolved} =
      case Map.fetch!(projection, "role") do
        "producer" ->
          y = Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
          {y, y}

        "resolver" ->
          # Resolve ONLY from the projection. Nothing is derivable here: an
          # absent prior yield must report UNRESOLVED rather than inventing one.
          if prior == "", do: {"UNRESOLVED", "UNRESOLVED"}, else: {prior, prior}
      end

    signature = :crypto.sign(:eddsa, :none, payload, [stored_private, :ed25519])

    report =
      [
        "schema=two-deployment-pod-v1",
        "role=" <> Map.fetch!(projection, "role"),
        "principal=" <> Map.fetch!(projection, "principal"),
        "pod_public_key=" <> Base.encode64(public_key),
        "yield=" <> payload,
        "resolved_yield=" <> resolved,
        "signature=" <> Base.encode64(signature)
      ]
      |> Enum.join("\n")

    tmp = Path.join(data_dir, "deployment-report.tmp")
    File.write!(tmp, report <> "\n")
    File.rename!(tmp, Path.join(data_dir, "deployment-report"))
    Process.sleep(300_000)
    """
  end

  defp launch_deployment!(launcher, ctx, repo) do
    # ⭐ The launcher refuses a second pod home for the same manifest id --
    # `{:invalid_manifest, "id", "pod home already exists for ..."}` -- so two
    # DEPLOYMENTS carry distinct deployment ids while sharing ONE principal.
    # That is the property under test, not a workaround: different signers, one
    # durable identity.
    assert {:ok, handle} =
             Launcher.launch(launcher, manifest(ctx, repo.name), profile(),
               repo: repo.path,
               sha: repo.sha,
               principal_pubkey: ctx.principal_pubkey,
               invocation: deployment_invocation()
             )

    handle
  end

  # The pod gets PATH=/usr/local/bin:/usr/bin:/bin, so `elixir` cannot find
  # `erl` on its own. Inject erl's directory explicitly, and constrain the BEAM
  # to one scheduler inside the sandbox.
  defp deployment_invocation do
    elixir = runtime_executable!("elixir")
    erl = runtime_executable!("erl")

    runtime_path =
      [Path.dirname(erl), "/usr/local/bin", "/usr/bin", "/bin"]
      |> Enum.uniq()
      |> Enum.join(":")

    [
      "/usr/bin/env",
      "PATH=#{runtime_path}",
      elixir,
      "--erl",
      "+S 1:1 +SDio 1 +SDcpu 1",
      "deployment-worker.exs"
    ]
  end

  defp await_report!(handle, name) do
    path = Path.join(data_dir(handle), name)
    assert {:ok, contents} = await_file(path)

    contents
    |> String.split("\n", trim: true)
    |> Map.new(fn line ->
      [k, v] = String.split(line, "=", parts: 2)
      {k, v}
    end)
  end

  defp data_dir(handle), do: Path.join([handle.pod_home, "workspace", ".commonplace"])
  defp checkout_dir(handle), do: Path.join(handle.pod_home, "checkout")
  defp home_dir(handle), do: Path.join(handle.pod_home, "home")

  defp start_launcher!(pods_root) do
    start_supervised!({Launcher, pods_root: pods_root, dedicated_runner_service: true})
  end

  defp manifest(ctx, deployment_id) do
    %{
      id: "deployment-#{deployment_id}",
      parent: "commonplace-factory",
      mission: "Two-deployment pod proof",
      principal: ctx.principal_uuid,
      workspace_class: "minimal",
      root_entries: [],
      authority: %{certs: [], authors_code: false, scope_note: nil},
      sync_scope: %{rule: "git-tracked-set", excludes: [".beads"], binary_extensions: [".png"]},
      sla: %{tier: "durable", retention: "indefinite", note: "pod-local"},
      environments: %{may_declare: false, requires_allowed: ["postgres"]},
      stewards: [ctx.principal_uuid],
      auditors: [UUID.uuid4()],
      escalate_to: "commonplace-factory",
      outputs: ["chits"],
      environment_faced: []
    }
  end

  defp profile do
    %Commonplace.Runner.PodProfile{
      id: "runner-local",
      harness: "commonplace-runner-v1",
      sandbox: "beam-isolate",
      services: %{"postgres" => "16.2"}
    }
  end

  defp runtime_executable!(name) do
    executable = System.find_executable(name) || flunk("#{name} executable is required")

    if Path.basename(Path.dirname(executable)) == "shims" do
      {resolved, 0} = System.cmd("asdf", ["which", name], stderr_to_stdout: true)
      String.trim(resolved)
    else
      executable
    end
  end

  defp await_file(path), do: await_file(path, System.monotonic_time(:millisecond) + 60_000)

  defp await_file(path, deadline) do
    cond do
      File.exists?(path) -> {:ok, File.read!(path)}
      System.monotonic_time(:millisecond) > deadline -> {:error, :timeout}
      true -> Process.sleep(100) && await_file(path, deadline)
    end
  end

  defp git!(repo, args) do
    {output, 0} = System.cmd("git", args, cd: repo, stderr_to_stdout: true)
    String.trim(output)
  end
end
