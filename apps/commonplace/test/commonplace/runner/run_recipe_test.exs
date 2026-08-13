defmodule Commonplace.Runner.RunRecipeTest do
  use ExUnit.Case, async: true

  alias Commonplace.Runner.{PodProfile, RunRecipe}

  @valid_recipe %{
    "setup" => ["mix deps.get", "mix ecto.setup"],
    "run" => "mix phx.server",
    "port" => 4000,
    "env" => ["DATABASE_URL", "SECRET_KEY_BASE"],
    "ready" => "/health",
    "requires" => %{"postgres" => ">=14"}
  }

  test "a complete six-field recipe validates and every field round-trips" do
    assert :ok = RunRecipe.validate(@valid_recipe)
    assert {:ok, encoded} = RunRecipe.encode(@valid_recipe)

    assert {:ok,
            %RunRecipe{
              setup: ["mix deps.get", "mix ecto.setup"],
              run: "mix phx.server",
              port: 4000,
              env: ["DATABASE_URL", "SECRET_KEY_BASE"],
              ready: "/health",
              requires: %{"postgres" => ">=14"}
            }} = RunRecipe.decode(encoded)
  end

  test "an env value is refused with env named" do
    recipe = %{@valid_recipe | "env" => %{"DATABASE_URL" => "postgres://secret"}}

    assert {:error, {:invalid_recipe, "env", "must contain names only; values are forbidden"}} =
             RunRecipe.validate(recipe)
  end

  test "an unparseable requirement is refused with requires named" do
    recipe = %{@valid_recipe | "requires" => %{"postgres" => "eventually"}}

    assert {:error,
            {:invalid_recipe, "requires",
             "must contain non-empty service names and valid versions"}} =
             RunRecipe.validate(recipe)
  end

  test "a missing required field is refused with the field named" do
    assert {:error, {:invalid_recipe, "run", "is required"}} =
             @valid_recipe
             |> Map.delete("run")
             |> RunRecipe.validate()
  end

  test "an unknown seventh field is refused with the field named" do
    assert {:error, {:invalid_recipe, "path", "is not a recognized field"}} =
             @valid_recipe
             |> Map.put("path", ".commonplace/run-recipe.json")
             |> RunRecipe.validate()
  end

  test "recipe requirements satisfy or refuse against the placement inventory" do
    requires = @valid_recipe["requires"]

    satisfying_profile = %PodProfile{
      id: "runner-with-postgres",
      harness: "commonplace-runner-v1",
      sandbox: "beam-isolate",
      services: %{"postgres" => "16.2"}
    }

    refusing_profile = %PodProfile{
      id: "runner-without-postgres",
      harness: "commonplace-runner-v1",
      sandbox: "beam-isolate",
      services: %{}
    }

    assert :ok = PodProfile.match_requires(requires, satisfying_profile)

    assert {:refused, ["this placement cannot satisfy requirement postgres >=14"]} =
             PodProfile.match_requires(requires, refusing_profile)
  end
end
