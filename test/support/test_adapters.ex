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
  def query_plan(_state, _statement, _opts), do: {:ok, ""}
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
  def query_plan(_state, _statement, _opts), do: {:ok, ""}
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
  def source_type(_state), do: :other
  @impl true
  def supports_feature?(_state, _feature), do: false
  @impl true
  def db_type_to_lotus_type(_state, _db_type), do: :text
  @impl true
  def editor_config(_state),
    do: %{language: "", keywords: [], types: [], functions: [], context_boundaries: []}
end

defmodule Lotus.Test.LifecycleAdapter do
  @moduledoc false
  @behaviour Lotus.Source.Adapter

  alias Lotus.Source.Adapter
  alias Lotus.Source.Registry

  @shared_name __MODULE__.Shared

  def shared_name, do: @shared_name

  def failing_start, do: {:error, :refused}

  @impl true
  def wrap(name, %{} = state) do
    %Adapter{name: name, module: __MODULE__, state: state, source_type: :other}
  end

  @impl true
  def shared_children do
    [%{id: :shared, start: {Agent, :start_link, [fn -> :shared end, [name: @shared_name]]}}]
  end

  @impl true
  def source_children(_name, %{children: :none}), do: []

  def source_children(_name, %{children: :failing}) do
    [%{id: :worker, start: {__MODULE__, :failing_start, []}}]
  end

  def source_children(name, state) do
    [
      %{
        id: :worker,
        start: {Agent, :start_link, [fn -> state end, [name: Registry.via(__MODULE__, name)]]}
      }
    ]
  end

  @impl true
  def source_started(_name, %{started: :raise}), do: raise("started hook failed")

  def source_started(name, %{owner: owner}) do
    send(owner, {:source_started, name})
    :ok
  end

  @impl true
  def source_stopped(name, %{owner: owner}) do
    send(owner, {:source_stopped, name})
    :ok
  end

  @impl true
  def extract_accessed_resources(_state, _statement), do: {:unrestricted, "test adapter"}
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
  def query_plan(_state, _statement, _opts), do: {:ok, ""}
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

defmodule Lotus.Test.LifecycleResolver do
  @moduledoc false
  @behaviour Lotus.Source.Resolver

  @key {__MODULE__, :sources}

  def put_sources(adapters), do: :persistent_term.put(@key, adapters)

  def clear, do: :persistent_term.erase(@key)

  @impl true
  def list_sources do
    case :persistent_term.get(@key, []) do
      :raise -> raise "resolver is not ready"
      adapters -> adapters
    end
  end

  @impl true
  def resolve(name, fallback) do
    case Enum.find(list_sources(), &(&1.name in [name, fallback])) do
      nil -> {:error, :not_found}
      adapter -> {:ok, adapter}
    end
  end

  @impl true
  def get_source!(name) do
    case resolve(name, nil) do
      {:ok, adapter} -> adapter
      {:error, :not_found} -> raise ArgumentError, "unknown source #{inspect(name)}"
    end
  end

  @impl true
  def list_source_names, do: Enum.map(list_sources(), & &1.name)

  @impl true
  def default_source do
    adapter = hd(list_sources())
    {adapter.name, adapter}
  end
end
