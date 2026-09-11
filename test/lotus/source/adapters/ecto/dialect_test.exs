defmodule Lotus.Source.Adapters.Ecto.DialectTest do
  @moduledoc """
  The Dialect behaviour is a published extension point that external dialect
  libraries implement from outside this repo. These tests pin the parts of the
  contract those dialects depend on.
  """

  use ExUnit.Case, async: true

  alias Lotus.Source.Adapters.Ecto.Dialect

  describe "published contract" do
    test "the behaviour carries documentation for adapter authors" do
      {:docs_v1, _, :elixir, _, moduledoc, _, _} = Code.fetch_docs(Dialect)

      assert %{"en" => text} = moduledoc
      assert text =~ "Dialect"
    end
  end

  describe "session hooks are optional" do
    defmodule MinimalDialect do
      @moduledoc false
      @behaviour Dialect

      alias Lotus.Query.Statement

      @impl true
      def execute_in_transaction(_repo, fun, _opts), do: {:ok, fun.()}

      @impl true
      def format_error(error), do: inspect(error)

      @impl true
      def quote_identifier(id), do: ~s("#{id}")

      @impl true
      def param_placeholder(index, _var, _type), do: "$#{index}"

      @impl true
      def limit_offset_placeholders(limit_index, offset_index),
        do: {"$#{limit_index}", "$#{offset_index}"}

      @impl true
      def apply_filters(statement, _filters), do: statement

      @impl true
      def apply_sorts(statement, _sorts), do: statement

      @impl true
      def query_plan(_repo, %Statement{}, _opts), do: {:ok, nil}

      @impl true
      def builtin_denies(_repo), do: []

      @impl true
      def builtin_schema_denies(_repo), do: []

      @impl true
      def default_schemas(_repo), do: []

      @impl true
      def list_schemas(_repo), do: []

      @impl true
      def list_tables(_repo, _schemas, _include_views?), do: []

      @impl true
      def describe_table(_repo, _schema, _table), do: []

      @impl true
      def resolve_table_namespace(_repo, _table, _schemas), do: nil

      @impl true
      def source_type, do: :other

      @impl true
      def ecto_adapter, do: __MODULE__

      @impl true
      def query_language, do: "minimal"

      @impl true
      def limit_query(statement, _limit), do: statement
    end

    test "a dialect compiles without set_statement_timeout/2 or set_search_path/2" do
      refute function_exported?(MinimalDialect, :set_statement_timeout, 2)
      refute function_exported?(MinimalDialect, :set_search_path, 2)
    end

    test "both hooks are declared optional on the behaviour" do
      optional = Dialect.behaviour_info(:optional_callbacks)

      assert {:set_statement_timeout, 2} in optional
      assert {:set_search_path, 2} in optional
    end
  end
end
