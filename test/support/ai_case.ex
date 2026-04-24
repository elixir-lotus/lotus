defmodule Lotus.AICase do
  @moduledoc """
  Test case template for AI module tests.

  Provides common setup for testing AI providers with Mimic mocks.

  ## Usage

      defmodule Lotus.AI.SomeTest do
        use Lotus.AICase, async: true

        test "generates SQL" do
          mock_successful_generation()
          # Test code...
        end
      end
  """

  use ExUnit.CaseTemplate

  using opts do
    async = Keyword.get(opts, :async, false)

    quote do
      use Lotus.Case, async: unquote(async)

      import Mimic
      import Lotus.AIFixtures
      import Lotus.ReqLLMMocks

      setup :verify_on_exit!

      # Mock Lotus.Schema calls for schema introspection
      setup do
        Mimic.copy(Lotus.Schema)
        Mimic.copy(Lotus.Source)
        Mimic.copy(Lotus.Source.Adapter)

        stub(Lotus.Source.Adapter, :validate_statement, fn _adapter, _statement, _opts ->
          {:error, "syntax error"}
        end)

        :ok
      end
    end
  end
end
