defmodule Lotus.Storage.QueryTest do
  use Lotus.Case, async: true

  alias Lotus.Query.Statement
  alias Lotus.Storage.Query

  describe "new/1" do
    test "builds a valid changeset with required fields" do
      attrs = %{
        name: "Recent Users",
        statement: "SELECT * FROM users WHERE active = true"
      }

      changeset = Query.new(attrs)

      assert changeset.valid?
      assert get_field(changeset, :name) == "Recent Users"
      assert get_field(changeset, :statement) == "SELECT * FROM users WHERE active = true"
    end

    test "is invalid without required fields" do
      changeset = Query.new(%{})

      refute changeset.valid?
      assert %{name: ["can't be blank"], statement: ["can't be blank"]} = errors_on(changeset)
    end

    test "is invalid when name is empty" do
      changeset = Query.new(%{name: "", statement: "SELECT 1"})

      refute changeset.valid?
      assert %{name: ["can't be blank"]} = errors_on(changeset)
    end

    test "is invalid when statement is empty" do
      changeset = Query.new(%{name: "Test", statement: ""})

      refute changeset.valid?
      assert %{statement: ["can't be blank"]} = errors_on(changeset)
    end

    test "accepts valid search_path" do
      attrs = %{
        name: "Schema Query",
        statement: "SELECT * FROM users",
        search_path: "reporting, public"
      }

      changeset = Query.new(attrs)

      assert changeset.valid?
      assert get_field(changeset, :search_path) == "reporting, public"
    end

    test "accepts single schema in search_path" do
      changeset =
        Query.new(%{
          name: "Test",
          statement: "SELECT 1",
          search_path: "analytics"
        })

      assert changeset.valid?
      assert get_field(changeset, :search_path) == "analytics"
    end

    test "converts empty search_path to nil" do
      changeset =
        Query.new(%{
          name: "Test",
          statement: "SELECT 1",
          search_path: ""
        })

      assert changeset.valid?
      assert get_field(changeset, :search_path) == nil
    end

    test "is invalid with malformed search_path" do
      changeset =
        Query.new(%{
          name: "Test",
          statement: "SELECT 1",
          search_path: "invalid-schema, 123schema"
        })

      refute changeset.valid?

      assert %{search_path: ["must be a comma-separated list of identifiers"]} =
               errors_on(changeset)
    end

    test "is invalid when search_path is not a string" do
      changeset =
        Query.new(%{
          name: "Test",
          statement: "SELECT 1",
          search_path: 123
        })

      refute changeset.valid?
      assert %{search_path: ["is invalid"]} = errors_on(changeset)
    end

    test "accepts a family:dialect query_language" do
      changeset =
        Query.new(%{
          name: "Test",
          statement: "SELECT 1",
          query_language: "sql:postgres"
        })

      assert changeset.valid?
      assert get_field(changeset, :query_language) == "sql:postgres"
    end

    test "accepts a bare family query_language" do
      changeset =
        Query.new(%{name: "Test", statement: "SELECT 1", query_language: "sql"})

      assert changeset.valid?
      assert get_field(changeset, :query_language) == "sql"
    end

    test "accepts a non-SQL query_language" do
      changeset =
        Query.new(%{name: "Test", statement: "SELECT 1", query_language: "json:elasticsearch"})

      assert changeset.valid?
      assert get_field(changeset, :query_language) == "json:elasticsearch"
    end

    test "is valid without a query_language" do
      changeset = Query.new(%{name: "Test", statement: "SELECT 1"})

      assert changeset.valid?
      assert get_field(changeset, :query_language) == nil
    end

    test "converts empty query_language to nil" do
      changeset =
        Query.new(%{name: "Test", statement: "SELECT 1", query_language: ""})

      assert changeset.valid?
      assert get_field(changeset, :query_language) == nil
    end

    test "is invalid with a malformed query_language" do
      changeset =
        Query.new(%{name: "Test", statement: "SELECT 1", query_language: "SQL:Postgres!"})

      refute changeset.valid?

      assert %{query_language: ["must be a language identifier like \"sql\" or \"sql:postgres\""]} =
               errors_on(changeset)
    end

    test "is invalid when query_language is not a string" do
      changeset =
        Query.new(%{name: "Test", statement: "SELECT 1", query_language: 123})

      refute changeset.valid?
      assert %{query_language: ["is invalid"]} = errors_on(changeset)
    end
  end

  describe "update/2" do
    setup do
      {:ok, query: %Query{name: "Original", statement: "SELECT 1"}}
    end

    test "updates fields", %{query: query} do
      changeset = Query.update(query, %{name: "Updated"})

      assert changeset.valid?
      assert get_field(changeset, :name) == "Updated"
    end

    test "validates updated query statement", %{query: query} do
      changeset = Query.update(query, %{statement: ""})

      refute changeset.valid?
      assert %{statement: ["can't be blank"]} = errors_on(changeset)
    end
  end

  describe "compile/2" do
    test "returns {:ok, statement} on success" do
      q = %Query{
        statement: "SELECT * FROM users WHERE id = {{id}}",
        variables: [],
        data_source: "postgres"
      }

      assert {:ok, %Statement{body: "SELECT * FROM users WHERE id = $1", params: [1]}} =
               Query.compile(q, %{"id" => 1})
    end

    test "returns {:error, reason} when a required variable is missing" do
      q = %Query{
        statement: "SELECT * FROM users WHERE age > {{min_age}}",
        variables: [],
        data_source: "postgres"
      }

      assert {:error, "Missing required variable: min_age"} =
               Query.compile(q, %{})
    end

    test "returns {:error, reason} when a list variable is empty" do
      q = %Query{
        statement: "SELECT * FROM users WHERE country IN ({{countries}})",
        variables: [%{name: "countries", type: :text, list: true}],
        data_source: "postgres"
      }

      assert {:error, "List variable 'countries' must have at least one value"} =
               Query.compile(q, %{"countries" => []})
    end

    test "uses falsy supplied values (false, 0) instead of falling through to default" do
      q = %Query{
        statement: "SELECT * FROM users WHERE active = {{active}} AND age > {{age}}",
        variables: [
          %{name: "active", type: :boolean, default: true},
          %{name: "age", type: :number, default: "18"}
        ],
        data_source: "postgres"
      }

      assert {:ok, %Statement{params: [false, 0]}} =
               Query.compile(q, %{"active" => false, "age" => 0})
    end

    test "falls back to default when nil is explicitly supplied" do
      q = %Query{
        statement: "SELECT * FROM users WHERE status = {{status}}",
        variables: [%{name: "status", type: :text, default: "active"}],
        data_source: "postgres"
      }

      assert {:ok, %Statement{params: ["active"]}} =
               Query.compile(q, %{"status" => nil})
    end

    test "returns {:error, reason} when a value fails type casting" do
      q = %Query{
        statement: "SELECT * FROM users WHERE age > {{min_age}}",
        variables: [%{name: "min_age", type: :number}],
        data_source: "postgres"
      }

      assert {:error, "Invalid number format: 'not-a-number'" <> _} =
               Query.compile(q, %{"min_age" => "not-a-number"})
    end
  end

  describe "compile!/2" do
    test "compile with PostgreSQL adapter uses $N placeholders" do
      q = %Query{
        statement: "SELECT * FROM users WHERE age > {{min_age}} AND active = {{active}}",
        variables: [],
        data_source: "postgres"
      }

      %Statement{body: sql, params: params} =
        Query.compile!(q, %{"min_age" => 30, "active" => true})

      assert sql == "SELECT * FROM users WHERE age > $1 AND active = $2"
      assert params == [30, true]
    end

    @tag :sqlite
    test "compile with SQLite adapter uses ? placeholders" do
      q = %Query{
        statement: "SELECT * FROM users WHERE age > {{min_age}} AND active = {{active}}",
        variables: [],
        data_source: "sqlite"
      }

      %Statement{body: sql, params: params} =
        Query.compile!(q, %{"min_age" => 30, "active" => true})

      assert sql == "SELECT * FROM users WHERE age > ? AND active = ?"
      assert params == [30, true]
    end

    test "compile with nil data_source defaults to PostgreSQL style" do
      q = %Query{
        statement: "SELECT * FROM users WHERE id = {{id}}",
        variables: [],
        data_source: nil
      }

      %Statement{body: sql, params: params} = Query.compile!(q, %{"id" => 123})

      assert sql == "SELECT * FROM users WHERE id = $1"
      assert params == [123]
    end

    test "uses query variable defaults when supplied_vars are not provided (PostgreSQL)" do
      q = %Query{
        statement: "SELECT * FROM users WHERE age > {{min_age}}",
        variables: [
          %{name: "min_age", type: :number, default: "40"}
        ],
        data_source: "postgres"
      }

      %Statement{body: sql, params: params} = Query.compile!(q, %{})

      assert sql == "SELECT * FROM users WHERE age > $1::numeric"
      assert params == [40]
    end

    @tag :sqlite
    test "uses query variable defaults when supplied_vars are not provided (SQLite)" do
      q = %Query{
        statement: "SELECT * FROM users WHERE age > {{min_age}}",
        variables: [
          %{name: "min_age", type: :number, default: "40"}
        ],
        data_source: "sqlite"
      }

      %Statement{body: sql, params: params} = Query.compile!(q, %{})

      assert sql == "SELECT * FROM users WHERE age > ?"
      assert params == [40]
    end

    test "raises if required variable missing and there is no query variable default" do
      q = %Query{
        statement: "SELECT * FROM users WHERE age > {{min_age}}",
        variables: []
      }

      assert_raise ArgumentError, ~r/Missing required variable: min_age/, fn ->
        Query.compile!(q, %{})
      end
    end

    test "ignores unused query variables" do
      q = %Query{
        statement: "SELECT * FROM users",
        variables: [
          %{name: "unused", type: :text, default: "value"}
        ]
      }

      %Statement{body: sql, params: params} = Query.compile!(q, %{})
      assert sql == "SELECT * FROM users"
      assert params == []
    end

    test "handles multiple occurrences of the same variable (PostgreSQL)" do
      q = %Query{
        statement: "SELECT * FROM users WHERE name = {{name}} OR nickname = {{name}}",
        variables: [
          %{name: "name", type: :text, default: "Jack"}
        ],
        data_source: "postgres"
      }

      %Statement{body: sql, params: params} = Query.compile!(q, %{})

      assert sql == "SELECT * FROM users WHERE name = $1 OR nickname = $2"
      assert params == ["Jack", "Jack"]
    end

    @tag :sqlite
    test "handles multiple occurrences of the same variable (SQLite)" do
      q = %Query{
        statement: "SELECT * FROM users WHERE name = {{name}} OR nickname = {{name}}",
        variables: [
          %{name: "name", type: :text, default: "Jack"}
        ],
        data_source: "sqlite"
      }

      %Statement{body: sql, params: params} = Query.compile!(q, %{})

      assert sql == "SELECT * FROM users WHERE name = ? OR nickname = ?"
      assert params == ["Jack", "Jack"]
    end

    test "overrides query variable defaults with provided supplied_vars" do
      q = %Query{
        statement: "SELECT * FROM users WHERE status = {{status}}",
        variables: [
          %{name: "status", type: :text, default: "inactive"}
        ],
        data_source: "postgres"
      }

      %Statement{body: sql, params: params} = Query.compile!(q, %{"status" => "active"})

      assert sql == "SELECT * FROM users WHERE status = $1"
      assert params == ["active"]
    end

    test "raises when nil value is provided" do
      q = %Query{
        statement: "SELECT * FROM users WHERE deleted_at IS {{deleted}}",
        variables: [],
        data_source: "postgres"
      }

      assert_raise ArgumentError, ~r/Missing required variable: deleted/, fn ->
        Query.compile!(q, %{"deleted" => nil})
      end
    end

    test "preserves var order in params list" do
      q = %Query{
        statement: "INSERT INTO users (name, age, email) VALUES ({{name}}, {{age}}, {{email}})",
        variables: [],
        data_source: "postgres"
      }

      %Statement{body: sql, params: params} =
        Query.compile!(q, %{"name" => "John", "age" => 30, "email" => "john@example.com"})

      assert sql == "INSERT INTO users (name, age, email) VALUES ($1, $2, $3)"
      assert params == ["John", 30, "john@example.com"]
    end
  end

  describe "variables field" do
    test "accepts valid variables" do
      attrs = %{
        name: "Test Query",
        statement: "SELECT * FROM users WHERE org_id = {{org_id}} AND status = {{status}}",
        variables: [
          %{name: "org_id", type: :number, label: "Organization ID", default: "1"},
          %{name: "status", type: :text, label: "Status", default: "active"}
        ]
      }

      changeset = Query.new(attrs)

      assert changeset.valid?
      variables = get_field(changeset, :variables)
      assert length(variables) == 2

      org_var = Enum.find(variables, &(&1.name == "org_id"))
      assert org_var.type == :number
      assert org_var.label == "Organization ID"
      assert org_var.default == "1"

      status_var = Enum.find(variables, &(&1.name == "status"))
      assert status_var.type == :text
      assert status_var.label == "Status"
      assert status_var.default == "active"
    end

    test "accepts variables with select widgets and static_options" do
      attrs = %{
        name: "Test Query",
        statement: "SELECT * FROM users WHERE status = {{status}}",
        variables: [
          %{
            name: "status",
            type: :text,
            widget: :select,
            label: "Status",
            static_options: ["active", "inactive", "pending"]
          }
        ]
      }

      changeset = Query.new(attrs)

      assert changeset.valid?
      variables = get_field(changeset, :variables)
      status_var = hd(variables)
      assert status_var.widget == :select

      assert [
               %{value: "active", label: "active"},
               %{value: "inactive", label: "inactive"},
               %{value: "pending", label: "pending"}
             ] = status_var.static_options
    end

    test "accepts variables with select widgets and options_query" do
      attrs = %{
        name: "Test Query",
        statement: "SELECT * FROM users WHERE org_id = {{org_id}}",
        variables: [
          %{
            name: "org_id",
            type: :number,
            widget: :select,
            label: "Organization",
            options_query: "SELECT id, name FROM orgs ORDER BY name"
          }
        ]
      }

      changeset = Query.new(attrs)

      assert changeset.valid?
      variables = get_field(changeset, :variables)
      org_var = hd(variables)
      assert org_var.widget == :select
      assert org_var.options_query == "SELECT id, name FROM orgs ORDER BY name"
    end

    test "rejects variables with invalid types" do
      attrs = %{
        name: "Test Query",
        statement: "SELECT * FROM users",
        variables: [
          %{name: "invalid", type: :invalid_type, label: "Invalid"}
        ]
      }

      changeset = Query.new(attrs)

      refute changeset.valid?
      assert %{variables: [%{type: ["is invalid"]}]} = errors_on(changeset)
    end

    test "rejects variables with invalid widgets" do
      attrs = %{
        name: "Test Query",
        statement: "SELECT * FROM users",
        variables: [
          %{name: "test", type: :text, widget: :invalid_widget, label: "Test"}
        ]
      }

      changeset = Query.new(attrs)

      refute changeset.valid?
      assert %{variables: [%{widget: ["is invalid"]}]} = errors_on(changeset)
    end

    test "rejects select widgets without options" do
      attrs = %{
        name: "Test Query",
        statement: "SELECT * FROM users WHERE status = {{status}}",
        variables: [
          %{
            name: "status",
            type: :text,
            widget: :select,
            label: "Status"
          }
        ]
      }

      changeset = Query.new(attrs)

      refute changeset.valid?

      assert %{
               variables: [
                 %{widget: ["select must define either static_options or options_query"]}
               ]
             } = errors_on(changeset)
    end

    test "sets default widget to input when not specified" do
      attrs = %{
        name: "Test Query",
        statement: "SELECT * FROM users WHERE name = {{name}}",
        variables: [
          %{name: "name", type: :text, label: "Name"}
        ]
      }

      changeset = Query.new(attrs)

      assert changeset.valid?
      variables = get_field(changeset, :variables)
      name_var = hd(variables)
      assert name_var.widget == :input
    end
  end

  describe "variable type casting" do
    test "casts number type from string" do
      q = %Query{
        statement: "SELECT * FROM users WHERE age > {{min_age}}",
        variables: [
          %{name: "min_age", type: :number, default: "30"}
        ],
        data_source: "postgres"
      }

      %Statement{body: sql, params: params} = Query.compile!(q, %{})

      assert sql == "SELECT * FROM users WHERE age > $1::numeric"
      assert params == [30]
    end

    test "casts date type from string" do
      q = %Query{
        statement: "SELECT * FROM users WHERE created_at >= {{since}}",
        variables: [
          %{name: "since", type: :date, default: "2024-01-01"}
        ],
        data_source: "postgres"
      }

      %Statement{body: sql, params: params} = Query.compile!(q, %{})

      assert sql == "SELECT * FROM users WHERE created_at >= $1::date"
      assert params == [~D[2024-01-01]]
    end

    test "handles text type without casting" do
      q = %Query{
        statement: "SELECT * FROM users WHERE status = {{status}}",
        variables: [
          %{name: "status", type: :text, default: "active"}
        ],
        data_source: "postgres"
      }

      %Statement{body: sql, params: params} = Query.compile!(q, %{})

      assert sql == "SELECT * FROM users WHERE status = $1"
      assert params == ["active"]
    end

    test "casts runtime supplied values" do
      q = %Query{
        statement: "SELECT * FROM users WHERE age > {{min_age}} AND created_at >= {{since}}",
        variables: [
          %{name: "min_age", type: :number},
          %{name: "since", type: :date}
        ],
        data_source: "postgres"
      }

      %Statement{body: sql, params: params} =
        Query.compile!(q, %{"min_age" => "25", "since" => "2024-06-01"})

      assert sql == "SELECT * FROM users WHERE age > $1::numeric AND created_at >= $2::date"
      assert params == [25, ~D[2024-06-01]]
    end

    test "runtime values override defaults with casting" do
      q = %Query{
        statement: "SELECT * FROM users WHERE age > {{min_age}}",
        variables: [
          %{name: "min_age", type: :number, default: "30"}
        ],
        data_source: "postgres"
      }

      %Statement{body: sql, params: params} = Query.compile!(q, %{"min_age" => "45"})

      assert sql == "SELECT * FROM users WHERE age > $1::numeric"
      assert params == [45]
    end

    test "handles variables without type metadata" do
      q = %Query{
        statement: "SELECT * FROM users WHERE name = {{name}}",
        variables: [],
        data_source: "postgres"
      }

      %Statement{body: sql, params: params} = Query.compile!(q, %{"name" => "John"})

      assert sql == "SELECT * FROM users WHERE name = $1"
      assert params == ["John"]
    end
  end

  describe "comprehensive variable scenarios" do
    test "complex query with mixed variable types and widgets" do
      attrs = %{
        name: "User Report",
        statement: """
        SELECT u.* FROM users u
        WHERE u.org_id = {{org_id}}
          AND u.created_at >= {{since_date}}
          AND u.status = {{status}}
          AND u.age > {{min_age}}
        """,
        variables: [
          %{
            name: "org_id",
            type: :number,
            widget: :select,
            label: "Organization",
            options_query: "SELECT id, name FROM orgs ORDER BY name"
          },
          %{
            name: "since_date",
            type: :date,
            label: "Created Since",
            default: "2024-01-01"
          },
          %{
            name: "status",
            type: :text,
            widget: :select,
            label: "Status",
            static_options: ["active", "inactive", "pending"],
            default: "active"
          },
          %{
            name: "min_age",
            type: :number,
            label: "Minimum Age",
            default: "18"
          }
        ]
      }

      changeset = Query.new(attrs)
      assert changeset.valid?

      # Test with the query struct
      q = %Query{
        statement: String.trim(attrs.statement),
        variables: get_field(changeset, :variables),
        data_source: "postgres"
      }

      # org_id has no default, so it should raise an error when called with empty vars
      assert_raise ArgumentError, ~r/Missing required variable: org_id/, fn ->
        Query.compile!(q, %{})
      end

      # Test with runtime values
      %Statement{body: sql, params: params} =
        Query.compile!(q, %{
          "org_id" => "5",
          "since_date" => "2024-06-01",
          "status" => "pending",
          "min_age" => "25"
        })

      expected_sql =
        "SELECT u.* FROM users u\nWHERE u.org_id = $1::numeric\n  AND u.created_at >= $2::date\n  AND u.status = $3\n  AND u.age > $4::numeric"

      assert sql == expected_sql
      assert params == [5, ~D[2024-06-01], "pending", 25]
    end

    test "handles validation errors in variable definitions" do
      attrs = %{
        name: "Invalid Query",
        statement: "SELECT * FROM users",
        variables: [
          # Missing required name field
          %{type: :text, label: "Test"},
          # Missing required type field
          %{name: "test2", label: "Test 2"},
          # Select widget without options
          %{name: "test3", type: :text, widget: :select, label: "Test 3"}
        ]
      }

      changeset = Query.new(attrs)

      refute changeset.valid?
      errors = errors_on(changeset)

      assert %{variables: variable_errors} = errors
      assert length(variable_errors) == 3

      # Check specific error patterns
      assert Enum.any?(variable_errors, fn errors ->
               Map.has_key?(errors, :name) and "can't be blank" in errors.name
             end)

      assert Enum.any?(variable_errors, fn errors ->
               Map.has_key?(errors, :type) and "can't be blank" in errors.type
             end)

      assert Enum.any?(variable_errors, fn errors ->
               Map.has_key?(errors, :widget) and
                 "select must define either static_options or options_query" in errors.widget
             end)
    end
  end

  describe "extract_variables_from_statement/1" do
    test "extracts variables in first-seen order and deduplicates" do
      sql = """
      SELECT * FROM users
      WHERE id = {{id}} AND status = {{status}} OR id = {{id}}
      """

      assert ["id", "status"] == Query.extract_variables_from_statement(sql)
    end

    test "returns [] when there are no variables" do
      sql = "SELECT * FROM users WHERE active = TRUE"
      assert [] == Query.extract_variables_from_statement(sql)
    end

    test "handles adjacent variables" do
      sql = "SELECT {{a}},{{b}},{{a}} FROM t"
      assert ["a", "b"] == Query.extract_variables_from_statement(sql)
    end

    test "trims whitespace around variable names" do
      sql = "WHERE x = {{   foo  }} AND y = {{bar}}"
      assert ["foo", "bar"] == Query.extract_variables_from_statement(sql)
    end

    test "allows underscores and digits (as content), keeps first occurrence" do
      sql = "SELECT * FROM t WHERE k={{user_id_2}} AND k2={{user_id_2}}"
      assert ["user_id_2"] == Query.extract_variables_from_statement(sql)
    end
  end

  describe "automatic type detection integration" do
    test "uses automatic UUID casting when column type detected" do
      # When auto-detection returns :uuid type, should cast to binary
      q = %Query{
        statement: "SELECT * FROM users WHERE users.id = {{user_id}}",
        variables: [],
        data_source: "postgres"
      }

      uuid_string = "550e8400-e29b-41d4-a716-446655440000"

      # This tests the flow - automatic detection would find users.id
      # Since schema cache isn't available in unit tests, it falls back to text
      %Statement{body: sql, params: params} = Query.compile!(q, %{"user_id" => uuid_string})

      assert sql == "SELECT * FROM users WHERE users.id = $1"
      # Without schema cache, value passes through as-is
      assert params == [uuid_string]
    end

    test "manual type takes precedence when auto-detection returns :text" do
      q = %Query{
        statement: "SELECT * FROM users WHERE age = {{min_age}}",
        variables: [
          %{name: "min_age", type: :number}
        ],
        data_source: "postgres"
      }

      %Statement{body: sql, params: params} = Query.compile!(q, %{"min_age" => "25"})

      # Manual type :number triggers casting and placeholder
      assert sql == "SELECT * FROM users WHERE age = $1::numeric"
      assert params == [25]
    end

    test "handles missing schema cache gracefully" do
      # Query with explicit table.column pattern
      q = %Query{
        statement: "SELECT * FROM orders WHERE orders.total = {{amount}}",
        variables: [],
        data_source: "postgres"
      }

      # Should not crash when schema cache unavailable
      %Statement{body: sql, params: params} = Query.compile!(q, %{"amount" => "100.50"})

      assert sql == "SELECT * FROM orders WHERE orders.total = $1"
      assert params == ["100.50"]
    end

    test "variable resolver extracts binding info from SQL" do
      # This tests that variable resolver correctly parses table.column patterns
      q = %Query{
        statement: """
        SELECT * FROM users u
        JOIN orders o ON o.user_id = u.id
        WHERE u.status = {{status}}
        """,
        variables: [],
        data_source: "postgres"
      }

      %Statement{body: sql, params: params} = Query.compile!(q, %{"status" => "active"})

      assert sql =~ "WHERE u.status = $1"
      assert params == ["active"]
    end
  end

  describe "type casting error handling" do
    test "raises ArgumentError for invalid number format with manual type" do
      q = %Query{
        statement: "SELECT * FROM users WHERE age > {{min_age}}",
        variables: [
          %{name: "min_age", type: :number}
        ],
        data_source: "postgres"
      }

      assert_raise ArgumentError, ~r/Invalid number format/, fn ->
        Query.compile!(q, %{"min_age" => "not-a-number"})
      end
    end

    test "raises ArgumentError for invalid date format with manual type" do
      q = %Query{
        statement: "SELECT * FROM users WHERE created_at >= {{since}}",
        variables: [
          %{name: "since", type: :date}
        ],
        data_source: "postgres"
      }

      assert_raise ArgumentError, ~r/Invalid date format/, fn ->
        Query.compile!(q, %{"since" => "not-a-date"})
      end
    end

    test "allows through values without type specification" do
      q = %Query{
        statement: "SELECT * FROM users WHERE name = {{name}}",
        variables: [],
        data_source: "postgres"
      }

      # No type, so value passes through as-is
      %Statement{body: _sql, params: params} = Query.compile!(q, %{"name" => "John"})
      assert params == ["John"]
    end
  end

  describe "list variable expansion" do
    test "list variable expands to multiple placeholders (PostgreSQL)" do
      q = %Query{
        statement: "SELECT * FROM users WHERE country IN ({{countries}})",
        variables: [
          %{name: "countries", type: :text, list: true}
        ],
        data_source: "postgres"
      }

      %Statement{body: sql, params: params} =
        Query.compile!(q, %{"countries" => ["US", "UK", "DE"]})

      assert sql == "SELECT * FROM users WHERE country IN ($1, $2, $3)"
      assert params == ["US", "UK", "DE"]
    end

    @tag :sqlite
    test "list variable expands to multiple placeholders (SQLite)" do
      q = %Query{
        statement: "SELECT * FROM users WHERE country IN ({{countries}})",
        variables: [
          %{name: "countries", type: :text, list: true}
        ],
        data_source: "sqlite"
      }

      %Statement{body: sql, params: params} =
        Query.compile!(q, %{"countries" => ["US", "UK", "DE"]})

      assert sql == "SELECT * FROM users WHERE country IN (?, ?, ?)"
      assert params == ["US", "UK", "DE"]
    end

    test "list + scalar variable: correct index sequencing" do
      q = %Query{
        statement: "SELECT * FROM users WHERE country IN ({{countries}}) AND age > {{min_age}}",
        variables: [
          %{name: "countries", type: :text, list: true},
          %{name: "min_age", type: :number}
        ],
        data_source: "postgres"
      }

      %Statement{body: sql, params: params} =
        Query.compile!(q, %{"countries" => ["US", "UK"], "min_age" => "18"})

      assert sql ==
               "SELECT * FROM users WHERE country IN ($1, $2) AND age > $3::numeric"

      assert params == ["US", "UK", 18]
    end

    test "list with number type casting" do
      q = %Query{
        statement: "SELECT * FROM orders WHERE id IN ({{ids}})",
        variables: [
          %{name: "ids", type: :number, list: true}
        ],
        data_source: "postgres"
      }

      %Statement{body: sql, params: params} = Query.compile!(q, %{"ids" => ["1", "2", "3"]})

      assert sql == "SELECT * FROM orders WHERE id IN ($1::numeric, $2::numeric, $3::numeric)"
      assert params == [1, 2, 3]
    end

    test "empty list raises ArgumentError" do
      q = %Query{
        statement: "SELECT * FROM users WHERE country IN ({{countries}})",
        variables: [
          %{name: "countries", type: :text, list: true}
        ],
        data_source: "postgres"
      }

      assert_raise ArgumentError, ~r/must have at least one value/, fn ->
        Query.compile!(q, %{"countries" => []})
      end
    end

    test "comma-separated string is normalized to list" do
      q = %Query{
        statement: "SELECT * FROM users WHERE country IN ({{countries}})",
        variables: [
          %{name: "countries", type: :text, list: true}
        ],
        data_source: "postgres"
      }

      %Statement{body: sql, params: params} = Query.compile!(q, %{"countries" => "US, UK, DE"})

      assert sql == "SELECT * FROM users WHERE country IN ($1, $2, $3)"
      assert params == ["US", "UK", "DE"]
    end

    test "single value in list works" do
      q = %Query{
        statement: "SELECT * FROM users WHERE country IN ({{countries}})",
        variables: [
          %{name: "countries", type: :text, list: true}
        ],
        data_source: "postgres"
      }

      %Statement{body: sql, params: params} = Query.compile!(q, %{"countries" => ["US"]})

      assert sql == "SELECT * FROM users WHERE country IN ($1)"
      assert params == ["US"]
    end

    test "scalar variable after list gets correct index" do
      q = %Query{
        statement:
          "SELECT * FROM orders WHERE status = {{status}} AND country IN ({{countries}}) AND age > {{min_age}}",
        variables: [
          %{name: "status", type: :text},
          %{name: "countries", type: :text, list: true},
          %{name: "min_age", type: :number}
        ],
        data_source: "postgres"
      }

      %Statement{body: sql, params: params} =
        Query.compile!(q, %{
          "status" => "active",
          "countries" => ["US", "UK", "DE"],
          "min_age" => "21"
        })

      assert sql ==
               "SELECT * FROM orders WHERE status = $1 AND country IN ($2, $3, $4) AND age > $5::numeric"

      assert params == ["active", "US", "UK", "DE", 21]
    end
  end

  describe "optional clauses ([[...]])" do
    test "value provided — brackets stripped, clause kept" do
      q = %Query{
        statement: "SELECT * FROM users WHERE 1=1 [[AND status = {{status}}]]",
        variables: [],
        data_source: "postgres"
      }

      %Statement{body: sql, params: params} = Query.compile!(q, %{"status" => "active"})

      assert sql == "SELECT * FROM users WHERE 1=1 AND status = $1"
      assert params == ["active"]
    end

    test "no value — clause stripped, no error" do
      q = %Query{
        statement: "SELECT * FROM users WHERE 1=1 [[AND status = {{status}}]]",
        variables: [],
        data_source: "postgres"
      }

      %Statement{body: sql, params: params} = Query.compile!(q, %{})

      assert sql == "SELECT * FROM users WHERE 1=1 "
      assert params == []
    end

    test "mixed required + optional variables" do
      q = %Query{
        statement: "SELECT * FROM users WHERE id = {{id}} [[AND status = {{status}}]]",
        variables: [],
        data_source: "postgres"
      }

      %Statement{body: sql, params: params} = Query.compile!(q, %{"id" => 1})

      assert sql == "SELECT * FROM users WHERE id = $1 "
      assert params == [1]
    end

    test "optional clause with list variable" do
      q = %Query{
        statement: "SELECT * FROM users WHERE 1=1 [[AND country IN ({{countries}})]]",
        variables: [
          %{name: "countries", type: :text, list: true}
        ],
        data_source: "postgres"
      }

      # With values
      %Statement{body: sql, params: params} = Query.compile!(q, %{"countries" => ["US", "UK"]})
      assert sql == "SELECT * FROM users WHERE 1=1 AND country IN ($1, $2)"
      assert params == ["US", "UK"]

      # Without values — clause removed
      %Statement{body: sql, params: params} = Query.compile!(q, %{})
      assert sql == "SELECT * FROM users WHERE 1=1 "
      assert params == []
    end

    test "extract_optional_variable_names/1" do
      sql =
        "SELECT * FROM users WHERE id = {{id}} [[AND name = {{name}}]] [[AND status = {{status}}]]"

      assert Query.extract_optional_variable_names(sql) == MapSet.new(["name", "status"])
    end
  end

  describe "database-specific placeholder generation" do
    test "PostgreSQL uses typed placeholders for known types" do
      q = %Query{
        statement: "SELECT * FROM users WHERE created = {{date}}",
        variables: [%{name: "date", type: :date}],
        data_source: "postgres"
      }

      %Statement{body: sql, params: _} = Query.compile!(q, %{"date" => "2024-01-01"})
      assert sql =~ "$1::date"
    end

    @tag :mysql
    test "MySQL uses CAST for typed placeholders" do
      q = %Query{
        statement: "SELECT * FROM users WHERE created = {{date}}",
        variables: [%{name: "date", type: :date}],
        data_source: "mysql"
      }

      %Statement{body: sql, params: _} = Query.compile!(q, %{"date" => "2024-01-01"})
      assert sql =~ "CAST(? AS DATE)"
    end

    @tag :sqlite
    test "SQLite uses plain placeholders" do
      q = %Query{
        statement: "SELECT * FROM users WHERE created = {{date}}",
        variables: [%{name: "date", type: :date}],
        data_source: "sqlite"
      }

      %Statement{body: sql, params: _} = Query.compile!(q, %{"date" => "2024-01-01"})
      assert sql =~ "?"
      refute sql =~ "CAST"
    end
  end
end
