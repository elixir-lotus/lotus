defmodule Lotus.Source.ConnectionsTest do
  # Starts sources through the reconciler and swaps the global resolver.
  use ExUnit.Case, async: false

  alias Lotus.Source.Adapter
  alias Lotus.Source.Connections
  alias Lotus.Test.LifecycleResolver

  @postgres %{
    "hostname" => "localhost",
    "port" => "2345",
    "database" => "lotus_test#{System.get_env("MIX_TEST_PARTITION")}",
    "username" => "postgres",
    "password" => "postgres"
  }

  defp tls_of(settings) do
    {:ok, %Adapter{state: %{config: config}}} =
      Connections.build("warehouse", "postgres", settings)

    Keyword.get(config, :ssl, false)
  end

  defmodule SearchAdapter do
    @moduledoc false
    # An adapter of a library: connected with a URL and a key.
    @behaviour Lotus.Source.Adapter
    @behaviour Lotus.Source.Adapter.Connection

    @impl Lotus.Source.Adapter.Connection
    def connection do
      %{
        kind: "search",
        label: "Search",
        fields: [
          %{key: :url, label: "URL", type: :string, required: true},
          %{key: :api_key, label: "API key", type: :secret}
        ]
      }
    end

    @impl Lotus.Source.Adapter.Connection
    def from_settings(_name, settings), do: {:ok, Map.new(settings)}

    @impl Lotus.Source.Adapter
    def wrap(name, state),
      do: %Adapter{name: name, module: __MODULE__, state: state, source_type: :other}

    @impl Lotus.Source.Adapter
    def health_check(%{url: "https://up"}), do: :ok
    def health_check(_state), do: {:error, "connection refused"}

    @impl Lotus.Source.Adapter
    def execute_query(_state, _text, _params, _opts), do: {:ok, %{columns: [], rows: []}}
    @impl Lotus.Source.Adapter
    def transaction(state, fun, _opts), do: {:ok, fun.(state)}
    @impl Lotus.Source.Adapter
    def list_tables(_state, _schemas, _opts), do: {:ok, []}
    @impl Lotus.Source.Adapter
    def describe_table(_state, _schema, _table), do: {:ok, []}
    @impl Lotus.Source.Adapter
    def builtin_denies(_state), do: []
    @impl Lotus.Source.Adapter
    def disconnect(_state), do: :ok
    @impl Lotus.Source.Adapter
    def format_error(_state, error), do: inspect(error)
    @impl Lotus.Source.Adapter
    def source_type(_state), do: :other
  end

  describe "kinds/0" do
    test "the built-in SQL databases, with their fields" do
      kinds = Map.new(Connections.kinds(), &{&1.kind, &1})

      assert %{label: "PostgreSQL", fields: fields} = kinds["postgres"]

      assert Enum.map(fields, & &1.key) == [
               :hostname,
               :port,
               :database,
               :username,
               :password,
               :ssl,
               :ssl_ca_certificate,
               :ssl_verify_hostname
             ]

      assert %{label: "MySQL"} = kinds["mysql"]
      assert %{label: "SQLite", fields: [%{key: :database}]} = kinds["sqlite"]
    end

    test "and those of the adapters in :source_adapters" do
      previous = Application.get_env(:lotus, :source_adapters)
      Application.put_env(:lotus, :source_adapters, [SearchAdapter])
      Lotus.Config.reload!()

      on_exit(fn ->
        if previous,
          do: Application.put_env(:lotus, :source_adapters, previous),
          else: Application.delete_env(:lotus, :source_adapters)

        Lotus.Config.reload!()
      end)

      assert %{label: "Search", module: SearchAdapter} = Connections.kind("search")
      assert :ok = Connections.test("search", %{"url" => "https://up"})

      assert {:error, "connection refused"} =
               Connections.test("search", %{"url" => "https://down"})
    end
  end

  describe "cast/2" do
    test "checks each field and casts it" do
      kind = Connections.kind("postgres")

      assert {:ok, values} = Connections.cast(kind, Map.put(@postgres, "hostname", " db "))
      assert values[:hostname] == "db"
      assert values[:port] == 2345
      assert values[:ssl] == false

      assert {:ok, values} =
               Connections.cast(kind, Map.merge(@postgres, %{"port" => "", "ssl" => "on"}))

      assert values[:port] == 5432
      assert values[:ssl] == true

      assert {:error, errors} =
               Connections.cast(kind, %{"hostname" => " ", "port" => "five", "database" => "x"})

      assert errors == %{
               hostname: "Give the host.",
               port: "Port is a whole number.",
               username: "Give the user."
             }
    end

    test "takes atom keys too" do
      assert {:ok, [database: "/tmp/x.db"]} =
               Connections.cast(Connections.kind("sqlite"), %{database: "/tmp/x.db"})
    end
  end

  describe "build/3 and test/2" do
    test "a Postgres source: tested, then started by the reconciler and queried" do
      assert :ok = Connections.test("postgres", @postgres)

      assert {:error, message} = Connections.test("postgres", %{@postgres | "password" => "nope"})
      assert message =~ "password authentication failed"

      previous = Application.get_env(:lotus, :source_resolver)
      Application.put_env(:lotus, :source_resolver, LifecycleResolver)
      Lotus.Config.reload!()

      on_exit(fn ->
        LifecycleResolver.put_sources([])
        {:ok, _} = Lotus.Source.reconcile()
        LifecycleResolver.clear()

        case previous do
          nil -> Application.delete_env(:lotus, :source_resolver)
          resolver -> Application.put_env(:lotus, :source_resolver, resolver)
        end

        Lotus.Config.reload!()
      end)

      assert {:ok, %Adapter{name: "warehouse"} = adapter} =
               Connections.build("warehouse", "postgres", @postgres)

      LifecycleResolver.put_sources([adapter])
      assert {:ok, %{started: ["warehouse"]}} = Lotus.Source.reconcile()

      assert {:ok, %{rows: [[1]]}} = Adapter.execute_query(adapter, "SELECT 1", [], [])
      assert :ok = Adapter.health_check(adapter)

      LifecycleResolver.put_sources([])
      assert {:ok, %{stopped: ["warehouse"]}} = Lotus.Source.reconcile()
      assert Lotus.Source.Registry.whereis(Lotus.Source.Adapters.Postgres, "warehouse") == nil
    end

    test "test: :query also runs a query, for a driver that connects without logging in" do
      alias Lotus.Source.Adapters.Ecto, as: EctoAdapter
      alias Lotus.Source.Adapters.Postgres

      {:ok, values} = Connections.cast(Connections.kind("postgres"), @postgres)

      {:ok, state} =
        EctoAdapter.settings_state(Postgres, Postgres.Repo, "probe", values, :query)

      assert state.test == :query
      assert :ok = EctoAdapter.do_health(state)

      {:ok, state} =
        EctoAdapter.settings_state(
          Postgres,
          Postgres.Repo,
          "probe",
          Keyword.put(values, :password, "nope"),
          :query
        )

      assert {:error, error} = EctoAdapter.do_health(state)
      assert inspect(error) =~ "password authentication failed"
    end

    test "SSL checks the server's certificate: against the given CA, else the system's" do
      alias Lotus.Source.Adapters.Ecto, as: EctoAdapter

      pem = File.read!("test/support/fixtures/tls/test_ca.pem")
      [{:Certificate, der, _}] = :public_key.pem_decode(pem)
      ssl = fn settings -> tls_of(Map.merge(@postgres, settings)) end

      assert ssl.(%{}) == false
      assert ssl.(%{"ssl" => true}) == [cacerts: :public_key.cacerts_get()]
      assert ssl.(%{"ssl_ca_certificate" => pem}) == [cacerts: [der]]

      # A form may join the lines of the PEM.
      assert ssl.(%{"ssl" => true, "ssl_ca_certificate" => String.replace(pem, "\n", " ")}) ==
               [cacerts: [der]]

      assert ssl.(%{"ssl_ca_certificate" => pem, "ssl_verify_hostname" => "false"}) == [
               cacerts: [der],
               customize_hostname_check: [],
               verify_fun: {&EctoAdapter.verify_ca_only/3, []}
             ]

      for bad <- [
            "not a certificate",
            "-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----"
          ] do
        assert {:error, %{ssl_ca_certificate: "Paste the CA certificate in PEM form" <> _}} =
                 Connections.build(
                   "warehouse",
                   "postgres",
                   Map.put(@postgres, "ssl_ca_certificate", bad)
                 )
      end
    end

    test "without the host name check, the chain to the CA is still checked" do
      alias Lotus.Source.Adapters.Ecto, as: EctoAdapter

      assert {:valid, :s} =
               EctoAdapter.verify_ca_only(:cert, {:bad_cert, :hostname_check_failed}, :s)

      assert {:fail, :unknown_ca} =
               EctoAdapter.verify_ca_only(:cert, {:bad_cert, :unknown_ca}, :s)

      assert {:fail, :cert_expired} =
               EctoAdapter.verify_ca_only(:cert, {:bad_cert, :cert_expired}, :s)
    end

    @tag :mysql
    test "a MySQL source with SSL connects or says why, rather than crash" do
      mysql = %{
        "hostname" => "localhost",
        "port" => "3307",
        "database" => "lotus_test",
        "username" => "lotus",
        "password" => "lotus",
        "ssl" => true
      }

      # The test server's certificate is its own, which no system CA signed.
      assert {:error, message} = Connections.test("mysql", mysql)
      assert message =~ "CA"
    end

    test "a SQLite file must exist" do
      assert {:error, %{database: "There is no database file at /nowhere.db."}} =
               Connections.build("local", "sqlite", %{"database" => "/nowhere.db"})
    end

    test "an unknown kind" do
      assert {:error, :unknown_kind} = Connections.build("x", "oracle", %{})

      assert {:error, "No installed adapter connects \"oracle\"."} =
               Connections.test("oracle", %{})
    end

    test "invalid settings are named, not tried" do
      assert {:error, %{hostname: _}} =
               Connections.test("postgres", %{@postgres | "hostname" => ""})
    end
  end
end
