defmodule Lotus.AI.Actions.ListDataSourcesTest do
  use Lotus.AICase, async: true

  alias Lotus.AI.Actions.ListDataSources

  describe "run/2" do
    test "returns available data sources with types" do
      stub(Lotus, :list_data_source_names, fn -> ["primary", "analytics"] end)

      stub(Lotus.Source, :source_type, fn
        "primary" -> :postgres
        "analytics" -> :postgres
      end)

      assert {:ok, result} = ListDataSources.run(%{}, %{})

      assert result.data_sources == [
               %{name: "primary", type: :postgres},
               %{name: "analytics", type: :postgres}
             ]
    end

    test "returns empty list when no data sources configured" do
      stub(Lotus, :list_data_source_names, fn -> [] end)

      assert {:ok, result} = ListDataSources.run(%{}, %{})
      assert result.data_sources == []
    end
  end

  describe "tool metadata" do
    test "exposes name, description, and empty schema" do
      assert ListDataSources.name() == "list_data_sources"
      assert ListDataSources.description() =~ "data sources"
      assert ListDataSources.schema() == []
    end
  end
end
