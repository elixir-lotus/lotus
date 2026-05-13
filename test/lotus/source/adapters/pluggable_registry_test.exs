defmodule Lotus.Source.Adapters.PluggableRegistryTest do
  @moduledoc """
  Tests the pluggable adapter registry: custom adapters registered via
  `source_adapters` config are discovered by `can_handle?/1` and produce
  correct `%Adapter{}` structs via `wrap/2`.
  """
  use Lotus.Case, async: true
  use Mimic

  alias Lotus.Config
  alias Lotus.Source.Adapter
  alias Lotus.Source.Resolvers.Static

  # A custom adapter that handles a specific module
  defmodule CustomAdapter do
    @behaviour Lotus.Source.Adapter

    @impl true
    @custom_source Lotus.Source.Adapters.PluggableRegistryTest.CustomSource
    def can_handle?(mod) when is_atom(mod), do: mod == @custom_source
    def can_handle?(_), do: false

    @impl true
    def wrap(name, source) do
      %Adapter{name: name, module: __MODULE__, state: source, source_type: :custom}
    end

    # Minimal stubs for required callbacks
    @impl true
    def execute_query(_, _, _, _), do: {:error, :not_implemented}
    @impl true
    def transaction(_, _, _), do: {:error, :not_implemented}
    @impl true
    def list_schemas(_), do: {:ok, []}
    @impl true
    def list_tables(_, _, _), do: {:ok, []}
    @impl true
    def describe_table(_, _, _), do: {:ok, []}
    @impl true
    def resolve_table_namespace(_, _, _), do: {:ok, nil}
    @impl true
    def quote_identifier(_, id), do: ~s("#{id}")
    @impl true
    def apply_filters(_, statement, _), do: statement
    @impl true
    def apply_sorts(_, statement, _), do: statement
    @impl true
    def query_plan(_, _, _, _), do: {:ok, "plan"}
    @impl true
    def builtin_denies(_), do: []
    @impl true
    def builtin_schema_denies(_), do: []
    @impl true
    def default_schemas(_), do: []
    @impl true
    def health_check(_), do: :ok
    @impl true
    def disconnect(_), do: :ok
    @impl true
    def format_error(_, e), do: inspect(e)
    @impl true
    def handled_errors(_), do: []
    @impl true
    def source_type(_), do: :custom
    @impl true
    def supports_feature?(_, _), do: false
    @impl true
    def limit_query(_, statement, _limit), do: statement
    @impl true
    def db_type_to_lotus_type(_, _), do: :text
    @impl true
    def editor_config(_),
      do: %{language: "", keywords: [], types: [], functions: [], context_boundaries: []}
  end

  # A non-Ecto source module (no __adapter__/0)
  defmodule CustomSource do
    def name, do: "custom"
  end

  setup :verify_on_exit!

  setup do
    Mimic.copy(Config)
    :ok
  end

  defp stub_config_with_custom do
    sources = %{"custom" => CustomSource, "postgres" => Lotus.Test.Repo}

    stub(Config, :source_adapters, fn -> [CustomAdapter] end)
    stub(Config, :data_sources, fn -> sources end)
    stub(Config, :default_data_source, fn -> {"postgres", Lotus.Test.Repo} end)
    stub(Config, :list_data_source_names, fn -> Map.keys(sources) end)

    stub(Config, :get_data_source!, fn name ->
      case Map.get(sources, name) do
        nil -> raise ArgumentError, "Data source '#{name}' not configured."
        mod -> mod
      end
    end)
  end

  describe "custom adapter via source_adapters config" do
    test "can_handle?/1 returns true for matching source" do
      assert CustomAdapter.can_handle?(CustomSource)
    end

    test "can_handle?/1 returns false for non-matching source" do
      refute CustomAdapter.can_handle?(Lotus.Test.Repo)
    end

    test "wrap/2 creates correct Adapter struct" do
      adapter = CustomAdapter.wrap("custom", CustomSource)

      assert %Adapter{} = adapter
      assert adapter.name == "custom"
      assert adapter.module == CustomAdapter
      assert adapter.state == CustomSource
      assert adapter.source_type == :custom
    end

    test "Static resolver discovers custom adapter from source_adapters config" do
      stub_config_with_custom()

      adapters = Static.list_sources()
      custom = Enum.find(adapters, &(&1.name == "custom"))

      assert %Adapter{} = custom
      assert custom.module == CustomAdapter
      assert custom.source_type == :custom
      assert custom.state == CustomSource
    end

    test "custom adapter takes precedence over builtin Ecto fallback" do
      stub_config_with_custom()

      adapter = Static.get_source!("custom")

      # Should be wrapped by CustomAdapter, not EctoAdapter
      assert adapter.module == CustomAdapter
      assert adapter.source_type == :custom
    end

    test "resolve/2 finds custom adapter by name" do
      stub_config_with_custom()

      assert {:ok, adapter} = Static.resolve("custom", nil)
      assert adapter.module == CustomAdapter
      assert adapter.source_type == :custom
    end

    test "Adapter dispatch works through custom adapter" do
      adapter = CustomAdapter.wrap("custom", CustomSource)

      assert Adapter.source_type(adapter) == :custom
      assert Adapter.supports_feature?(adapter, :anything) == false
      assert {:ok, []} = Adapter.list_schemas(adapter)
    end
  end

  # End-to-end adapter: implements execute_query with canned responses and a
  # no-op transaction wrapper, so we can drive Lotus.run_statement/3 through a
  # non-Ecto adapter and prove the full pipeline (sanitize → preflight →
  # transaction → execute_query → Result assembly) works without touching
  # Ecto anywhere.
  defmodule EchoAdapter do
    @behaviour Lotus.Source.Adapter

    @impl true
    def can_handle?(:echo_source), do: true
    def can_handle?(_), do: false

    @impl true
    def wrap(name, source) do
      %Adapter{name: name, module: __MODULE__, state: source, source_type: :echo}
    end

    # The real work: echo the statement back as a row so tests can assert
    # the pipeline delivered the statement unchanged.
    @impl true
    def execute_query(:echo_source, statement, params, _opts) do
      {:ok,
       %{
         columns: ["statement", "param_count"],
         rows: [[statement, length(params)]],
         num_rows: 1
       }}
    end

    @impl true
    def transaction(:echo_source = state, fun, _opts) do
      {:ok, fun.(state)}
    rescue
      e -> {:error, Exception.message(e)}
    end

    # Discovery / introspection — enough for the pipeline not to crash.
    @impl true
    def list_schemas(_), do: {:ok, ["default"]}
    @impl true
    def list_tables(_, _, _), do: {:ok, [{nil, "messages"}]}
    @impl true
    def describe_table(_, _, _), do: {:ok, []}
    @impl true
    def resolve_table_namespace(_, _, _), do: {:ok, nil}

    # SQL-generation stubs — trivial because the pipeline runs them even for
    # non-SQL adapters when no filters/sorts are supplied.
    @impl true
    def quote_identifier(_, id), do: id
    @impl true
    def apply_filters(_, statement, _), do: statement
    @impl true
    def apply_sorts(_, statement, _), do: statement
    @impl true
    def query_plan(_, _, _, _), do: {:ok, "echo-plan"}

    # Echo adapter has no real relations — return an empty set so preflight
    # passes without needing the :allow_unrestricted_resources opt-in.
    @impl true
    def extract_accessed_resources(_, _statement), do: {:ok, MapSet.new()}
    @impl true
    def builtin_denies(_), do: []
    @impl true
    def builtin_schema_denies(_), do: []
    @impl true
    def default_schemas(_), do: ["default"]
    @impl true
    def health_check(_), do: :ok
    @impl true
    def disconnect(_), do: :ok
    @impl true
    def format_error(_, e), do: inspect(e)
    @impl true
    def handled_errors(_), do: []
    @impl true
    def source_type(_), do: :echo
    @impl true
    def supports_feature?(_, _), do: false
    @impl true
    def limit_query(_, statement, _limit), do: statement
    @impl true
    def db_type_to_lotus_type(_, _), do: :text

    @impl true
    def editor_config(_),
      do: %{language: "echo", keywords: [], types: [], functions: [], context_boundaries: []}
  end

  describe "end-to-end query execution through a non-Ecto adapter" do
    setup do
      sources = %{"echo" => :echo_source, "postgres" => Lotus.Test.Repo}

      stub(Config, :source_adapters, fn -> [EchoAdapter] end)
      stub(Config, :data_sources, fn -> sources end)
      stub(Config, :default_data_source, fn -> {"postgres", Lotus.Test.Repo} end)
      stub(Config, :list_data_source_names, fn -> Map.keys(sources) end)

      stub(Config, :get_data_source!, fn name ->
        case Map.get(sources, name) do
          nil -> raise ArgumentError, "Data source '#{name}' not configured."
          mod -> mod
        end
      end)

      :ok
    end

    test "Lotus.run_statement/3 routes through the custom adapter's execute_query" do
      # cache: :bypass so we observe a fresh adapter call and the assertion
      # isn't accidentally satisfied by a cache hit from a sibling test.
      assert {:ok, result} =
               Lotus.run_statement(
                 "echo:hello",
                 [1, 2, 3],
                 repo: "echo",
                 cache: :bypass
               )

      assert result.columns == ["statement", "param_count"]
      assert result.rows == [["echo:hello", 3]]
      assert result.num_rows == 1
    end

    test "filters and sorts pass through to the non-Ecto adapter's callbacks" do
      # EchoAdapter's apply_filters/apply_sorts are passthroughs, so this
      # proves the pipeline invokes them without needing SQL semantics.
      assert {:ok, result} =
               Lotus.run_statement(
                 "echo:filtered",
                 [],
                 repo: "echo",
                 filters: [],
                 sorts: [],
                 cache: :bypass
               )

      assert [["echo:filtered", 0]] = result.rows
    end
  end
end
