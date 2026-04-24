import Config

config :lotus,
  storage_repo: Lotus.Test.Repo,
  default_source: "postgres",
  data_sources: %{
    "postgres" => Lotus.Test.Repo,
    "mysql" => Lotus.Test.MysqlRepo,
    "sqlite" => Lotus.Test.SqliteRepo
  },
  table_visibility: %{
    default: [
      deny: [
        {"pg_catalog", ~r/.*/},
        {"information_schema", ~r/.*/},
        {"public", "schema_migrations"},
        # Test bare string blocking across all repos/schemas
        # Should block api_keys in any database
        "api_keys",
        # Should block internal_logs in any database
        "internal_logs"
      ]
    ],
    # MySQL-specific rules for testing
    mysql: [
      allow: [
        # Allow users table (tests overlap with other repos)
        "users",
        # Analytics events
        "events",
        # Page tracking
        "page_views",
        # Orders (different structure than SQLite)
        "orders",
        "monthly_summaries",
        "daily_metrics",
        "feature_usage",
        "customer_segments"
      ],
      deny: [
        # Block the 'information' table we created
        "information"
      ]
    ]
  }

config :lotus, Lotus.Test.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  port: 2345,
  database: "lotus_dev",
  pool_size: 10,
  priv: "priv/repo",
  show_sensitive_data_on_connection_error: true,
  stacktrace: true

config :lotus, Lotus.Test.SqliteRepo,
  database: Path.expand("../priv/lotus_dev.db", Path.dirname(__ENV__.file)),
  pool_size: 10,
  priv: "priv/sqlite_repo",
  show_sensitive_data_on_connection_error: true,
  stacktrace: true

config :lotus, Lotus.Test.MysqlRepo,
  username: "lotus",
  password: "lotus",
  hostname: "localhost",
  # Docker Compose MySQL port
  port: 3307,
  database: "lotus_test",
  pool_size: 10,
  priv: "priv/mysql_repo",
  show_sensitive_data_on_connection_error: true,
  stacktrace: true

config :lotus, ecto_repos: [Lotus.Test.Repo, Lotus.Test.SqliteRepo, Lotus.Test.MysqlRepo]
