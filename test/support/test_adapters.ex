defmodule Lotus.Test.NoOpAdapter do
  @moduledoc false
  @behaviour Lotus.Source.Adapter

  @impl true
  def extract_accessed_resources(_state, _statement),
    do: {:unrestricted, "test no-op adapter"}

  @impl true
  def execute_query(_state, _sql, _params, _opts), do: {:error, "not implemented"}
  @impl true
  def transaction(_state, _fun, _opts), do: {:error, "not implemented"}
  @impl true
  def list_schemas(_state), do: {:ok, []}
  @impl true
  def list_tables(_state, _schemas, _opts), do: {:ok, []}
  @impl true
  def describe_table(_state, _schema, _table), do: {:ok, []}
  @impl true
  def resolve_table_namespace(_state, _table, _schemas), do: {:ok, nil}
  @impl true
  def quote_identifier(_state, id), do: ~s("#{id}")
  @impl true
  def apply_filters(_state, statement, _filters), do: statement
  @impl true
  def apply_sorts(_state, statement, _sorts), do: statement
  @impl true
  def query_plan(_state, _sql, _params, _opts), do: {:ok, ""}
  @impl true
  def builtin_denies(_state), do: []
  @impl true
  def builtin_schema_denies(_state), do: []
  @impl true
  def default_schemas(_state), do: []
  @impl true
  def health_check(_state), do: :ok
  @impl true
  def disconnect(_state), do: :ok
  @impl true
  def format_error(_state, error), do: inspect(error)
  @impl true
  def handled_errors(_state), do: []
  @impl true
  def source_type(_state), do: :other
  @impl true
  def supports_feature?(_state, _feature), do: false
  @impl true
  def limit_query(_state, statement, _limit), do: statement
  @impl true
  def db_type_to_lotus_type(_state, _db_type), do: :text
  @impl true
  def editor_config(_state),
    do: %{language: "", keywords: [], types: [], functions: [], context_boundaries: []}
end

defmodule Lotus.Test.StubAdapter do
  @moduledoc false
  @behaviour Lotus.Source.Adapter

  @impl true
  def execute_query(_state, _sql, _params, _opts), do: {:error, "not implemented"}
  @impl true
  def transaction(_state, _fun, _opts), do: {:error, "not implemented"}
  @impl true
  def list_schemas(_state), do: {:ok, []}
  @impl true
  def list_tables(_state, _schemas, _opts), do: {:ok, []}
  @impl true
  def describe_table(_state, _schema, _table), do: {:ok, []}
  @impl true
  def resolve_table_namespace(_state, _table, _schemas), do: {:ok, nil}
  @impl true
  def quote_identifier(_state, id), do: ~s("#{id}")
  @impl true
  def apply_filters(_state, statement, _filters), do: statement
  @impl true
  def apply_sorts(_state, statement, _sorts), do: statement
  @impl true
  def query_plan(_state, _sql, _params, _opts), do: {:ok, ""}
  @impl true
  def builtin_denies(_state), do: []
  @impl true
  def builtin_schema_denies(_state), do: []
  @impl true
  def default_schemas(_state), do: []
  @impl true
  def health_check(_state), do: :ok
  @impl true
  def disconnect(_state), do: :ok
  @impl true
  def format_error(_state, error), do: inspect(error)
  @impl true
  def handled_errors(_state), do: []
  @impl true
  def source_type(_state), do: :other
  @impl true
  def supports_feature?(_state, _feature), do: false
  @impl true
  def limit_query(_state, statement, _limit), do: statement
  @impl true
  def db_type_to_lotus_type(_state, _db_type), do: :text
  @impl true
  def editor_config(_state),
    do: %{language: "", keywords: [], types: [], functions: [], context_boundaries: []}
end
