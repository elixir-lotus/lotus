defmodule Lotus.Storage.DashboardTest do
  use Lotus.Case, async: true

  alias Lotus.Dashboards.DateToken

  alias Lotus.Storage.{
    Dashboard,
    DashboardCard,
    DashboardCardFilterMapping,
    DashboardFilter
  }

  describe "Dashboard schema" do
    test "creates dashboard with valid attributes" do
      changeset = Dashboard.new(%{name: "Sales Dashboard"})
      assert changeset.valid?
    end

    test "requires name" do
      changeset = Dashboard.new(%{})
      refute changeset.valid?
      assert %{name: ["can't be blank"]} = errors_on(changeset)
    end

    test "validates name length (min 1, max 255)" do
      # Empty name
      changeset = Dashboard.new(%{name: ""})
      refute changeset.valid?
      assert %{name: [msg]} = errors_on(changeset)
      assert msg =~ "blank" or msg =~ "at least"

      # Name too long
      long_name = String.duplicate("a", 256)
      changeset = Dashboard.new(%{name: long_name})
      refute changeset.valid?
      assert %{name: [msg]} = errors_on(changeset)
      assert msg =~ "at most"

      # Valid length
      valid_name = String.duplicate("a", 255)
      changeset = Dashboard.new(%{name: valid_name})
      assert changeset.valid?
    end

    test "validates auto_refresh_seconds range (60-3600)" do
      # Too low
      changeset = Dashboard.new(%{name: "Test", auto_refresh_seconds: 30})
      refute changeset.valid?
      assert %{auto_refresh_seconds: [msg]} = errors_on(changeset)
      assert msg =~ "between 60 and 3600"

      # Too high
      changeset = Dashboard.new(%{name: "Test", auto_refresh_seconds: 7200})
      refute changeset.valid?

      # Valid minimum
      changeset = Dashboard.new(%{name: "Test", auto_refresh_seconds: 60})
      assert changeset.valid?

      # Valid maximum
      changeset = Dashboard.new(%{name: "Test", auto_refresh_seconds: 3600})
      assert changeset.valid?

      # Valid nil (disabled)
      changeset = Dashboard.new(%{name: "Test", auto_refresh_seconds: nil})
      assert changeset.valid?
    end

    test "accepts optional description" do
      changeset = Dashboard.new(%{name: "Test", description: "A test dashboard"})
      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :description) == "A test dashboard"
    end

    test "normalizes settings to string keys" do
      changeset = Dashboard.new(%{name: "Test", settings: %{theme: "dark", layout: "grid"}})
      assert changeset.valid?
      settings = Ecto.Changeset.get_field(changeset, :settings)
      assert settings == %{"theme" => "dark", "layout" => "grid"}
    end

    test "defaults settings to empty map" do
      changeset = Dashboard.new(%{name: "Test"})
      assert Ecto.Changeset.get_field(changeset, :settings) == %{}
    end

    test "update/2 creates changeset for updates" do
      dashboard = %Dashboard{id: 1, name: "Original"}
      changeset = Dashboard.update(dashboard, %{name: "Updated"})
      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :name) == "Updated"
    end
  end

  describe "DashboardCard schema" do
    test "creates card with valid attributes" do
      changeset =
        DashboardCard.new(%{
          dashboard_id: 1,
          card_type: :query,
          query_id: 1,
          position: 0
        })

      assert changeset.valid?
    end

    test "requires dashboard_id, card_type, and position" do
      changeset = DashboardCard.new(%{})
      refute changeset.valid?
      errors = errors_on(changeset)
      assert "can't be blank" in errors[:dashboard_id]
      assert "can't be blank" in errors[:card_type]
      assert "can't be blank" in errors[:position]
    end

    test "validates card_type enum values" do
      for type <- [:query, :text, :link, :heading] do
        changeset =
          DashboardCard.new(%{
            dashboard_id: 1,
            card_type: type,
            position: 0,
            query_id: if(type == :query, do: 1, else: nil)
          })

        assert changeset.valid?, "Expected #{type} to be valid"
      end
    end

    test "requires query_id for query cards" do
      changeset =
        DashboardCard.new(%{
          dashboard_id: 1,
          card_type: :query,
          position: 0
        })

      refute changeset.valid?
      assert %{query_id: ["is required for query cards"]} = errors_on(changeset)
    end

    test "rejects query_id for non-query cards" do
      changeset =
        DashboardCard.new(%{
          dashboard_id: 1,
          card_type: :text,
          query_id: 1,
          position: 0
        })

      refute changeset.valid?
      assert %{query_id: ["must be nil for non-query cards"]} = errors_on(changeset)
    end

    test "validates position is non-negative" do
      changeset =
        DashboardCard.new(%{
          dashboard_id: 1,
          card_type: :text,
          position: -1
        })

      refute changeset.valid?
      assert %{position: [msg]} = errors_on(changeset)
      assert msg =~ "greater than or equal to"
    end

    test "validates title length" do
      long_title = String.duplicate("a", 256)

      changeset =
        DashboardCard.new(%{
          dashboard_id: 1,
          card_type: :text,
          position: 0,
          title: long_title
        })

      refute changeset.valid?
      assert %{title: [msg]} = errors_on(changeset)
      assert msg =~ "at most"
    end

    test "normalizes visualization_config to string keys" do
      changeset =
        DashboardCard.new(%{
          dashboard_id: 1,
          card_type: :query,
          query_id: 1,
          position: 0,
          visualization_config: %{chart: "bar", x: %{field: "date"}}
        })

      assert changeset.valid?
      config = Ecto.Changeset.get_field(changeset, :visualization_config)
      assert config == %{"chart" => "bar", "x" => %{"field" => "date"}}
    end

    test "normalizes content to string keys" do
      changeset =
        DashboardCard.new(%{
          dashboard_id: 1,
          card_type: :text,
          position: 0,
          content: %{text: "Hello", format: "markdown"}
        })

      assert changeset.valid?
      content = Ecto.Changeset.get_field(changeset, :content)
      assert content == %{"text" => "Hello", "format" => "markdown"}
    end
  end

  describe "DashboardCard.Layout embedded schema" do
    test "sets default layout values" do
      changeset =
        DashboardCard.new(%{
          dashboard_id: 1,
          card_type: :text,
          position: 0,
          layout: %{}
        })

      assert changeset.valid?
      layout = Ecto.Changeset.get_field(changeset, :layout)
      assert layout.x == 0
      assert layout.y == 0
      assert layout.w == 6
      assert layout.h == 4
    end

    test "validates x position (0-11)" do
      changeset =
        DashboardCard.new(%{
          dashboard_id: 1,
          card_type: :text,
          position: 0,
          layout: %{x: 12}
        })

      refute changeset.valid?
      assert %{layout: %{x: [msg]}} = errors_on(changeset)
      assert msg =~ "less than"
    end

    test "validates y position is non-negative" do
      changeset =
        DashboardCard.new(%{
          dashboard_id: 1,
          card_type: :text,
          position: 0,
          layout: %{y: -1}
        })

      refute changeset.valid?
      assert %{layout: %{y: [msg]}} = errors_on(changeset)
      assert msg =~ "greater than or equal to"
    end

    test "validates width (1-12)" do
      # Width 0
      changeset =
        DashboardCard.new(%{
          dashboard_id: 1,
          card_type: :text,
          position: 0,
          layout: %{w: 0}
        })

      refute changeset.valid?

      # Width 13
      changeset =
        DashboardCard.new(%{
          dashboard_id: 1,
          card_type: :text,
          position: 0,
          layout: %{w: 13}
        })

      refute changeset.valid?
    end

    test "validates height minimum is 1" do
      changeset =
        DashboardCard.new(%{
          dashboard_id: 1,
          card_type: :text,
          position: 0,
          layout: %{h: 0}
        })

      refute changeset.valid?
      assert %{layout: %{h: [msg]}} = errors_on(changeset)
      assert msg =~ "greater than"
    end

    test "validates card does not extend beyond grid" do
      # x=8, w=6 means x+w=14 > 12
      changeset =
        DashboardCard.new(%{
          dashboard_id: 1,
          card_type: :text,
          position: 0,
          layout: %{x: 8, w: 6}
        })

      refute changeset.valid?
      assert %{layout: %{w: [msg]}} = errors_on(changeset)
      assert msg =~ "extends beyond grid"
    end
  end

  describe "DashboardFilter schema" do
    test "creates filter with valid attributes" do
      changeset =
        DashboardFilter.new(%{
          dashboard_id: 1,
          name: "date_filter",
          label: "Select Date",
          filter_type: :date,
          widget: :date_picker,
          position: 0
        })

      assert changeset.valid?
    end

    test "requires all mandatory fields" do
      changeset = DashboardFilter.new(%{})
      refute changeset.valid?
      errors = errors_on(changeset)
      assert "can't be blank" in errors[:dashboard_id]
      assert "can't be blank" in errors[:name]
      assert "can't be blank" in errors[:label]
      assert "can't be blank" in errors[:filter_type]
      assert "can't be blank" in errors[:widget]
      assert "can't be blank" in errors[:position]
    end

    test "validates name format (identifier)" do
      # Invalid - starts with number
      changeset =
        DashboardFilter.new(%{
          dashboard_id: 1,
          name: "1invalid",
          label: "Test",
          filter_type: :text,
          widget: :input,
          position: 0
        })

      refute changeset.valid?
      assert %{name: [msg]} = errors_on(changeset)
      assert msg =~ "valid identifier"

      # Invalid - contains spaces
      changeset =
        DashboardFilter.new(%{
          dashboard_id: 1,
          name: "invalid name",
          label: "Test",
          filter_type: :text,
          widget: :input,
          position: 0
        })

      refute changeset.valid?

      # Valid - with underscores
      changeset =
        DashboardFilter.new(%{
          dashboard_id: 1,
          name: "valid_name_123",
          label: "Test",
          filter_type: :text,
          widget: :input,
          position: 0
        })

      assert changeset.valid?
    end

    test "validates filter_type enum values" do
      for type <- [:text, :number, :date, :date_range, :select] do
        widget =
          case type do
            :date -> :date_picker
            :date_range -> :date_range_picker
            :select -> :select
            _ -> :input
          end

        changeset =
          DashboardFilter.new(%{
            dashboard_id: 1,
            name: "filter",
            label: "Filter",
            filter_type: type,
            widget: widget,
            position: 0
          })

        assert changeset.valid?, "Expected filter_type #{type} to be valid"
      end
    end

    test "validates widget type compatibility" do
      # text + input = valid
      changeset =
        DashboardFilter.new(%{
          dashboard_id: 1,
          name: "filter",
          label: "Filter",
          filter_type: :text,
          widget: :input,
          position: 0
        })

      assert changeset.valid?

      # text + date_picker = invalid
      changeset =
        DashboardFilter.new(%{
          dashboard_id: 1,
          name: "filter",
          label: "Filter",
          filter_type: :text,
          widget: :date_picker,
          position: 0
        })

      refute changeset.valid?
      assert %{widget: [msg]} = errors_on(changeset)
      assert msg =~ "not compatible"

      # date_range + date_range_picker = valid
      changeset =
        DashboardFilter.new(%{
          dashboard_id: 1,
          name: "filter",
          label: "Filter",
          filter_type: :date_range,
          widget: :date_range_picker,
          position: 0
        })

      assert changeset.valid?

      # select + select = valid
      changeset =
        DashboardFilter.new(%{
          dashboard_id: 1,
          name: "filter",
          label: "Filter",
          filter_type: :select,
          widget: :select,
          position: 0
        })

      assert changeset.valid?
    end

    test "normalizes config to string keys" do
      changeset =
        DashboardFilter.new(%{
          dashboard_id: 1,
          name: "filter",
          label: "Filter",
          filter_type: :select,
          widget: :select,
          position: 0,
          config: %{options: ["a", "b", "c"]}
        })

      assert changeset.valid?
      config = Ecto.Changeset.get_field(changeset, :config)
      assert config == %{"options" => ["a", "b", "c"]}
    end

    test "rejects a date range token as the default value of a date filter" do
      changeset =
        DashboardFilter.new(%{
          dashboard_id: 1,
          name: "filter",
          label: "Filter",
          filter_type: :date,
          widget: :date_picker,
          position: 0,
          default_value: "last_7_days"
        })

      refute changeset.valid?

      assert %{
               default_value: [
                 "last_7_days is a date range token and needs filter type date_range"
               ]
             } =
               errors_on(changeset)
    end

    test "rejects a date range token when the filter type changes to date" do
      filter = %DashboardFilter{
        dashboard_id: 1,
        name: "filter",
        label: "Filter",
        filter_type: :date_range,
        widget: :date_range_picker,
        position: 0,
        default_value: "this_month"
      }

      changeset = DashboardFilter.update(filter, %{filter_type: :date, widget: :date_picker})

      refute changeset.valid?

      assert %{
               default_value: [
                 "this_month is a date range token and needs filter type date_range"
               ]
             } = errors_on(changeset)
    end

    test "accepts a single day token or a concrete date as the default value of a date filter" do
      for default_value <- ["today", "yesterday", "2026-01-01"] do
        changeset =
          DashboardFilter.new(%{
            dashboard_id: 1,
            name: "filter",
            label: "Filter",
            filter_type: :date,
            widget: :date_picker,
            position: 0,
            default_value: default_value
          })

        assert changeset.valid?, "Expected default_value #{default_value} to be valid"
      end
    end

    test "accepts every date token as the default value of a date range filter" do
      for token <- DateToken.tokens() do
        changeset =
          DashboardFilter.new(%{
            dashboard_id: 1,
            name: "filter",
            label: "Filter",
            filter_type: :date_range,
            widget: :date_range_picker,
            position: 0,
            default_value: token
          })

        assert changeset.valid?, "Expected default_value #{token} to be valid"
      end
    end

    test "accepts a date range token as the default value of a text filter" do
      changeset =
        DashboardFilter.new(%{
          dashboard_id: 1,
          name: "filter",
          label: "Filter",
          filter_type: :text,
          widget: :input,
          position: 0,
          default_value: "last_7_days"
        })

      assert changeset.valid?
    end

    test "accepts a source query on a filter with the select widget" do
      for filter_type <- [:select, :text, :number] do
        changeset =
          DashboardFilter.new(%{
            dashboard_id: 1,
            name: "city",
            label: "City",
            filter_type: filter_type,
            widget: :select,
            position: 0,
            source_query_id: 1
          })

        assert changeset.valid?, "Expected filter_type #{filter_type} to be valid"
      end
    end

    test "rejects a source query on a filter without the select widget" do
      changeset =
        DashboardFilter.new(%{
          dashboard_id: 1,
          name: "city",
          label: "City",
          filter_type: :text,
          widget: :input,
          position: 0,
          source_query_id: 1
        })

      refute changeset.valid?
      assert %{source_query_id: ["needs the select widget"]} = errors_on(changeset)
    end

    test "accepts a dependency with a source query" do
      changeset = DashboardFilter.new(Map.put(city_filter_attrs(), :depends_on_filter_id, 2))

      assert changeset.valid?
    end

    test "rejects a dependency without a source query" do
      changeset =
        city_filter_attrs()
        |> Map.merge(%{source_query_id: nil, depends_on_filter_id: 2})
        |> DashboardFilter.new()

      refute changeset.valid?
      assert %{depends_on_filter_id: ["needs a source query"]} = errors_on(changeset)
    end

    test "rejects a removal of the source query of a filter with a dependency" do
      filter =
        struct!(
          DashboardFilter,
          Map.merge(city_filter_attrs(), %{id: 3, depends_on_filter_id: 2})
        )

      changeset = DashboardFilter.update(filter, %{source_query_id: nil})

      refute changeset.valid?
      assert %{depends_on_filter_id: ["needs a source query"]} = errors_on(changeset)
    end

    test "accepts an update of a filter with a dependency whose source query was deleted" do
      filter =
        struct!(
          DashboardFilter,
          Map.merge(city_filter_attrs(), %{id: 3, source_query_id: nil, depends_on_filter_id: 2})
        )

      changeset = DashboardFilter.update(filter, %{label: "Town"})

      assert changeset.valid?
    end

    test "rejects a dependency on the filter itself" do
      filter = struct!(DashboardFilter, Map.put(city_filter_attrs(), :id, 3))

      changeset = DashboardFilter.update(filter, %{depends_on_filter_id: 3})

      refute changeset.valid?
      assert %{depends_on_filter_id: ["cannot be the filter itself"]} = errors_on(changeset)
    end
  end

  describe "DashboardFilter JSON" do
    test "encodes the source query id and the dependency id" do
      filter =
        struct!(
          DashboardFilter,
          Map.merge(city_filter_attrs(), %{id: 3, depends_on_filter_id: 2})
        )

      assert %{"source_query_id" => 1, "depends_on_filter_id" => 2} =
               filter |> Lotus.JSON.encode!() |> Lotus.JSON.decode!()
    end
  end

  defp city_filter_attrs do
    %{
      dashboard_id: 1,
      name: "city",
      label: "City",
      filter_type: :select,
      widget: :select,
      position: 0,
      source_query_id: 1
    }
  end

  describe "DashboardCardFilterMapping schema" do
    test "creates mapping with valid attributes" do
      changeset =
        DashboardCardFilterMapping.new(%{
          card_id: 1,
          filter_id: 1,
          variable_name: "user_id"
        })

      assert changeset.valid?
    end

    test "requires all mandatory fields" do
      changeset = DashboardCardFilterMapping.new(%{})
      refute changeset.valid?
      errors = errors_on(changeset)
      assert "can't be blank" in errors[:card_id]
      assert "can't be blank" in errors[:filter_id]
      assert "can't be blank" in errors[:variable_name]
    end

    test "validates variable_name format" do
      # Invalid - starts with number
      changeset =
        DashboardCardFilterMapping.new(%{
          card_id: 1,
          filter_id: 1,
          variable_name: "123var"
        })

      refute changeset.valid?
      assert %{variable_name: [msg]} = errors_on(changeset)
      assert msg =~ "valid variable name"

      # Valid
      changeset =
        DashboardCardFilterMapping.new(%{
          card_id: 1,
          filter_id: 1,
          variable_name: "valid_var_123"
        })

      assert changeset.valid?
    end

    test "normalizes transform to string keys" do
      changeset =
        DashboardCardFilterMapping.new(%{
          card_id: 1,
          filter_id: 1,
          variable_name: "start_date",
          transform: %{type: "date_range_start", format: "YYYY-MM-DD"}
        })

      assert changeset.valid?
      transform = Ecto.Changeset.get_field(changeset, :transform)
      assert transform == %{"type" => "date_range_start", "format" => "YYYY-MM-DD"}
    end

    test "accepts nil transform" do
      changeset =
        DashboardCardFilterMapping.new(%{
          card_id: 1,
          filter_id: 1,
          variable_name: "user_id",
          transform: nil
        })

      assert changeset.valid?
    end
  end
end
