defmodule Lotus.StorageTest do
  use Lotus.Case, async: true
  use Mimic

  import Lotus.Fixtures

  alias Lotus.Storage

  describe "list_queries/1" do
    test "returns empty list when no queries exist" do
      assert Storage.list_queries() == []
    end

    test "returns all queries" do
      query1 = query_fixture(%{name: "Users Query"})
      query2 = query_fixture(%{name: "Posts Query"})

      queries = Storage.list_queries()

      assert length(queries) == 2
      assert query1 in queries
      assert query2 in queries
    end
  end

  describe "list_queries_by/1" do
    setup do
      query1 = query_fixture(%{name: "Active Users"})
      query2 = query_fixture(%{name: "User Reports"})
      query3 = query_fixture(%{name: "Product Analytics"})

      {:ok, queries: %{users_analytics: query1, user_reports: query2, product_analytics: query3}}
    end

    test "returns all queries when no filters provided", %{queries: queries} do
      result = Storage.list_queries_by([])

      assert length(result) == 3
      assert queries.users_analytics in result
      assert queries.user_reports in result
      assert queries.product_analytics in result
    end

    test "filters by search term (case insensitive)", %{queries: queries} do
      result = Storage.list_queries_by(search: "user")

      assert length(result) == 2
      assert queries.users_analytics in result
      assert queries.user_reports in result
      refute queries.product_analytics in result
    end

    test "returns empty list when no matches found" do
      query_fixture(%{name: "Test Query"})

      result = Storage.list_queries_by(search: "nonexistent")
      assert result == []
    end
  end

  describe "get_query!/2" do
    test "returns query when found" do
      query = query_fixture(%{name: "Test Query"})

      result = Storage.get_query!(query.id)

      assert result.id == query.id
      assert result.name == "Test Query"
    end

    test "raises when query not found" do
      assert_raise Ecto.NoResultsError, fn ->
        Storage.get_query!(999_999)
      end
    end
  end

  describe "get_query/2" do
    test "returns query when found" do
      query = query_fixture(%{name: "Test Query"})

      result = Storage.get_query(query.id)

      assert result.id == query.id
      assert result.name == "Test Query"
    end

    test "returns nil when query not found" do
      assert Storage.get_query(999_999) == nil
    end

    test "retrieves query with string static_options correctly" do
      {:ok, query} =
        Storage.create_query(%{
          name: "String Options Query",
          statement: "SELECT * FROM users WHERE role = {{role}}",
          variables: [
            %{
              name: "role",
              type: :text,
              widget: :select,
              static_options: ["admin", "user", "guest"]
            }
          ]
        })

      retrieved = Storage.get_query(query.id)
      [variable] = retrieved.variables

      # Should get normalized map format
      assert [
               %{value: "admin", label: "admin"},
               %{value: "user", label: "user"},
               %{value: "guest", label: "guest"}
             ] = variable.static_options
    end

    test "retrieves query with tuple static_options correctly" do
      {:ok, query} =
        Storage.create_query(%{
          name: "Tuple Options Query",
          statement: "SELECT * FROM tasks WHERE status = {{status}}",
          variables: [
            %{
              name: "status",
              type: :text,
              widget: :select,
              static_options: [{"todo", "To Do"}, {"done", "Completed"}]
            }
          ]
        })

      retrieved = Storage.get_query(query.id)
      [variable] = retrieved.variables

      assert [
               %{value: "todo", label: "To Do"},
               %{value: "done", label: "Completed"}
             ] = variable.static_options
    end
  end

  describe "create_query/2" do
    test "creates query with valid attributes" do
      attrs = %{
        name: "New Query",
        description: "A test query",
        statement: "SELECT * FROM users"
      }

      assert {:ok, query} = Storage.create_query(attrs)
      assert query.name == "New Query"
      assert query.description == "A test query"
      assert query.statement == "SELECT * FROM users"
      assert query.id
      assert query.inserted_at
      assert query.updated_at
    end

    test "creates query with minimal attributes" do
      attrs = %{
        name: "Minimal Query",
        statement: "SELECT 1"
      }

      assert {:ok, query} = Storage.create_query(attrs)
      assert query.name == "Minimal Query"
      assert query.description == nil
      assert query.statement == "SELECT 1"
      assert query.data_source == nil
    end

    test "creates query with valid data_source" do
      attrs = %{
        name: "Analytics Query",
        statement: "SELECT COUNT(*) FROM page_views",
        data_source: "postgres"
      }

      assert {:ok, query} = Storage.create_query(attrs)
      assert query.data_source == "postgres"
    end

    test "normalizes empty string data_source to nil" do
      attrs = %{
        name: "Test Query",
        statement: "SELECT 1",
        data_source: ""
      }

      assert {:ok, query} = Storage.create_query(attrs)
      assert query.data_source == nil
    end

    test "returns error with invalid data_source" do
      attrs = %{
        name: "Invalid Source Query",
        statement: "SELECT 1",
        data_source: "nonexistent_repo"
      }

      assert {:error, changeset} = Storage.create_query(attrs)
      refute changeset.valid?
      assert %{data_source: [error_msg]} = errors_on(changeset)
      assert error_msg =~ "must be one of: mysql, postgres, sqlite"
    end

    test "returns error with invalid attributes" do
      attrs = %{name: "", statement: ""}

      assert {:error, changeset} = Storage.create_query(attrs)
      refute changeset.valid?

      assert %{
               name: ["can't be blank"],
               statement: ["can't be blank"]
             } = errors_on(changeset)
    end

    test "returns error when required fields missing" do
      attrs = %{}

      assert {:error, changeset} = Storage.create_query(attrs)
      refute changeset.valid?
      assert %{name: ["can't be blank"], statement: ["can't be blank"]} = errors_on(changeset)
    end

    test "creates query with string static_options" do
      attrs = %{
        name: "String Options Query",
        statement: "SELECT * FROM users WHERE role = {{role}}",
        variables: [
          %{
            name: "role",
            type: :text,
            widget: :select,
            static_options: ["admin", "user", "guest"]
          }
        ]
      }

      assert {:ok, query} = Storage.create_query(attrs)
      [variable] = query.variables

      assert [
               %{value: "admin", label: "admin"},
               %{value: "user", label: "user"},
               %{value: "guest", label: "guest"}
             ] = variable.static_options
    end

    test "creates query with tuple static_options" do
      attrs = %{
        name: "Tuple Options Query",
        statement: "SELECT * FROM tasks WHERE status = {{status}}",
        variables: [
          %{
            name: "status",
            type: :text,
            widget: :select,
            static_options: [
              {"todo", "To Do"},
              {"in_progress", "In Progress"},
              {"done", "Completed"}
            ]
          }
        ]
      }

      assert {:ok, query} = Storage.create_query(attrs)
      [variable] = query.variables

      assert [
               %{value: "todo", label: "To Do"},
               %{value: "in_progress", label: "In Progress"},
               %{value: "done", label: "Completed"}
             ] = variable.static_options
    end

    test "rejects query with mixed static_options format" do
      attrs = %{
        name: "Mixed Options Query",
        statement: "SELECT * FROM items WHERE priority = {{priority}}",
        variables: [
          %{
            name: "priority",
            type: :text,
            widget: :select,
            static_options: ["low", {"medium", "Medium Priority"}, "high"]
          }
        ]
      }

      assert {:error, changeset} = Storage.create_query(attrs)
      refute changeset.valid?

      # Check that the error is on the nested variable
      assert %{variables: [variable_errors]} = errors_on(changeset)
      assert %{static_options: [error_msg]} = variable_errors
      assert error_msg =~ "cannot mix different formats"
    end

    test "creates query with map static_options" do
      attrs = %{
        name: "Map Options Query",
        statement: "SELECT * FROM logs WHERE level = {{level}}",
        variables: [
          %{
            name: "level",
            type: :text,
            widget: :select,
            static_options: [
              %{"value" => "info", "label" => "Information"},
              %{"value" => "error", "label" => "Error"}
            ]
          }
        ]
      }

      assert {:ok, query} = Storage.create_query(attrs)
      [variable] = query.variables

      assert [
               %{value: "info", label: "Information"},
               %{value: "error", label: "Error"}
             ] = variable.static_options
    end
  end

  describe "update_query/3" do
    setup do
      {:ok,
       query:
         query_fixture(%{
           name: "Original Query",
           description: "Original description",
           statement: "SELECT * FROM users"
         })}
    end

    test "updates query with valid attributes", %{query: query} do
      attrs = %{
        name: "Updated Query",
        description: "Updated description"
      }

      assert {:ok, updated_query} = Storage.update_query(query, attrs)
      assert updated_query.id == query.id
      assert updated_query.name == "Updated Query"
      assert updated_query.description == "Updated description"
      assert updated_query.statement == "SELECT * FROM users"
    end

    test "updates only provided attributes", %{query: query} do
      attrs = %{name: "New Name Only"}

      assert {:ok, updated_query} = Storage.update_query(query, attrs)
      assert updated_query.name == "New Name Only"
      assert updated_query.description == "Original description"
    end

    test "updates statement", %{query: query} do
      attrs = %{statement: "SELECT count(*) FROM users"}

      assert {:ok, updated_query} = Storage.update_query(query, attrs)
      assert updated_query.statement == "SELECT count(*) FROM users"
    end

    test "returns error with invalid attributes", %{query: query} do
      attrs = %{name: "", statement: ""}

      assert {:error, changeset} = Storage.update_query(query, attrs)
      refute changeset.valid?

      assert %{
               name: ["can't be blank"],
               statement: ["can't be blank"]
             } = errors_on(changeset)
    end
  end

  describe "delete_query/2" do
    test "deletes existing query" do
      query = query_fixture(%{name: "To Delete"})

      assert {:ok, deleted_query} = Storage.delete_query(query)
      assert deleted_query.id == query.id

      assert_raise Ecto.NoResultsError, fn ->
        Storage.get_query!(query.id)
      end
    end
  end

  describe "run/2" do
    test "delegates to Lotus.run_query/2" do
      query =
        query_fixture(%{
          name: "Test Query",
          statement: "SELECT 1 as result"
        })

      expected_result = {:ok, %{"result" => 1}}

      Lotus
      |> expect(:run_query, fn ^query, [] -> expected_result end)

      result = Storage.run(query)

      assert result == expected_result
    end

    test "passes options through to Lotus.run_query/2" do
      query =
        query_fixture(%{
          name: "Test Query",
          statement: "SELECT 1 as result"
        })

      opts = [statement_timeout_ms: 3000, prefix: "analytics"]
      expected_result = {:ok, %{"result" => 1}}

      Lotus
      |> expect(:run_query, fn ^query, ^opts -> expected_result end)

      result = Storage.run(query, opts)

      assert result == expected_result
    end

    test "handles error responses from Lotus.run_query/2" do
      query =
        query_fixture(%{
          name: "Failing Query",
          statement: "SELECT invalid"
        })

      expected_error = {:error, "Invalid SQL"}

      Lotus
      |> expect(:run_query, fn ^query, [] -> expected_error end)

      result = Storage.run(query)

      assert result == expected_error
    end
  end
end
