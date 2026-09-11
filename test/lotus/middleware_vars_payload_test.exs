defmodule Lotus.MiddlewareVarsPayloadTest do
  @moduledoc """
  `:before_query` and `:after_query` plugs receive the bound query variables
  under `:vars`, so a plug can enforce rules on the values a caller picked
  (date-range limits, tenant checks) without parsing the statement.
  """

  use Lotus.Case

  alias Lotus.Middleware
  alias Lotus.Test.Schemas.User

  defmodule CaptureVarsPlug do
    @moduledoc false
    def init(opts), do: opts

    def call(%{vars: vars} = payload, event: event) do
      send(self(), {event, vars})
      {:cont, payload}
    end
  end

  defmodule MaxRangePlug do
    @moduledoc false
    def init(opts), do: opts

    def call(%{vars: %{"min_age" => min, "max_age" => max}} = payload, max_span: span) do
      if max - min <= span do
        {:cont, payload}
      else
        {:halt, "age range must be #{span} or less"}
      end
    end

    def call(payload, _opts), do: {:cont, payload}
  end

  setup do
    on_exit(fn -> :persistent_term.erase({Lotus.Middleware, :compiled}) end)

    Repo.insert!(%User{id: 1, name: "Ada", email: "ada@example.test", age: 36})
    Repo.insert!(%User{id: 2, name: "Grace", email: "grace@example.test", age: 85})

    {:ok, query} =
      Lotus.create_query(%{
        name: "Users by age",
        statement: "SELECT name FROM test_users WHERE age >= {{min_age}} AND age <= {{max_age}}",
        data_source: "postgres",
        variables: [
          %{name: "min_age", type: :number, default: "18"},
          %{name: "max_age", type: :number}
        ]
      })

    %{query: query}
  end

  test "both hooks see the merged variables: defaults plus supplied values", %{query: query} do
    Middleware.compile(%{
      before_query: [{CaptureVarsPlug, [event: :before]}],
      after_query: [{CaptureVarsPlug, [event: :after]}]
    })

    assert {:ok, _} = Lotus.run_query(query, vars: %{"max_age" => 40})

    assert_receive {:before, %{"min_age" => "18", "max_age" => 40}}
    assert_receive {:after, %{"min_age" => "18", "max_age" => 40}}
  end

  test "a raw statement carries an empty vars map" do
    Middleware.compile(%{before_query: [{CaptureVarsPlug, [event: :before]}]})

    assert {:ok, _} = Lotus.run_statement("SELECT 1", [], repo: "postgres")
    assert_receive {:before, vars}
    assert vars == %{}
  end

  test "a plug can halt on the variable values", %{query: query} do
    Middleware.compile(%{before_query: [{MaxRangePlug, [max_span: 10]}]})

    assert {:error, "age range must be 10 or less"} =
             Lotus.run_query(query, vars: %{"min_age" => 20, "max_age" => 90})

    assert {:ok, result} = Lotus.run_query(query, vars: %{"min_age" => 30, "max_age" => 40})
    assert result.rows == [["Ada"]]
  end
end
