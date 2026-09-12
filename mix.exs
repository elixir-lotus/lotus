defmodule Lotus.MixProject do
  use Mix.Project

  @source_url "https://github.com/elixir-lotus/lotus"
  @version "1.0.0"

  def project do
    [
      app: :lotus,
      name: "Lotus",
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      elixirc_options: [no_warn_undefined: [Postgrex.Error, Exqlite.Error, MyXQL.Error]],
      deps: deps(),
      docs: docs(),
      package: package(),
      description: description(),
      source_url: @source_url,
      homepage_url: @source_url,
      dialyzer: dialyzer()
    ]
  end

  def cli do
    [preferred_envs: ["test.setup": :test, test: :test]]
  end

  def application do
    [
      mod: {Lotus.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:cachex, "~> 4.0", optional: true},
      # Lotus.Normalizer renders Decimal results with `max_digits: :infinity`,
      # which Decimal.to_string/3 only accepts from 2.4.0 on. Ecto's own
      # requirement allows 2.0, so without this an app can resolve a Decimal
      # that raises the moment a query returns a numeric column.
      {:decimal, "~> 2.4 or ~> 3.0"},
      {:ecto, "~> 3.10"},
      {:ecto_sql, "~> 3.10"},
      {:ecto_sqlite3, "~> 0.21", optional: true},
      {:jason, "~> 1.4"},
      {:myxql, "~> 0.8", optional: true},
      {:nimble_csv, "~> 1.2"},
      {:nimble_options, "~> 1.0"},
      {:postgrex, "~> 0.20", optional: true},
      {:telemetry, "~> 1.0"},

      # AI/LLM Integration
      {:req_llm, "~> 1.6"},

      # Development and testing dependencies
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.40", only: [:dev, :test], runtime: false},
      {:mimic, "~> 2.0", only: :test}
    ]
  end

  defp aliases do
    [
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      "test.setup": ["ecto.drop --quiet", "ecto.create", "ecto.migrate"],
      lint: ["format", "dialyzer"]
    ]
  end

  defp package do
    [
      name: "lotus",
      maintainers: ["Arda Can Tugay", "Rui Freitas"],
      licenses: ["MIT"],
      links: %{GitHub: @source_url},
      files: ~w[lib .formatter.exs mix.exs README* LICENSE* CHANGELOG*]
    ]
  end

  defp dialyzer do
    [
      plt_add_apps: [:mix, :ex_unit, :ecto, :ecto_sql, :postgrex, :myxql],
      plt_core_path: "_build/#{Mix.env()}",
      flags: [:error_handling, :missing_return, :underspecs],
      ignore_warnings: ".dialyzer_ignore.exs"
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extras: docs_guides(),
      skip_undefined_reference_warnings_on: ["CHANGELOG.md", "guides/upgrading-to-v1.md"],
      groups_for_modules: [
        "Core API": [Lotus, Lotus.Config, Lotus.Value],
        "Query Storage": [Lotus.Storage, Lotus.Storage.Query, Lotus.Storage.QueryVariable],
        "Query Execution": [Lotus.Runner, Lotus.Result, Lotus.Preflight],
        "Data Export": [Lotus.Export, ~r/Lotus\.Export\..+/],
        "Data Sources": [Lotus.Source, Lotus.Source.Adapter, Lotus.Source.Resolver],
        "Adapter Authoring": [
          Lotus.Query.Statement,
          Lotus.Source.Adapters.Ecto,
          Lotus.Source.Adapters.Ecto.Dialect,
          ~r/Lotus\.Source\.Adapters\..+/
        ],
        "Schema Introspection": [Lotus.Schema, Lotus.Visibility],
        Telemetry: [Lotus.Telemetry],
        Caching: [Lotus.Cache, ~r/Lotus\.Cache\..+/],
        "Database Migrations": [Lotus.Migration, Lotus.Migrations, ~r/Lotus\.Migrations\..+/],
        "OTP Application": [Lotus.Application, Lotus.Supervisor],
        AI: [
          Lotus.AI,
          Lotus.AI.QueryGenerator,
          Lotus.AI.QueryExplainer,
          Lotus.AI.QueryOptimizer,
          Lotus.AI.Conversation,
          Lotus.AI.Action,
          Lotus.AI.Actions,
          Lotus.AI.Tool,
          ~r/Lotus\.AI\.Actions\..+/
        ],
        Utilities: [Lotus.JSON]
      ]
    ]
  end

  defp docs_guides do
    [
      "README.md",
      "CHANGELOG.md",
      "guides/overview.md",
      "guides/installation.md",
      "guides/getting-started.md",
      "guides/dashboards.md",
      "guides/advanced-variables.md",
      "guides/ai_query_generation.md",
      "guides/configuration.md",
      "guides/middleware.md",
      "guides/schema-introspection.md",
      "guides/visibility.md",
      "guides/source-adapters.md",
      "guides/custom-resolvers.md",
      "guides/caching.md",
      "guides/telemetry.md",
      "guides/upgrading-to-v1.md",
      "guides/contributing.md"
    ]
  end

  defp description do
    """
    Embeddable business intelligence engine for Elixir — run queries against SQL and non-SQL data sources, build dashboards, and manage analytics directly in your Phoenix app.
    """
  end
end
