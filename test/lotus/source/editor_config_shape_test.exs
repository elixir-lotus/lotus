defmodule Lotus.Source.EditorConfigShapeTest do
  # async: false — we clear :persistent_term keys used for one-time
  # warning dedup so each test sees a fresh warn-state.
  use ExUnit.Case, async: false

  # Each test deliberately re-triggers the truncation warnings to cover
  # the logger branch; capture them so the suite output stays clean.
  @moduletag capture_log: true

  alias Lotus.Query.Statement
  alias Lotus.Source.Adapter

  # Minimal stub that delegates every required callback to a no-op so
  # we can exercise only the editor_config dispatch. Modules `use` this
  # and override `editor_config/1` to supply the specific shape under
  # test.
  defmodule StubBase do
    defmacro __using__(_opts) do
      quote do
        @behaviour Lotus.Source.Adapter

        @impl true
        def execute_query(_state, _sql, _params, _opts),
          do: {:ok, %{columns: [], rows: [], num_rows: 0}}

        @impl true
        def transaction(state, fun, _opts), do: {:ok, fun.(state)}

        @impl true
        def list_schemas(_state), do: {:ok, []}

        @impl true
        def list_tables(_state, _schemas, _opts), do: {:ok, []}

        @impl true
        def describe_table(_state, _schema, _table), do: {:ok, []}

        @impl true
        def resolve_table_namespace(_state, _table, _schemas), do: {:ok, nil}

        @impl true
        def quote_identifier(_state, ident), do: ~s("#{ident}")

        @impl true
        def apply_filters(_state, %Statement{} = s, _filters), do: s

        @impl true
        def apply_sorts(_state, %Statement{} = s, _sorts), do: s

        @impl true
        def query_plan(_state, _sql, _params, _opts), do: {:ok, nil}

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
        def format_error(_state, err), do: inspect(err)

        @impl true
        def handled_errors(_state), do: []

        @impl true
        def supports_feature?(_state, _feature), do: false

        @impl true
        def limit_query(_state, stmt, limit), do: "#{stmt} LIMIT #{limit}"

        @impl true
        def db_type_to_lotus_type(_state, _type), do: :text
      end
    end
  end

  defmodule NoisyAdapter do
    use StubBase

    @impl true
    def source_type(_state), do: :noisy

    # Deliberately oversized + polluted editor_config so the
    # dispatch-layer caps and unknown-key filter can be exercised.
    @impl true
    def editor_config(_state) do
      %{
        language: "sql:noisy",
        keywords: Enum.map(1..2500, &"KW#{&1}"),
        types: Enum.map(1..2500, &"T#{&1}"),
        functions: Enum.map(1..600, fn i -> %{name: "f#{i}", detail: "f#{i}()", args: "()"} end),
        context_boundaries: ["FROM", "WHERE"],
        context_schema: %{
          root: Enum.map(1..300, &"root#{&1}"),
          children: Map.new(1..700, fn i -> {"k#{i}", ["child"]} end)
        },
        # Unknown top-level keys — must be dropped.
        please_drop_me: "secrets",
        another_unknown: %{nested: true}
      }
    end
  end

  defmodule SmallAdapter do
    use StubBase

    @impl true
    def source_type(_state), do: :small

    @impl true
    def editor_config(_state) do
      %{
        language: "sql",
        keywords: ["SELECT", "FROM"],
        types: ["INTEGER"],
        functions: [%{name: "COUNT", detail: "COUNT()", args: "(*)"}],
        context_boundaries: ["FROM"]
      }
    end
  end

  setup do
    # Reset the one-time warning dedup state so repeated runs see fresh
    # truncations and hit the logger branch again.
    for field <- [
          :keywords,
          :types,
          :functions,
          :context_schema_root,
          :context_schema_children
        ] do
      key = {Adapter, :editor_config_warn, NoisyAdapter, field}
      :persistent_term.erase(key)
    end

    :ok
  end

  describe "dispatch-layer caps" do
    setup do
      {:ok,
       adapter: %Adapter{
         name: "noisy",
         module: NoisyAdapter,
         state: %{},
         source_type: :noisy
       }}
    end

    test "truncates keywords to 2000 entries", %{adapter: adapter} do
      config = Adapter.editor_config(adapter)
      assert length(config.keywords) == 2000
      assert Enum.at(config.keywords, 0) == "KW1"
      assert Enum.at(config.keywords, 1999) == "KW2000"
    end

    test "truncates types to 2000 entries", %{adapter: adapter} do
      assert length(Adapter.editor_config(adapter).types) == 2000
    end

    test "truncates functions to 500 entries", %{adapter: adapter} do
      config = Adapter.editor_config(adapter)
      assert length(config.functions) == 500
      assert Enum.at(config.functions, 0).name == "f1"
      assert Enum.at(config.functions, 499).name == "f500"
    end

    test "truncates context_schema.root to 200 entries", %{adapter: adapter} do
      assert length(Adapter.editor_config(adapter).context_schema.root) == 200
    end

    test "truncates context_schema.children to 500 entries", %{adapter: adapter} do
      assert map_size(Adapter.editor_config(adapter).context_schema.children) == 500
    end

    test "drops unknown top-level keys", %{adapter: adapter} do
      config = Adapter.editor_config(adapter)
      refute Map.has_key?(config, :please_drop_me)
      refute Map.has_key?(config, :another_unknown)
    end

    test "preserves all known top-level keys", %{adapter: adapter} do
      config = Adapter.editor_config(adapter)

      for key <- [
            :language,
            :keywords,
            :types,
            :functions,
            :context_boundaries,
            :context_schema
          ] do
        assert Map.has_key?(config, key), "lost known key: #{key}"
      end

      assert config.language == "sql:noisy"
    end
  end

  describe "well-shaped adapters pass through unchanged" do
    test "small editor_config is returned verbatim" do
      adapter = %Adapter{
        name: "small",
        module: SmallAdapter,
        state: %{},
        source_type: :small
      }

      config = Adapter.editor_config(adapter)

      assert config == %{
               language: "sql",
               keywords: ["SELECT", "FROM"],
               types: ["INTEGER"],
               functions: [%{name: "COUNT", detail: "COUNT()", args: "(*)"}],
               context_boundaries: ["FROM"]
             }
    end
  end
end
