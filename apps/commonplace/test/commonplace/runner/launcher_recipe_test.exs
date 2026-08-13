defmodule Commonplace.Runner.LauncherRecipeTest do
  use ExUnit.Case, async: false

  alias Commonplace.Crypto.Signing
  alias Commonplace.Runner.{Launcher, PodProfile, RunRecipe}

  setup_all do
    started? =
      Enum.any?(Application.started_applications(), fn {application, _description, _version} ->
        application == :commonplace
      end)

    unless started? do
      data_dir = Path.join(System.tmp_dir!(), "cp_launcher_recipe_app_#{UUID.uuid4()}")
      previous_data_dir = Application.fetch_env(:commonplace, :data_dir)
      Application.put_env(:commonplace, :data_dir, data_dir)

      on_exit(fn ->
        :ok = Application.stop(:commonplace)
        restore_application_env(:commonplace, :data_dir, previous_data_dir)
        File.rm_rf!(data_dir)
      end)

      {:ok, _started} = Application.ensure_all_started(:commonplace)
    end

    :ok
  end

  setup do
    fixture_root = Path.join(System.tmp_dir!(), "cp_launcher_recipe_#{UUID.uuid4()}")
    source_repo = Path.join(fixture_root, "source")
    pods_root = Path.join(fixture_root, "pods")
    File.mkdir_p!(source_repo)
    File.mkdir_p!(pods_root)

    write_worker(source_repo, "worker-one.sh", "effect-from-run-one")
    write_worker(source_repo, "worker-two.sh", "effect-from-run-two")

    recipe = %{
      "setup" => [
        "printf 'setup-finished\\n' > \"$COMMONPLACE_DATA_DIR/setup-effect\""
      ],
      "run" => "./worker-one.sh",
      "port" => 4_000,
      "env" => ["COMMONPLACE_DATA_DIR", "PATH"],
      "ready" => "/ready",
      "requires" => %{"postgres" => ">=14"}
    }

    File.write!(Path.join(source_repo, "recipe-one.json"), Jason.encode!(recipe))

    File.write!(
      Path.join(source_repo, "recipe-two.json"),
      Jason.encode!(%{recipe | "run" => "./worker-two.sh"})
    )

    git!(source_repo, ["init", "--quiet"])
    git!(source_repo, ["config", "user.email", "launcher-recipe@example.invalid"])
    git!(source_repo, ["config", "user.name", "Launcher Recipe Fixture"])
    git!(source_repo, ["add", "."])
    git!(source_repo, ["commit", "--quiet", "-m", "fixture"])

    {principal_pubkey, _principal_private_key} = Signing.generate_keypair()

    on_exit(fn -> File.rm_rf!(fixture_root) end)

    %{
      source_repo: source_repo,
      pods_root: pods_root,
      sha: git!(source_repo, ["rev-parse", "HEAD"]),
      principal_uuid: UUID.uuid4(),
      principal_pubkey: principal_pubkey
    }
  end

  test "changing only recipe run changes the observed worker effect", ctx do
    launcher = start_supervised!({Launcher, pods_root: ctx.pods_root})
    recipe_one = read_recipe!(Path.join(ctx.source_repo, "recipe-one.json"))
    recipe_two = read_recipe!(Path.join(ctx.source_repo, "recipe-two.json"))

    assert %{recipe_one | run: recipe_two.run} == recipe_two

    handle_one = launch_recipe!(launcher, ctx, recipe_one)
    assert {:ok, "effect-from-run-one\n"} = await_file(effect_path(handle_one))
    assert File.read!(setup_path(handle_one)) == "setup-finished\n"
    assert :ok = Launcher.reap(handle_one)

    handle_two = launch_recipe!(launcher, ctx, recipe_two)
    assert {:ok, "effect-from-run-two\n"} = await_file(effect_path(handle_two))
    assert File.read!(setup_path(handle_two)) == "setup-finished\n"
    assert :ok = Launcher.reap(handle_two)
  end

  test "recipe env names resolve only from the constructed placement allowlist", ctx do
    launcher = start_supervised!({Launcher, pods_root: ctx.pods_root})
    recipe = read_recipe!(Path.join(ctx.source_repo, "recipe-one.json"))

    handle = launch_recipe!(launcher, ctx, recipe)
    assert {:ok, "COMMONPLACE_DATA_DIR\nPATH\nPWD\n"} = await_file(environment_path(handle))
    assert :ok = Launcher.reap(handle)
    assert pod_homes(ctx.pods_root) == []

    unavailable = %{recipe | env: recipe.env ++ ["RECIPE_VALUE_FROM_NOWHERE"]}

    assert {:refused,
            [
              "this placement does not supply declared environment variable " <>
                "RECIPE_VALUE_FROM_NOWHERE"
            ]} =
             Launcher.launch_recipe(
               launcher,
               manifest(ctx),
               profile(),
               unavailable,
               launch_opts(ctx)
             )

    assert pod_homes(ctx.pods_root) == []
  end

  test "recipe requires gates placement before launch, with a satisfying control", ctx do
    launcher = start_supervised!({Launcher, pods_root: ctx.pods_root})
    recipe = read_recipe!(Path.join(ctx.source_repo, "recipe-one.json"))

    satisfying_handle = launch_recipe!(launcher, ctx, recipe)
    assert {:ok, "effect-from-run-one\n"} = await_file(effect_path(satisfying_handle))
    assert :ok = Launcher.reap(satisfying_handle)
    assert pod_homes(ctx.pods_root) == []

    refusing = %{recipe | requires: %{"postgres" => ">=17"}}

    assert {:refused, ["this placement cannot satisfy requirement postgres >=17"]} =
             Launcher.launch_recipe(
               launcher,
               manifest(ctx),
               profile(),
               refusing,
               launch_opts(ctx)
             )

    assert pod_homes(ctx.pods_root) == []
  end

  defp write_worker(source_repo, name, effect) do
    File.write!(
      Path.join(source_repo, name),
      """
      #!/bin/sh
      test "$(cat "$COMMONPLACE_DATA_DIR/setup-effect")" = "setup-finished"
      env | cut -d= -f1 | sort > "$COMMONPLACE_DATA_DIR/recipe-environment.tmp"
      mv "$COMMONPLACE_DATA_DIR/recipe-environment.tmp" "$COMMONPLACE_DATA_DIR/recipe-environment"
      printf '#{effect}\\n' > "$COMMONPLACE_DATA_DIR/recipe-effect.tmp"
      mv "$COMMONPLACE_DATA_DIR/recipe-effect.tmp" "$COMMONPLACE_DATA_DIR/recipe-effect"
      sleep 300
      """
    )

    File.chmod!(Path.join(source_repo, name), 0o755)
  end

  defp launch_recipe!(launcher, ctx, recipe) do
    assert {:ok, handle} =
             Launcher.launch_recipe(launcher, manifest(ctx), profile(), recipe, launch_opts(ctx))

    handle
  end

  defp launch_opts(ctx) do
    [repo: ctx.source_repo, sha: ctx.sha, principal_pubkey: ctx.principal_pubkey]
  end

  defp read_recipe!(path) do
    assert {:ok, %{case: :present, recipe: recipe}} = RunRecipe.read(path)
    recipe
  end

  defp manifest(ctx) do
    %{
      id: "cell-launched-from-recipe",
      parent: "commonplace-factory",
      mission: "Execute a runner recipe in a pod",
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
    %PodProfile{
      id: "runner-local",
      harness: "commonplace-runner-v1",
      sandbox: "beam-isolate",
      services: %{"postgres" => "16.2"}
    }
  end

  defp effect_path(handle), do: Path.join(data_dir(handle), "recipe-effect")
  defp setup_path(handle), do: Path.join(data_dir(handle), "setup-effect")
  defp environment_path(handle), do: Path.join(data_dir(handle), "recipe-environment")
  defp data_dir(handle), do: Path.join([handle.pod_home, "workspace", ".commonplace"])

  defp pod_homes(pods_root) do
    pods_root
    |> File.ls!()
    |> Enum.reject(&(&1 == ".runner.lock"))
  end

  defp await_file(path), do: await_file(path, System.monotonic_time(:millisecond) + 60_000)

  defp await_file(path, deadline) do
    case File.read(path) do
      {:ok, contents} ->
        {:ok, contents}

      {:error, :enoent} ->
        if System.monotonic_time(:millisecond) < deadline do
          receive do
          after
            10 -> await_file(path, deadline)
          end
        else
          {:error, :timeout}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp git!(repo, args) do
    {output, 0} = System.cmd("git", args, cd: repo, stderr_to_stdout: true)
    String.trim(output)
  end

  defp restore_application_env(application, key, {:ok, value}),
    do: Application.put_env(application, key, value)

  defp restore_application_env(application, key, :error),
    do: Application.delete_env(application, key)
end
