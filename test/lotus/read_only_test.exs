defmodule Lotus.ReadOnlyTest do
  @moduledoc """
  Whether statements may write, per data source: a call's `read_only:`, then
  the source's own `read_only` field, then `:data_source_read_only`, then the
  global `:read_only`.
  """
  # Changes the application env.
  use Lotus.Case, async: false
  use Mimic

  alias Lotus.AI.Actions.ExecuteStatement
  alias Lotus.{Config, Settings}
  alias Lotus.Source.Adapters.Ecto, as: EctoAdapter
  alias Lotus.Storage.Query
  alias Lotus.Test.Repo

  @write "UPDATE test_users SET age = age WHERE false"

  defmodule Answers do
    @moduledoc false
    @behaviour Lotus.Settings

    @impl true
    def get(key), do: :persistent_term.get({__MODULE__, key}, :default)
  end

  setup do
    previous = Application.get_all_env(:lotus)

    on_exit(fn ->
      for key <- Settings.overridable(), do: :persistent_term.erase({Answers, key})

      for key <- [:read_only, :data_source_read_only, :settings, :source_resolver] do
        case Keyword.fetch(previous, key) do
          {:ok, value} -> Application.put_env(:lotus, key, value)
          :error -> Application.delete_env(:lotus, key)
        end
      end

      Config.reload!()
    end)
  end

  defp configure(env) do
    Enum.each(env, fn {key, value} -> Application.put_env(:lotus, key, value) end)
    Config.reload!()
  end

  defp source(read_only), do: %{EctoAdapter.wrap("postgres", Repo) | read_only: read_only}

  defp refused?({:error, message}) when is_binary(message),
    do: message =~ "read-only" or message =~ "read only"

  defp refused?(_result), do: false

  describe "Lotus.Config.read_only?/1" do
    test "follows the global setting by default" do
      assert Config.read_only?("postgres")
      assert Config.read_only?(source(nil))

      configure(read_only: false)
      refute Config.read_only?("postgres")
      refute Config.read_only?(source(nil))
    end

    test ":data_source_read_only goes over the global setting" do
      configure(read_only: true, data_source_read_only: %{"postgres" => false})
      refute Config.read_only?("postgres")
      assert Config.read_only?("mysql")

      configure(read_only: false, data_source_read_only: %{"postgres" => true})
      assert Config.read_only?("postgres")
      refute Config.read_only?("mysql")
    end

    test "the source's own field goes over the config" do
      configure(read_only: true, data_source_read_only: %{"postgres" => true})
      refute Config.read_only?(source(false))

      configure(read_only: false, data_source_read_only: %{"postgres" => false})
      assert Config.read_only?(source(true))
    end

    test "a name asks the resolver for the source's own field" do
      configure(source_resolver: __MODULE__.FalseResolver)
      refute Config.read_only?("postgres")
    end

    test "a name the resolver does not know follows the config" do
      configure(data_source_read_only: %{"gone" => false})
      refute Config.read_only?("gone")
      assert Config.read_only?("unknown")
    end

    test "Lotus.Settings answers :data_source_read_only at run time" do
      configure(settings: Answers)
      assert Config.read_only?("postgres")

      :persistent_term.put({Answers, :data_source_read_only}, {:ok, %{"postgres" => false}})
      refute Config.read_only?("postgres")
      assert Config.read_only?("mysql")

      assert {:ok, %{"x" => true}} = Settings.validate(:data_source_read_only, %{"x" => true})
      assert {:error, _} = Settings.validate(:data_source_read_only, %{"x" => "yes"})
    end

    test "the config is validated" do
      assert_raise ArgumentError, ~r/data_source_read_only/, fn ->
        Config.load!(storage_repo: Repo, data_source_read_only: %{"postgres" => "no"})
      end
    end

    test "Lotus.read_only?/1 answers for a source name" do
      assert Lotus.read_only?("postgres")
      configure(data_source_read_only: %{"postgres" => false})
      refute Lotus.read_only?("postgres")
    end
  end

  describe "running statements" do
    test "a source configured writable runs a write without read_only:" do
      assert refused?(Lotus.run_statement(@write))

      configure(data_source_read_only: %{"postgres" => false})
      assert {:ok, %{num_rows: 0}} = Lotus.run_statement(@write)
    end

    test "a source configured read-only refuses a write when writes are allowed globally" do
      configure(read_only: false, data_source_read_only: %{"postgres" => true})
      assert refused?(Lotus.run_statement(@write))
    end

    test "the call's read_only: goes over the source's setting" do
      configure(data_source_read_only: %{"postgres" => false})
      assert refused?(Lotus.run_statement(@write, [], read_only: true))

      configure(data_source_read_only: %{"postgres" => true})
      assert {:ok, _} = Lotus.run_statement(@write, [], read_only: false)
    end

    test "the source's own field decides, as a resolver sets it" do
      stub(Lotus.Source, :resolve!, fn _source, _fallback -> source(false) end)
      assert {:ok, _} = Lotus.run_statement(@write)

      stub(Lotus.Source, :resolve!, fn _source, _fallback -> source(true) end)
      configure(read_only: false)
      assert refused?(Lotus.run_statement(@write))
    end

    test "a saved query run follows the source's setting" do
      query = %Query{name: "w", statement: @write, data_source: "postgres", variables: []}
      assert refused?(Lotus.run_query(query))

      configure(data_source_read_only: %{"postgres" => false})
      assert {:ok, _} = Lotus.run_query(query)
    end

    test "a stream follows the source's setting" do
      fun = fn chunks -> Enum.to_list(chunks) end
      assert refused?(Lotus.stream_statement(@write, [], [], fun))

      configure(data_source_read_only: %{"postgres" => false})
      assert {:ok, _chunks} = Lotus.stream_statement(@write, [], [], fun)
    end

    test "the paths that pass read_only: true stay read-only on a writable source" do
      configure(data_source_read_only: %{"postgres" => false})

      assert {:ok, %{error: message}} =
               ExecuteStatement.run(
                 %{statement: @write, data_source: "postgres", label: "write"},
                 %{}
               )

      assert message =~ "read-only"
    end
  end

  describe "dashboards" do
    import Lotus.Fixtures

    alias Lotus.Dashboards

    setup do
      configure(data_source_read_only: %{"postgres" => false})
      query = query_fixture(%{statement: @write, data_source: "postgres"})
      dashboard = dashboard_fixture()
      card = dashboard_card_fixture(dashboard, %{card_type: :query, query_id: query.id})
      %{dashboard: dashboard, card: card}
    end

    test "a card runs read-only on a source that takes writes", %{card: card} do
      assert refused?(Dashboards.run_dashboard_card(card))
      assert refused?(Dashboards.run_dashboard_card(card, read_only: false))
    end

    test "a dashboard's cards run read-only", %{dashboard: dashboard, card: card} do
      for parallel <- [true, false] do
        results = Dashboards.run_dashboard(dashboard, parallel: parallel, read_only: false)
        assert refused?(results[card.id])
      end
    end
  end

  defmodule FalseResolver do
    @moduledoc false
    def resolve(name, _fallback) do
      {:ok, %{EctoAdapter.wrap(name, Repo) | read_only: false}}
    end
  end
end
