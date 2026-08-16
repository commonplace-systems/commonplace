defmodule Commonplace.Cell.DeclarationTest do
  use ExUnit.Case, async: true

  alias Commonplace.Cell.Declaration
  alias Commonplace.Crypto.Signing

  setup do
    {public_key, _private_key} = Signing.generate_keypair()

    %{
      valid: %{
        "child_uuid" => UUID.uuid4(),
        "name" => "platform-watch",
        "public_key" => Signing.encode_key(public_key)
      }
    }
  end

  test "a complete public identity declaration round-trips", %{valid: valid} do
    assert :ok = Declaration.validate(valid)
    assert {:ok, encoded} = Declaration.encode(valid)

    assert {:ok,
            %Declaration{
              child_uuid: child_uuid,
              name: "platform-watch",
              public_key: public_key
            }} = Declaration.decode(encoded)

    assert child_uuid == valid["child_uuid"]
    assert public_key == valid["public_key"]
  end

  test "a missing identity field is refused with the field named", %{valid: valid} do
    assert {:error, {:invalid_declaration, "child_uuid", "is required"}} =
             valid
             |> Map.delete("child_uuid")
             |> Declaration.validate()
  end

  test "an invalid public key is refused with the field named", %{valid: valid} do
    assert {:error, {:invalid_declaration, "public_key", "must be an encoded public key"}} =
             valid
             |> Map.put("public_key", "not-a-public-key")
             |> Declaration.validate()
  end

  test "an unknown field is refused with the field named", %{valid: valid} do
    assert {:error, {:invalid_declaration, "status", "is not a recognized field"}} =
             valid
             |> Map.put("status", "active")
             |> Declaration.validate()
  end

  test "invalid JSON is refused as a declaration" do
    assert {:error, {:invalid_declaration, "declaration", "must be valid JSON"}} =
             Declaration.decode("not-json")
  end
end
