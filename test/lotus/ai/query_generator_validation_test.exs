defmodule Lotus.AI.QueryGeneratorValidationTest do
  use Lotus.Case, async: true

  alias Lotus.AI.QueryGenerator

  describe "validate_key/1" do
    test "accepts valid non-empty string" do
      assert :ok = QueryGenerator.validate_key(%{api_key: "sk-test123"})
    end

    test "accepts any non-empty string" do
      assert :ok = QueryGenerator.validate_key(%{api_key: "anything-non-empty"})
    end

    test "rejects empty string" do
      assert {:error, _} = QueryGenerator.validate_key(%{api_key: ""})
    end

    test "rejects nil" do
      assert {:error, _} = QueryGenerator.validate_key(%{api_key: nil})
    end
  end
end
