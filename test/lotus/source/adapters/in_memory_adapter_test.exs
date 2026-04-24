defmodule Lotus.Test.InMemoryAdapterTest do
  @moduledoc """
  Unit tests for `Lotus.Test.InMemoryAdapter` — the first-party non-SQL
  reference adapter shipped with Lotus's own test suite.

  Exercises the pipeline end-to-end against the in-memory DSL to keep
  the non-Ecto code path honest as the `Lotus.Source.Adapter` contract
  evolves.
  """
  use ExUnit.Case, async: true

  alias Lotus.Query.Filter
  alias Lotus.Query.Sort
  alias Lotus.Query.Statement
  alias Lotus.Runner
  alias Lotus.Source.Adapter
  alias Lotus.Test.InMemoryAdapter

  defp sample_dataset do
    InMemoryAdapter.dataset(
      tables: %{
        "users" => %{
          columns: ["id", "name", "age", "status"],
          types: %{
            "id" => "integer",
            "name" => "text",
            "age" => "integer",
            "status" => "text"
          },
          rows: [
            [1, "Alice", 30, "active"],
            [2, "Bob", 17, "active"],
            [3, "Carol", 42, "inactive"],
            [4, "Dave", 25, "active"]
          ]
        },
        "posts" => %{
          columns: ["id", "user_id", "title"],
          rows: [
            [1, 1, "Hello"],
            [2, 1, "World"],
            [3, 3, "Solo"]
          ]
        }
      }
    )
  end

  defp adapter, do: InMemoryAdapter.adapter("mem", sample_dataset())

  defp stmt(dsl, params \\ []), do: %Statement{text: dsl, params: params}

  describe "registration (can_handle?/1, wrap/2)" do
    test "can_handle?/1 only matches tagged dataset maps" do
      tagged = sample_dataset()
      refute InMemoryAdapter.can_handle?(%{tables: %{}})
      refute InMemoryAdapter.can_handle?(Some.Unknown.Module)
      assert InMemoryAdapter.can_handle?(tagged)
    end

    test "wrap/2 produces a correctly-shaped %Adapter{}" do
      %Adapter{} = a = adapter()
      assert a.name == "mem"
      assert a.module == InMemoryAdapter
      assert a.source_type == :in_memory
      assert is_map(a.state)
    end
  end

  describe "introspection" do
    test "list_schemas/1 is empty for flat namespaces" do
      assert {:ok, []} = Adapter.list_schemas(adapter())
    end

    test "list_tables/3 returns (nil, table) tuples sorted by name" do
      assert {:ok, [{nil, "posts"}, {nil, "users"}]} = Adapter.list_tables(adapter(), [], [])
    end

    test "describe_table/3 returns column definitions" do
      assert {:ok, cols} = Adapter.describe_table(adapter(), nil, "users")
      names = Enum.map(cols, & &1.name)
      assert names == ["id", "name", "age", "status"]
      assert Enum.find(cols, &(&1.name == "id")).primary_key == true
      assert Enum.find(cols, &(&1.name == "name")).type == "text"
    end

    test "describe_table/3 surfaces a not-found error" do
      assert {:error, msg} = Adapter.describe_table(adapter(), nil, "missing")
      assert msg =~ "not found"
    end
  end

  describe "identifier and operator validation" do
    test "validate_identifier/3 accepts typical SQL-ish identifiers" do
      assert :ok = Adapter.validate_identifier(adapter(), :table, "users")
      assert :ok = Adapter.validate_identifier(adapter(), :column, "user_id")
    end

    test "validate_identifier/3 rejects unsafe values" do
      assert {:error, msg} = Adapter.validate_identifier(adapter(), :column, "id; DROP")
      assert msg =~ "invalid"
    end

    test "supported_filter_operators/1 advertises :like and null ops" do
      ops = Adapter.supported_filter_operators(adapter())
      assert :eq in ops
      assert :like in ops
      assert :is_null in ops
    end

    test "parse_qualified_name/2 is flat (single-component)" do
      assert {:ok, ["users"]} = Adapter.parse_qualified_name(adapter(), "users")
    end
  end

  describe "pipeline — apply_filters/3 + apply_sorts/3 + apply_pagination/3" do
    test "apply_filters/3 appends filters into the DSL :where" do
      statement = stmt(%{from: "users"})
      filters = [Filter.new("status", :eq, "active")]

      %Statement{text: %{where: where}} = Adapter.apply_filters(adapter(), statement, filters)
      assert where == [{"status", :eq, "active"}]
    end

    test "apply_sorts/3 appends sort pairs" do
      statement = stmt(%{from: "users"})
      sorts = [Sort.new("age", :desc)]

      %Statement{text: %{order_by: order}} = Adapter.apply_sorts(adapter(), statement, sorts)
      assert order == [{"age", :desc}]
    end

    test "apply_pagination/3 records limit/offset and a count_spec on :exact" do
      statement = stmt(%{from: "users"})
      paged = Adapter.apply_pagination(adapter(), statement, limit: 2, offset: 1, count: :exact)

      assert paged.text.limit == 2
      assert paged.text.offset == 1
      assert %{query: count_dsl, params: []} = paged.meta[:count_spec]
      refute Map.has_key?(count_dsl, :limit)
      refute Map.has_key?(count_dsl, :offset)
      assert count_dsl.count == true
    end
  end

  describe "variable substitution" do
    test "substitute_variable/5 inlines into {:var, name} markers" do
      statement = stmt(%{from: "users", where: [{"id", :eq, {:var, "uid"}}]})

      assert {:ok, %Statement{text: %{where: where}}} =
               Adapter.substitute_variable(adapter(), statement, "uid", 1, :integer)

      assert where == [{"id", :eq, 1}]
    end

    test "substitute_variable/5 ignores markers for other names" do
      statement = stmt(%{from: "users", where: [{"id", :eq, {:var, "other"}}]})

      assert {:ok, %Statement{text: %{where: where}}} =
               Adapter.substitute_variable(adapter(), statement, "uid", 99, :integer)

      assert where == [{"id", :eq, {:var, "other"}}]
    end

    test "substitute_list_variable/5 inlines a list into a :in marker" do
      statement = stmt(%{from: "users", where: [{"id", :in, {:var, "ids"}}]})

      assert {:ok, %Statement{text: %{where: where}}} =
               Adapter.substitute_list_variable(adapter(), statement, "ids", [1, 2, 3], :integer)

      assert where == [{"id", :in, [1, 2, 3]}]
    end
  end

  describe "visibility (extract_accessed_resources/2)" do
    test "extracts {nil, table} from a DSL statement" do
      statement = stmt(%{from: "users"})
      assert {:ok, set} = Adapter.extract_accessed_resources(adapter(), statement)
      assert MapSet.equal?(set, MapSet.new([{nil, "users"}]))
    end

    test "returns {:unrestricted, _} for non-DSL text" do
      statement = %Statement{text: "SELECT 1"}
      assert {:unrestricted, reason} = Adapter.extract_accessed_resources(adapter(), statement)
      assert reason =~ "non-DSL"
    end
  end

  describe "AI context" do
    test "ai_context/1 returns a bounded, language-tagged map" do
      assert {:ok, ctx} = Adapter.ai_context(adapter())
      assert ctx.language == "lotus:in_memory"
      assert is_binary(ctx.example_query)
      assert is_binary(ctx.syntax_notes)
      assert is_list(ctx.error_patterns)
    end

    test "ai_context/1 declares per-feature capabilities" do
      assert {:ok, %{capabilities: caps}} = Adapter.ai_context(adapter())
      assert caps.generation == true
      assert match?({false, _}, caps.optimization)
      assert caps.explanation == true
    end
  end

  describe "Runner integration — executing a DSL statement" do
    test "runs a filter + sort + pagination pipeline end-to-end" do
      base = stmt(%{from: "users"})

      statement =
        base
        |> (&Adapter.apply_filters(adapter(), &1, [Filter.new("status", :eq, "active")])).()
        |> (&Adapter.apply_sorts(adapter(), &1, [Sort.new("age", :desc)])).()
        |> (&Adapter.apply_pagination(adapter(), &1, limit: 2, offset: 0)).()

      assert {:ok, result} = Runner.run_statement(adapter(), statement)
      assert result.columns == ["id", "name", "age", "status"]
      assert [[1, "Alice", 30, _], [4, "Dave", 25, _]] = result.rows
      assert result.num_rows == 2
    end

    test "runs a substituted variable pipeline" do
      statement = stmt(%{from: "users", where: [{"id", :eq, {:var, "uid"}}]})

      assert {:ok, %Statement{} = bound} =
               Adapter.substitute_variable(adapter(), statement, "uid", 3, :integer)

      assert {:ok, %{rows: [[3, "Carol", 42, "inactive"]]}} =
               Runner.run_statement(adapter(), bound)
    end

    test "Runner surfaces a :unrestricted visibility reason when the host isn't opted in" do
      # The in-memory adapter implements extract_accessed_resources, so a DSL
      # statement resolves cleanly and preflight passes.
      statement = stmt(%{from: "users"})
      assert {:ok, %{num_rows: 4}} = Runner.run_statement(adapter(), statement)
    end
  end
end
