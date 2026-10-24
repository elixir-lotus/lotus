defmodule Lotus.Source.AdapterCapabilitiesTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Lotus.Query.Filter
  alias Lotus.Query.Statement
  alias Lotus.Source.Adapter
  alias Lotus.Source.Adapters.Ecto, as: EctoAdapter
  alias Lotus.Source.Resolvers.Static
  alias Mix.Tasks.Lotus.Adapter.Check

  defmodule CoreOnly do
    @moduledoc false
    @behaviour Lotus.Source.Adapter

    @impl true
    def execute_query(_state, _body, _params, _opts),
      do: {:ok, %{columns: [], rows: [], num_rows: 0}}

    @impl true
    def transaction(state, fun, _opts), do: {:ok, fun.(state)}
    @impl true
    def list_tables(_state, _schemas, _opts), do: {:ok, []}
    @impl true
    def describe_table(_state, _schema, _table), do: {:ok, []}
    @impl true
    def builtin_denies(_state), do: []
    @impl true
    def health_check(_state), do: :ok
    @impl true
    def disconnect(_state), do: :ok
    @impl true
    def format_error(_state, error), do: inspect(error)
    @impl true
    def source_type(_state), do: :other
  end

  # Implements Shaping's callbacks without declaring the behaviour, as an
  # adapter written against the flat 1.x behaviour does.
  defmodule UndeclaredShaping do
    @moduledoc false
    @behaviour Lotus.Source.Adapter

    @impl true
    def execute_query(_state, _body, _params, _opts),
      do: {:ok, %{columns: [], rows: [], num_rows: 0}}

    @impl true
    def transaction(state, fun, _opts), do: {:ok, fun.(state)}
    @impl true
    def list_tables(_state, _schemas, _opts), do: {:ok, []}
    @impl true
    def describe_table(_state, _schema, _table), do: {:ok, []}
    @impl true
    def builtin_denies(_state), do: []
    @impl true
    def health_check(_state), do: :ok
    @impl true
    def disconnect(_state), do: :ok
    @impl true
    def format_error(_state, error), do: inspect(error)
    @impl true
    def source_type(_state), do: :other

    def apply_filters(_state, %Statement{} = statement, _filters),
      do: %{statement | body: "filtered"}

    def supported_filter_operators(_state), do: [:eq]
  end

  defmodule DeclaredShaping do
    @moduledoc false
    @behaviour Lotus.Source.Adapter
    use Lotus.Test.AdapterDefaults, [:shaping]

    @impl true
    def execute_query(_state, _body, _params, _opts),
      do: {:ok, %{columns: [], rows: [], num_rows: 0}}

    @impl true
    def transaction(state, fun, _opts), do: {:ok, fun.(state)}
    @impl true
    def list_tables(_state, _schemas, _opts), do: {:ok, []}
    @impl true
    def describe_table(_state, _schema, _table), do: {:ok, []}
    @impl true
    def builtin_denies(_state), do: []
    @impl true
    def health_check(_state), do: :ok
    @impl true
    def disconnect(_state), do: :ok
    @impl true
    def format_error(_state, error), do: inspect(error)
    @impl true
    def source_type(_state), do: :other

    @impl true
    def apply_filters(_state, %Statement{} = statement, _filters),
      do: %{statement | body: "filtered"}
  end

  defp adapter(mod), do: %Adapter{name: "t", module: mod, state: nil, source_type: :other}

  @filters [Filter.new("id", :eq, 1)]

  describe "capabilities/1" do
    test "the built-in Ecto adapters declare every capability, and Postgres :session too" do
      all = Keyword.keys(Adapter.capability_behaviours())

      for mod <- [EctoAdapter | EctoAdapter.builtin_adapters()] do
        expected =
          if mod == Lotus.Source.Adapters.Postgres, do: all, else: all -- [:session]

        assert Adapter.capabilities(mod) == expected
      end
    end

    test "a core-only adapter has none" do
      assert Adapter.capabilities(CoreOnly) == []
      refute Adapter.capability?(CoreOnly, :shaping)
    end

    test "only declared behaviours count" do
      assert Adapter.capabilities(DeclaredShaping) == [:shaping]
      assert Adapter.capability?(adapter(DeclaredShaping), :shaping)
    end

    test "the :capabilities field wins over the module" do
      assert Adapter.capabilities(%{adapter(DeclaredShaping) | capabilities: []}) == []
    end
  end

  describe "with_capabilities/1" do
    test "fills the field from the module" do
      assert %Adapter{capabilities: [:shaping]} =
               Adapter.with_capabilities(adapter(DeclaredShaping))
    end

    test "keeps a field that is already set" do
      filled = %{adapter(DeclaredShaping) | capabilities: []}
      assert Adapter.with_capabilities(filled) == filled
    end

    test "Ecto wraps come with their capabilities" do
      assert %Adapter{capabilities: caps} = EctoAdapter.wrap("main", Lotus.Test.Repo)
      assert caps == Keyword.keys(Adapter.capability_behaviours())
    end

    test "the static resolver fills them" do
      assert %Adapter{capabilities: caps} = Static.get_source!("postgres")
      assert :shaping in caps
    end
  end

  describe "dispatch" do
    test "calls a declared capability's callbacks" do
      statement = Adapter.apply_filters(adapter(DeclaredShaping), Statement.new("x"), @filters)
      assert statement.body == "filtered"
    end

    test "ignores the callbacks of an undeclared capability and warns once" do
      log =
        capture_log(fn ->
          statement =
            Adapter.apply_filters(adapter(UndeclaredShaping), Statement.new("x"), @filters)

          assert statement.body == "x"

          assert Adapter.supported_filter_operators(adapter(UndeclaredShaping)) ==
                   Filter.operators() -- Filter.text_operators()
        end)

      assert log =~ "UndeclaredShaping exports Lotus.Source.Adapter.Shaping callbacks"
      assert log =~ "@behaviour Lotus.Source.Adapter.Shaping"

      assert capture_log(fn -> Adapter.capabilities(UndeclaredShaping) end) == ""
    end

    test "uses the struct's field instead of the module" do
      stripped = %{adapter(DeclaredShaping) | capabilities: []}
      assert Adapter.apply_filters(stripped, Statement.new("x"), @filters).body == "x"
    end
  end

  describe "mix lotus.adapter.check" do
    test "reports every capability of an Ecto adapter as declared" do
      report = Check.report(Lotus.Source.Adapters.Postgres)

      assert report.ok?
      assert report.core == :declared
      assert Enum.all?(report.capabilities, fn {_cap, status} -> status == :declared end)
    end

    test "passes a core-only adapter" do
      report = Check.report(CoreOnly)
      assert report.ok?
      assert Enum.all?(report.capabilities, fn {_cap, status} -> status == :absent end)
    end

    test "flags exported callbacks of an undeclared capability" do
      report = Check.report(UndeclaredShaping)

      refute report.ok?

      assert {:shaping, {:ignored, [apply_filters: 3, supported_filter_operators: 1]}} in report.capabilities

      assert Check.format(report) =~
               "shaping        not declared, ignores apply_filters/3, supported_filter_operators/1"
    end

    test "flags a module that is not an adapter or not loaded" do
      refute Check.report(Enum).ok?
      assert Check.report(Enum).core == :absent

      report = Check.report("Not.A.Module")
      refute report.ok?
      assert Check.format(report) =~ "not loaded"
    end
  end
end
