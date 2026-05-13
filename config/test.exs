import Config

config :lotus,
  storage_repo: Lotus.Test.Repo,
  default_source: "postgres",
  data_sources: %{
    "postgres" => Lotus.Test.Repo,
    "sqlite" => Lotus.Test.SqliteRepo,
    "mysql" => Lotus.Test.MysqlRepo
  },
  table_visibility: %{
    # Built-in rules automatically exclude:
    # - schema_migrations, lotus_queries
    # - pg_catalog, information_schema
    # - sqlite_* tables
    #
    # This config is just for additional custom rules if needed
    default: []
  }

config :lotus, Lotus.Test.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  port: 2345,
  database: "lotus_test#{System.get_env("MIX_TEST_PARTITION")}",
  migration_lock: false,
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2,
  priv: "test/support/postgres",
  show_sensitive_data_on_connection_error: true,
  stacktrace: true

config :lotus, Lotus.Test.SqliteRepo,
  database:
    Path.expand(
      "../priv/lotus_sqlite_test#{System.get_env("MIX_TEST_PARTITION")}.db",
      Path.dirname(__ENV__.file)
    ),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 5,
  journal_mode: :wal,
  synchronous: :normal,
  busy_timeout: 30000,
  queue_target: 5000,
  queue_interval: 5000,
  priv: "test/support/sqlite",
  migration_source: "lotus_sqlite_schema_migrations",
  show_sensitive_data_on_connection_error: true,
  stacktrace: true

config :lotus, Lotus.Test.MysqlRepo,
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2,
  queue_target: 5000,
  queue_interval: 5000,
  priv: "test/support/mysql",
  migration_source: "lotus_mysql_schema_migrations",
  show_sensitive_data_on_connection_error: true,
  stacktrace: true,
  url:
    System.get_env("MYSQL_URL") ||
      "mysql://root:mysql@localhost:3307/lotus_test#{System.get_env("MIX_TEST_PARTITION")}"

config :lotus, ecto_repos: [Lotus.Test.Repo, Lotus.Test.SqliteRepo, Lotus.Test.MysqlRepo]
