defmodule Lotus.RunQuerySourceResolutionTest do
  use Lotus.Case, async: true
  use Mimic

  alias Lotus.Source
  alias Lotus.Source.Resolvers.Static
  alias Lotus.Storage.{Query, QueryVariable}

  setup :verify_on_exit!

  test "run_query/2 resolves the data source once per run" do
    expect(Source, :resolve!, fn source_opt, q_source ->
      {:ok, adapter} = Static.resolve(source_opt, q_source)
      adapter
    end)

    query = %Query{
      name: "Resolved Once",
      statement: "SELECT {{n}} AS n",
      data_source: "postgres",
      variables: [%QueryVariable{name: "n", type: :number}]
    }

    assert {:ok, %Lotus.Result{num_rows: 1}} = Lotus.run_query(query, vars: %{"n" => 1})
  end

  test "run_query/2 rejects a language mismatch before compiling the statement" do
    query = %Query{
      name: "Mismatch Before Compile",
      statement: "SELECT {{missing}} AS n",
      data_source: "sqlite",
      query_language: "sql:postgres",
      variables: []
    }

    assert {:error, msg} = Lotus.run_query(query)
    assert msg =~ "sql:sqlite"
    refute msg =~ "Missing required variable"
  end
end
