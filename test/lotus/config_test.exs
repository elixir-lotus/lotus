defmodule Lotus.ConfigTest do
  use ExUnit.Case, async: false

  alias Lotus.Config

  import ExUnit.CaptureLog

  @preserved_keys [
    :cache,
    :table_visibility,
    :schema_visibility,
    :column_visibility,
    :data_sources,
    :default_source,
    :source_adapters,
    :allow_unrestricted_resources
  ]

  setup do
    originals = Map.new(@preserved_keys, &{&1, Application.get_env(:lotus, &1)})

    on_exit(fn ->
      for {key, value} <- originals do
        if is_nil(value) do
          Application.delete_env(:lotus, key)
        else
          Application.put_env(:lotus, key, value)
        end
      end

      Config.reload!()
    end)

    :ok
  end

  describe "cache_namespace/0" do
    test "returns the default namespace when no cache is configured" do
      Application.delete_env(:lotus, :cache)
      Config.reload!()

      assert Config.cache_namespace() == "lotus:v1"
    end

    test "returns the default namespace when cache is configured without an explicit namespace" do
      Application.put_env(:lotus, :cache, %{adapter: Lotus.Cache.ETS})
      Config.reload!()

      assert Config.cache_namespace() == "lotus:v1"
    end

    test "returns the configured namespace when explicitly set" do
      Application.put_env(:lotus, :cache, %{
        adapter: Lotus.Cache.ETS,
        namespace: "my_app:v3"
      })

      Config.reload!()

      assert Config.cache_namespace() == "my_app:v3"
    end
  end

  describe "visibility rules lookups" do
    @variants [
      {:rules_for_source_name, :table_visibility},
      {:schema_rules_for_source_name, :schema_visibility},
      {:column_rules_for_source_name, :column_visibility}
    ]

    test "returns source-specific rules when source_name matches a configured key" do
      rules = [deny: ["secret_table"]]

      for {fun, key} <- @variants do
        put_visibility(key, %{postgres: rules})

        assert apply(Config, fun, ["postgres"]) == rules,
               "#{fun} did not return source-specific rules"
      end
    end

    test "returns an empty list when the source-specific value is an empty list" do
      for {fun, key} <- @variants do
        put_visibility(key, %{postgres: [], default: [deny: ["should_not_see"]]})

        assert apply(Config, fun, ["postgres"]) == [],
               "#{fun} did not return empty list for empty source-specific value"
      end
    end

    test "falls through to :default when the source-specific value is nil" do
      default_rules = [deny: ["default_rule"]]

      for {fun, key} <- @variants do
        put_visibility(key, %{postgres: nil, default: default_rules})

        assert apply(Config, fun, ["postgres"]) == default_rules,
               "#{fun} did not fall through to :default for nil source-specific value"
      end
    end

    test "returns :default rules when source_name has no match and :default is present" do
      default_rules = [deny: ["default_rule"]]

      for {fun, key} <- @variants do
        put_visibility(key, %{other_source: [deny: ["other"]], default: default_rules})

        assert apply(Config, fun, ["postgres"]) == default_rules,
               "#{fun} did not fall through to :default"
      end
    end

    test "returns an empty list when source_name has no match and :default is absent" do
      for {fun, key} <- @variants do
        put_visibility(key, %{other_source: [deny: ["other"]]})

        assert apply(Config, fun, ["postgres"]) == [],
               "#{fun} did not return [] when no match and no :default"
      end
    end

    test "returns an empty list when the visibility map is missing entirely" do
      for {fun, key} <- @variants do
        Application.delete_env(:lotus, key)
        Config.reload!()

        assert apply(Config, fun, ["postgres"]) == [],
               "#{fun} did not return [] when visibility map is missing"
      end
    end

    test "returns :default rules for an arbitrary source_name string with no matching key" do
      unknown = "lotus_config_test_unknown_#{System.unique_integer([:positive])}"
      default_rules = [deny: ["secret"]]

      for {fun, key} <- @variants do
        put_visibility(key, %{postgres: [deny: ["should_not_match"]], default: default_rules})

        assert apply(Config, fun, [unknown]) == default_rules,
               "#{fun} did not return :default rules for unknown source_name"
      end
    end
  end

  describe "data_sources config validation" do
    test "accepts map data source values alongside module atoms" do
      Application.put_env(:lotus, :data_sources, %{
        "postgres" => Lotus.Test.Repo,
        "search" => %{adapter: :elasticsearch, url: "http://localhost:9200"}
      })

      Config.reload!()

      sources = Config.data_sources()
      assert sources["postgres"] == Lotus.Test.Repo
      assert sources["search"] == %{adapter: :elasticsearch, url: "http://localhost:9200"}
    end
  end

  describe "source_adapters config validation" do
    test "accepts modules that implement Lotus.Source.Adapter behaviour" do
      # Use a built-in adapter as the "known valid" module so the test exercises
      # the real behaviour contract without needing a stub.
      Application.put_env(:lotus, :source_adapters, [Lotus.Source.Adapters.Postgres])
      assert Config.reload!()
      assert Lotus.Source.Adapters.Postgres in Config.source_adapters()
    end

    test "rejects unloaded modules with a descriptive error" do
      Application.put_env(:lotus, :source_adapters, [:NotAModule])

      assert_raise ArgumentError,
                   ~r/expected a loaded module implementing Lotus.Source.Adapter/,
                   fn -> Config.reload!() end
    end

    test "rejects loaded modules that do not implement the behaviour" do
      Application.put_env(:lotus, :source_adapters, [String])

      assert_raise ArgumentError,
                   ~r/String does not implement the Lotus.Source.Adapter behaviour/,
                   fn -> Config.reload!() end
    end

    test "rejects non-atom values" do
      Application.put_env(:lotus, :source_adapters, ["not_an_atom"])

      assert_raise ArgumentError, ~r/expected a module atom/, fn ->
        Config.reload!()
      end
    end
  end

  defp put_visibility(key, value) do
    Application.put_env(:lotus, key, value)
    Config.reload!()
  end

  describe "allow_unrestricted_resources?/1" do
    setup do
      # Preserve the app-level `default_source` pointing at the real test
      # sources; these test cases use isolated `data_sources` and would fail
      # the cross-validation that `:default_source` must be a configured key.
      Application.delete_env(:lotus, :default_source)
      :ok
    end

    test "returns true when the source's config map opts in" do
      Application.put_env(:lotus, :allow_unrestricted_resources, false)

      Application.put_env(:lotus, :data_sources, %{
        "es" => %{adapter: :elasticsearch, allow_unrestricted_resources: true}
      })

      Config.reload!()

      assert Config.allow_unrestricted_resources?("es") == true
    end

    test "falls back to the global flag when the source has no per-source setting" do
      Application.put_env(:lotus, :allow_unrestricted_resources, true)
      Application.put_env(:lotus, :data_sources, %{"pg" => Lotus.Test.Repo})
      Config.reload!()

      assert Config.allow_unrestricted_resources?("pg") == true
    end

    test "returns false when neither the source nor the global flag opts in" do
      Application.put_env(:lotus, :allow_unrestricted_resources, false)
      Application.put_env(:lotus, :data_sources, %{"pg" => Lotus.Test.Repo})
      Config.reload!()

      assert Config.allow_unrestricted_resources?("pg") == false
    end

    test "per-source opt-in wins over global flag being false" do
      Application.put_env(:lotus, :allow_unrestricted_resources, false)

      Application.put_env(:lotus, :data_sources, %{
        "es" => %{adapter: :elasticsearch, allow_unrestricted_resources: true},
        "pg" => Lotus.Test.Repo
      })

      Config.reload!()

      assert Config.allow_unrestricted_resources?("es") == true
      assert Config.allow_unrestricted_resources?("pg") == false
    end

    test "defaults to false when nothing is configured" do
      Application.delete_env(:lotus, :allow_unrestricted_resources)
      Application.put_env(:lotus, :data_sources, %{"pg" => Lotus.Test.Repo})
      Config.reload!()

      assert Config.allow_unrestricted_resources?("pg") == false
    end
  end
end
