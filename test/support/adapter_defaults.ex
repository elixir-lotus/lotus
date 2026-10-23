defmodule Lotus.Test.AdapterDefaults do
  @moduledoc false
  # Declares capability behaviours on a test adapter and fills each callback
  # the adapter leaves out with the value `Lotus.Source.Adapter` would use for
  # an adapter without the capability. A test adapter then writes only the
  # callbacks its test exercises:
  #
  #     @behaviour Lotus.Source.Adapter
  #     use Lotus.Test.AdapterDefaults, [:shaping, :editor]

  alias Lotus.Query.Filter

  def filter_operators, do: Filter.operators() -- Filter.text_operators()

  defmacro __using__(capabilities) when is_list(capabilities) do
    for capability <- capabilities, do: defaults(capability)
  end

  defp defaults(:introspection) do
    quote do
      @behaviour Lotus.Source.Adapter.Introspection

      def list_schemas(_state), do: {:ok, []}
      def resolve_table_namespace(_state, _table, _schemas), do: {:ok, nil}
      def default_schemas(_state), do: []
      def builtin_schema_denies(_state), do: []
      def hierarchy_label(_state), do: "Tables"
      def parse_qualified_name(_state, name), do: {:ok, [name]}
      def validate_identifier(_state, _kind, _value), do: :ok

      defoverridable Lotus.Source.Adapter.Introspection
    end
  end

  defp defaults(:preflight) do
    quote do
      @behaviour Lotus.Source.Adapter.Preflight

      def extract_accessed_resources(_state, _statement), do: {:unrestricted, "test adapter"}
      def needs_preflight?(_state, _statement), do: true
      def sanitize_query(_state, _statement, _opts), do: :ok
      def query_plan(_state, _statement, _opts), do: {:ok, nil}
      def validate_statement(_state, _statement, _opts), do: :ok
      def prepare_for_analysis(_state, _statement), do: {:error, :unsupported}

      defoverridable Lotus.Source.Adapter.Preflight
    end
  end

  defp defaults(:binding) do
    quote do
      @behaviour Lotus.Source.Adapter.Binding

      def transform_statement(_state, statement), do: statement
      def substitute_variable(_state, _statement, _var, _value, _type), do: {:error, :unsupported}

      def substitute_list_variable(_state, _statement, _var, _values, _type),
        do: {:error, :unsupported}

      def transform_bound_query(_state, statement, _opts), do: statement
      def db_type_to_lotus_type(_state, _db_type), do: :text

      defoverridable Lotus.Source.Adapter.Binding
    end
  end

  defp defaults(:shaping) do
    quote do
      @behaviour Lotus.Source.Adapter.Shaping

      def apply_filters(_state, statement, _filters), do: statement
      def apply_sorts(_state, statement, _sorts), do: statement
      def apply_pagination(_state, statement, _opts), do: statement
      def limit_query(_state, statement, _limit), do: statement

      def supported_filter_operators(_state), do: unquote(__MODULE__).filter_operators()

      def quote_identifier(_state, identifier), do: identifier

      defoverridable Lotus.Source.Adapter.Shaping
    end
  end

  defp defaults(:editor) do
    quote do
      @behaviour Lotus.Source.Adapter.Editor

      def editor_config(_state),
        do: %{language: "", keywords: [], types: [], functions: [], context_boundaries: []}

      def query_language(_state), do: "sql"
      def example_query(_state, table, _schema), do: "SELECT value_column FROM #{table}"
      def ai_context(_state), do: {:error, :ai_not_supported}

      defoverridable Lotus.Source.Adapter.Editor
    end
  end
end
