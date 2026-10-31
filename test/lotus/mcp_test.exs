defmodule Lotus.MCPTest do
  use Lotus.Case, async: false

  import Lotus.Fixtures
  import Sake.Test

  alias Lotus.MCP.Host
  alias Lotus.Middleware

  @all ["lotus:read", "lotus:query", "lotus:write"]

  defmodule Recorder do
    @moduledoc false
    # Tells the test which context and scope Lotus saw a statement run with.
    def init(pid), do: pid

    def call(payload, pid) do
      send(pid, {:before_query, payload.context})
      {:cont, payload}
    end
  end

  defmodule HostServer do
    @moduledoc false
    # A host's own server, saying who may use Lotus instead of the config.
    use Sake.Server, name: "host", version: "1.0.0"

    mount Lotus.MCP

    middleware :before_request, [
      {Lotus.MCP.Host, authorize: {Lotus.MCPTest, :admin?}, actor: {Lotus.MCPTest, :host_actor}}
    ]
  end

  def admin?(principal), do: Map.get(principal, :admin?) == true
  def host_actor(principal), do: [context: {:host, principal.id}, scope: nil]

  setup do
    setup_test_data()
    mcp_config([])
    on_exit(fn -> Application.delete_env(:lotus, :mcp) end)
    :ok
  end

  # The MCP settings, with every principal allowed unless the test says.
  defp mcp_config(opts),
    do: Application.put_env(:lotus, :mcp, Keyword.put_new(opts, :authorize, fn _ -> true end))

  defp client(scopes \\ @all, principal \\ %{id: 7, email: "ana@example.com"}),
    do: connect(Lotus.MCP, scope: principal, scopes: scopes)

  defp call!(client, tool, args) do
    {:ok, result} = call_tool(client, tool, args)
    result
  end

  describe "the server" do
    test "lists every tool to a token with every scope" do
      assert {:ok, tools} = list_tools(client())

      assert Enum.map(tools, & &1.name) == [
               "list_data_sources",
               "list_schemas",
               "list_tables",
               "describe_table",
               "get_column_values",
               "run_sql",
               "list_queries",
               "get_query",
               "run_query",
               "list_dashboards",
               "get_dashboard",
               "run_dashboard",
               "save_query",
               "update_query",
               "save_chart",
               "create_dashboard",
               "add_dashboard_card"
             ]
    end

    test "a read-only token sees no query or write tools, and is refused them" do
      client = client(["lotus:read"])
      assert {:ok, tools} = list_tools(client)
      names = Enum.map(tools, & &1.name)

      assert "list_tables" in names
      refute "run_sql" in names
      refute "save_query" in names

      assert {:error, {:insufficient_scope, %{scope: ["lotus:query"]}}} =
               call_tool(client, "run_sql", %{
                 "data_source" => "postgres",
                 "statement" => "SELECT 1"
               })

      assert {:error, {:insufficient_scope, %{scope: ["lotus:write"]}}} =
               call_tool(client, "create_dashboard", %{"name" => "x"})
    end

    test "marks the read tools read-only and update_query destructive" do
      assert {:ok, tools} = list_tools(client())
      by_name = Map.new(tools, &{&1.name, &1.annotations})

      assert by_name["run_sql"]["readOnlyHint"] == true
      assert by_name["update_query"]["destructiveHint"] == true
      assert by_name["save_query"]["readOnlyHint"] == false
    end
  end

  describe "who may use it" do
    @tag :capture_log
    test "nobody, until the host says who" do
      Application.put_env(:lotus, :mcp, [])
      client = client()

      assert {:ok, []} = list_tools(client)
      assert {:ok, []} = list_resources(client)
      assert {:error, {:rpc, _}} = call_tool(client, "list_data_sources", %{})
    end

    test "only the principals authorize: allows" do
      mcp_config(authorize: fn principal -> principal.admin? end)

      assert {:ok, []} = list_tools(client(@all, %{admin?: false}))
      assert {:ok, [_ | _]} = list_tools(client(@all, %{admin?: true}))

      assert {:error, {:rpc, _}} =
               call_tool(client(@all, %{admin?: false}), "list_data_sources", %{})
    end

    @tag :capture_log
    test "an actor that does not give both context and scope fails the call" do
      mcp_config(actor: fn principal -> [context: principal] end)

      assert {:error, {:rpc, %{"message" => "The tool failed."}}} =
               call_tool(client(), "run_sql", %{
                 "data_source" => "postgres",
                 "statement" => "SELECT 1"
               })
    end
  end

  describe "served by the host's own server, with Lotus.MCP.Host" do
    setup do
      Application.put_env(:lotus, :mcp, [])
      :ok
    end

    defp host_client(principal),
      do: connect(HostServer, scope: principal, scopes: @all)

    test "its authorize: decides who may use Lotus, without config :lotus, :mcp" do
      assert {:ok, []} = list_tools(host_client(%{id: 1, admin?: false}))
      assert {:ok, [_ | _]} = list_tools(host_client(%{id: 1, admin?: true}))

      assert {:error, {:rpc, _}} =
               call_tool(host_client(%{id: 1, admin?: false}), "list_data_sources", %{})
    end

    test "its actor: is the actor Lotus runs with" do
      Middleware.compile(%{before_query: [{Recorder, self()}]})
      on_exit(fn -> Middleware.compile(%{}) end)

      call!(host_client(%{id: 3, admin?: true}), "run_sql", %{
        "data_source" => "postgres",
        "statement" => "SELECT 1"
      })

      assert_receive {:before_query, {:host, 3}}
    end

    test "config :lotus, :mcp still wins where it sets a key" do
      mcp_config(authorize: fn _ -> false end)

      assert {:ok, []} = list_tools(host_client(%{id: 1, admin?: true}))
    end

    test "takes only :authorize and :actor" do
      assert_raise ArgumentError, ~r/takes :authorize and :actor/, fn ->
        Host.init(authorise: {Lotus.MCPTest, :admin?})
      end
    end
  end

  describe "exploring" do
    test "lists data sources, tables and columns" do
      client = client()

      assert %{structured: %{"data_sources" => sources}} =
               call!(client, "list_data_sources", %{})

      assert %{"name" => "postgres", "default" => true} =
               Enum.find(sources, &(&1["name"] == "postgres"))

      assert %{structured: %{"tables" => tables}} =
               call!(client, "list_tables", %{"data_source" => "postgres"})

      assert "public.test_users" in tables
      refute Enum.any?(tables, &String.contains?(&1, "lotus_queries"))

      assert %{structured: %{"columns" => columns}} =
               call!(client, "describe_table", %{
                 "data_source" => "postgres",
                 "table" => "test_users"
               })

      assert "email" in Enum.map(columns, & &1["name"])
    end

    test "list_data_sources leaves out the sources the actor may not use" do
      Mimic.stub(Lotus.Visibility, :source_visible?, fn
        "sqlite", %{id: 7} -> false
        _source, _scope -> true
      end)

      assert %{structured: %{"data_sources" => sources}} =
               call!(client(), "list_data_sources", %{})

      names = Enum.map(sources, & &1["name"])
      assert "postgres" in names
      refute "sqlite" in names
    end

    test "what helps a model write a query: descriptions, joins, sizes" do
      Mimic.stub(Lotus.Config, :data_source_description, fn
        "postgres" -> "the app's users and posts"
        _ -> nil
      end)

      Repo.query!("ANALYZE test_users")
      client = client()

      assert %{structured: %{"data_sources" => sources}} =
               call!(client, "list_data_sources", %{})

      assert %{"description" => "the app's users and posts"} =
               Enum.find(sources, &(&1["name"] == "postgres"))

      refute Map.has_key?(Enum.find(sources, &(&1["name"] == "sqlite")), "description")

      assert %{structured: %{"columns" => columns}} =
               call!(client, "describe_table", %{
                 "data_source" => "postgres",
                 "table" => "test_posts"
               })

      assert %{"references" => "public.test_users.id"} =
               Enum.find(columns, &(&1["name"] == "user_id"))

      refute Map.has_key?(Enum.find(columns, &(&1["name"] == "title")), "references")

      assert %{structured: %{"approx_rows" => approx}} =
               call!(client, "list_tables", %{"data_source" => "postgres"})

      assert is_integer(approx["public.test_users"])
    end

    test "every call is a [:lotus, :mcp, :call] event, with the actor" do
      ref = make_ref()
      pid = self()

      :telemetry.attach(
        "#{inspect(ref)}",
        [:lotus, :mcp, :call],
        fn _event, measurements, metadata, _ ->
          send(pid, {:mcp_call, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach("#{inspect(ref)}") end)

      call!(client(), "list_tables", %{"data_source" => "postgres"})
      call!(client(), "list_tables", %{"data_source" => "nope"})

      assert_received {:mcp_call, %{duration: duration}, ok}
      assert is_integer(duration)

      assert %{
               kind: :tool,
               name: "list_tables",
               arguments: %{data_source: "postgres"},
               status: :ok,
               context: %{id: 7},
               scope: %{id: 7}
             } = ok

      assert_received {:mcp_call, _measurements, %{name: "list_tables", status: :error}}
    end

    test "an unknown data source is a tool error, not a crash" do
      assert %{is_error: true, text: "Unknown data source \"nope\"" <> _} =
               call!(client(), "list_tables", %{"data_source" => "nope"})
    end

    test "the data_sources setting hides the others" do
      mcp_config(data_sources: ["sqlite"])
      client = client()

      assert %{structured: %{"data_sources" => [%{"name" => "sqlite"}]}} =
               call!(client, "list_data_sources", %{})

      assert %{is_error: true} =
               call!(client, "run_sql", %{"data_source" => "postgres", "statement" => "SELECT 1"})

      query = query_fixture(%{data_source: "postgres"})
      assert %{structured: %{"queries" => []}} = call!(client, "list_queries", %{})
      assert %{is_error: true} = call!(client, "get_query", %{"id" => query.id})
      assert %{is_error: true} = call!(client, "run_query", %{"id" => query.id})
    end
  end

  describe "run_sql" do
    test "returns a page of rows" do
      assert %{
               structured: %{
                 "columns" => ["name"],
                 "rows" => [[_], [_]],
                 "num_rows" => 2,
                 "has_more" => true,
                 "offset" => 0
               }
             } =
               call!(client(), "run_sql", %{
                 "data_source" => "postgres",
                 "statement" => "SELECT name FROM test_users ORDER BY name",
                 "limit" => 2
               })
    end

    test "caps the page at max_rows" do
      mcp_config(max_rows: 1)

      assert %{structured: %{"num_rows" => 1, "has_more" => true}} =
               call!(client(), "run_sql", %{
                 "data_source" => "postgres",
                 "statement" => "SELECT name FROM test_users",
                 "limit" => 100
               })
    end

    test "refuses writes, whatever the read_only config says" do
      Mimic.stub(Lotus.Config, :read_only?, fn -> false end)

      assert %{is_error: true} =
               call!(client(), "run_sql", %{
                 "data_source" => "postgres",
                 "statement" => "DELETE FROM test_users"
               })

      assert %{rows: [[3]]} = Repo.query!("SELECT count(*) FROM test_users")
    end

    test "runs with the principal as the actor, or the configured one" do
      Middleware.compile(%{before_query: [{Recorder, self()}]})
      on_exit(fn -> Middleware.compile(%{}) end)
      principal = %{id: 7, email: "ana@example.com"}
      args = %{"data_source" => "postgres", "statement" => "SELECT 1"}

      call!(client(@all, principal), "run_sql", args)
      assert_receive {:before_query, ^principal}

      mcp_config(actor: fn p -> [context: {:user, p.id}, scope: nil] end)
      call!(client(@all, principal), "run_sql", args)
      assert_receive {:before_query, {:user, 7}}
    end
  end

  describe "saved queries" do
    test "lists, gets and runs a saved query with variables" do
      query =
        query_fixture(%{
          name: "Active users",
          statement: "SELECT name FROM test_users WHERE active = {{active}} ORDER BY name",
          variables: [%{name: "active", type: :text, default: "true"}]
        })

      client = client()

      assert %{structured: %{"queries" => [%{"id" => id, "name" => "Active users"}]}} =
               call!(client, "list_queries", %{"search" => "active"})

      assert id == query.id

      assert %{
               structured: %{
                 "statement" => "SELECT name" <> _,
                 "variables" => [%{"name" => "active"}]
               }
             } =
               call!(client, "get_query", %{"id" => id})

      assert %{structured: %{"rows" => rows}} = call!(client, "run_query", %{"id" => id})
      assert length(rows) >= 2

      assert %{structured: %{"rows" => [["Charles Bukowski"]]}} =
               call!(client, "run_query", %{"id" => id, "vars" => %{"active" => "false"}})
    end

    test "a missing query is a tool error" do
      assert %{is_error: true, text: "No saved query with id 0"} =
               call!(client(), "run_query", %{"id" => 0})
    end

    test "saves and changes a query, with its variables" do
      client = client()

      assert %{structured: %{"id" => id, "variables" => [%{"name" => "min", "type" => "number"}]}} =
               call!(client, "save_query", %{
                 "name" => "Older users",
                 "statement" => "SELECT name, age FROM test_users WHERE age > {{min}}",
                 "data_source" => "postgres",
                 "variables" => [%{"name" => "min", "type" => "number", "default" => 40}]
               })

      assert %{variables: [%{default: "40"}]} = Lotus.get_query!(id)

      assert %{structured: %{"name" => "Oldest users"}} =
               call!(client, "update_query", %{"id" => id, "name" => "Oldest users"})

      # What was left out is unchanged.
      assert %{statement: "SELECT name, age" <> _, data_source: "postgres", variables: [_]} =
               Lotus.get_query!(id)

      assert %{is_error: true, text: "Nothing to change"} =
               call!(client, "update_query", %{"id" => id})

      assert %{is_error: true, text: "Only read-only queries are allowed" <> _} =
               call!(client, "save_query", %{
                 "name" => "Oops",
                 "statement" => "DELETE FROM test_users",
                 "data_source" => "postgres"
               })

      assert %{is_error: true} =
               call!(client, "update_query", %{"id" => id, "statement" => "DROP TABLE test_users"})

      assert %{is_error: true, text: "A variable's name must be" <> _} =
               call!(client, "save_query", %{
                 "name" => "Bad variable",
                 "statement" => "SELECT {{x y}}",
                 "data_source" => "postgres",
                 "variables" => [%{"name" => "x y", "type" => "text"}]
               })

      assert %{is_error: true, text: "name can't be blank"} =
               call!(client, "save_query", %{
                 "name" => "",
                 "statement" => "SELECT 1",
                 "data_source" => "postgres"
               })
    end
  end

  describe "charts" do
    setup do
      %{query: query_fixture(%{statement: "SELECT name, age FROM test_users"})}
    end

    test "saves a chart Lotus Web can show, and replaces it", %{query: query} do
      client = client()

      assert %{structured: %{"chart" => %{"config" => config}}} =
               call!(client, "save_chart", %{
                 "query_id" => query.id,
                 "chart_type" => "bar",
                 "x_field" => "name",
                 "y_field" => "age"
               })

      assert config == %{"chart_type" => "bar", "x_field" => "name", "y_field" => "age"}

      call!(client, "save_chart", %{
        "query_id" => query.id,
        "chart_type" => "kpi",
        "value_field" => "age",
        "label" => "Age"
      })

      assert [%{config: %{"chart_type" => "kpi", "value_field" => "age", "kpi_label" => "Age"}}] =
               Lotus.list_visualizations(query.id)
    end

    test "refuses a field that is not a column, and a missing one", %{query: query} do
      client = client()

      assert %{is_error: true, text: "Not a column of the query's result: y_field \"total\"" <> _} =
               call!(client, "save_chart", %{
                 "query_id" => query.id,
                 "chart_type" => "line",
                 "x_field" => "name",
                 "y_field" => "total"
               })

      assert %{is_error: true, text: "A line chart needs y_field"} =
               call!(client, "save_chart", %{
                 "query_id" => query.id,
                 "chart_type" => "line",
                 "x_field" => "name"
               })

      assert [] = Lotus.list_visualizations(query.id)
    end

    test "a token without lotus:query can't save a chart, which runs the query",
         %{query: query} do
      client = client(["lotus:read", "lotus:write"])
      test_pid = self()
      ref = make_ref()

      :telemetry.attach(
        ref,
        [:lotus, :query, :start],
        fn _, _, _, _ ->
          send(test_pid, :query_ran)
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(ref) end)

      assert {:error, {:insufficient_scope, %{scope: ["lotus:write", "lotus:query"]}}} =
               call_tool(client, "save_chart", %{
                 "query_id" => query.id,
                 "chart_type" => "kpi",
                 "value_field" => "age"
               })

      dashboard = dashboard_fixture(%{name: "Charts"})

      assert %{is_error: true, text: "A chart runs its query" <> _} =
               call!(client, "add_dashboard_card", %{
                 "dashboard_id" => dashboard.id,
                 "query_id" => query.id,
                 "chart_type" => "kpi",
                 "value_field" => "age"
               })

      assert %{structured: %{"card" => %{"title" => _}}} =
               call!(client, "add_dashboard_card", %{
                 "dashboard_id" => dashboard.id,
                 "query_id" => query.id
               })

      refute_received :query_ran
      assert [] = Lotus.list_visualizations(query.id)
    end
  end

  describe "dashboards" do
    test "creates a dashboard, adds cards below each other, and runs it" do
      query = query_fixture(%{name: "Users", statement: "SELECT name, age FROM test_users"})
      client = client()

      assert %{structured: %{"id" => id, "cards" => []}} =
               call!(client, "create_dashboard", %{"name" => "Team"})

      assert %{structured: %{"card" => %{"layout" => %{"y" => 0, "h" => 2}}}} =
               call!(client, "add_dashboard_card", %{
                 "dashboard_id" => id,
                 "type" => "heading",
                 "text" => "People",
                 "height" => 2,
                 "width" => 12
               })

      assert %{
               structured: %{
                 "card" => %{
                   "title" => "Users",
                   "layout" => %{"y" => 2, "w" => 6},
                   "chart" => %{"chart_type" => "bar"}
                 }
               }
             } =
               call!(client, "add_dashboard_card", %{
                 "dashboard_id" => id,
                 "query_id" => query.id,
                 "chart_type" => "bar",
                 "x_field" => "name",
                 "y_field" => "age"
               })

      assert %{is_error: true, text: "A query card needs query_id"} =
               call!(client, "add_dashboard_card", %{"dashboard_id" => id})

      assert %{structured: %{"dashboards" => [%{"name" => "Team"}]}} =
               call!(client, "list_dashboards", %{})

      assert %{structured: %{"cards" => [_, _]}} = call!(client, "get_dashboard", %{"id" => id})

      assert %{structured: %{"cards" => [%{"title" => "Users", "result" => %{"rows" => rows}}]}} =
               call!(client, "run_dashboard", %{"id" => id, "rows_per_card" => 2})

      assert length(rows) == 2
    end
  end

  describe "dashboards and the data_sources setting" do
    test "a card on a source the endpoint does not expose is left out" do
      shown = query_fixture(%{name: "Shown", data_source: "postgres"})
      hidden = query_fixture(%{name: "Hidden", statement: "SELECT 1", data_source: "sqlite"})
      dashboard = dashboard_fixture(%{name: "Mixed"})
      dashboard_card_fixture(dashboard, %{card_type: :query, query_id: shown.id, title: "Shown"})

      dashboard_card_fixture(dashboard, %{
        card_type: :query,
        query_id: hidden.id,
        title: "Hidden",
        position: 1
      })

      mcp_config(data_sources: ["postgres"])
      client = client()

      assert %{structured: %{"cards" => [%{"title" => "Shown"}]}} =
               call!(client, "get_dashboard", %{"id" => dashboard.id})

      assert %{structured: %{"cards" => [%{"title" => "Shown", "result" => _}]}} =
               call!(client, "run_dashboard", %{"id" => dashboard.id})
    end
  end

  describe "resources" do
    test "lists and reads saved queries and dashboards" do
      query = query_fixture(%{name: "Users"})
      dashboard = dashboard_fixture(%{name: "Team"})
      client = client()

      assert {:ok, resources} = list_resources(client)
      uris = Enum.map(resources, & &1["uri"])
      assert "lotus://queries/#{query.id}" in uris
      assert "lotus://dashboards/#{dashboard.id}" in uris

      assert {:ok, [%{text: text}]} = read_resource(client, "lotus://queries/#{query.id}")
      assert %{"name" => "Users", "statement" => "SELECT 1 as result"} = JSON.decode!(text)

      assert {:error, _} = read_resource(client, "lotus://queries/nope")
    end
  end
end
