defmodule Lotus.Storage.VariableResolverTest do
  use Lotus.Case, async: true

  alias Lotus.Storage.VariableResolver

  describe "resolve_variables/1 with explicit bindings" do
    test "extracts table.column = {{var}} pattern" do
      sql = "SELECT * FROM users WHERE users.id = {{user_id}}"

      result = VariableResolver.resolve_variables(sql)

      assert [%{variable: "user_id", table: "users", column: "id"}] = result
    end

    test "extracts multiple explicit bindings" do
      sql = """
      SELECT * FROM users
      WHERE users.id = {{id}}
        AND users.email = {{email}}
        AND users.status = {{status}}
      """

      result = VariableResolver.resolve_variables(sql)

      assert length(result) == 3

      assert Enum.any?(
               result,
               &(&1.variable == "id" and &1.table == "users" and &1.column == "id")
             )

      assert Enum.any?(
               result,
               &(&1.variable == "email" and &1.table == "users" and &1.column == "email")
             )

      assert Enum.any?(
               result,
               &(&1.variable == "status" and &1.table == "users" and &1.column == "status")
             )
    end

    test "handles different table for each binding" do
      sql = """
      SELECT * FROM users u
      JOIN orders o ON o.user_id = u.id
      WHERE users.id = {{user_id}}
        AND orders.total = {{order_total}}
      """

      result = VariableResolver.resolve_variables(sql)

      assert Enum.any?(result, &(&1.variable == "user_id" and &1.table == "users"))
      assert Enum.any?(result, &(&1.variable == "order_total" and &1.table == "orders"))
    end
  end

  describe "resolve_variables/1 with table aliases" do
    test "resolves simple alias from FROM clause" do
      sql = "SELECT * FROM users u WHERE u.id = {{user_id}}"

      result = VariableResolver.resolve_variables(sql)

      assert [%{variable: "user_id", table: "users", column: "id"}] = result
    end

    test "resolves alias with AS keyword" do
      sql = "SELECT * FROM users AS u WHERE u.id = {{user_id}}"

      result = VariableResolver.resolve_variables(sql)

      assert [%{variable: "user_id", table: "users", column: "id"}] = result
    end

    test "resolves JOIN alias" do
      sql = """
      SELECT * FROM users u
      JOIN orders o ON o.user_id = u.id
      WHERE o.total = {{order_total}}
      """

      result = VariableResolver.resolve_variables(sql)

      assert Enum.any?(result, &(&1.variable == "order_total" and &1.table == "orders"))
    end

    test "resolves multiple JOIN aliases" do
      sql = """
      SELECT * FROM users u
      JOIN orders o ON o.user_id = u.id
      JOIN products p ON p.id = o.product_id
      WHERE u.status = {{user_status}}
        AND o.total = {{order_total}}
        AND p.price = {{product_price}}
      """

      result = VariableResolver.resolve_variables(sql)

      assert Enum.any?(result, &(&1.variable == "user_status" and &1.table == "users"))
      assert Enum.any?(result, &(&1.variable == "order_total" and &1.table == "orders"))
      assert Enum.any?(result, &(&1.variable == "product_price" and &1.table == "products"))
    end
  end

  describe "resolve_variables/1 with implicit bindings" do
    test "infers table from FROM clause" do
      sql = "SELECT * FROM users WHERE id = {{user_id}}"

      result = VariableResolver.resolve_variables(sql)

      assert [%{variable: "user_id", table: "users", column: "id"}] = result
    end

    test "infers table for multiple implicit variables" do
      sql = """
      SELECT * FROM orders
      WHERE status = {{status}} AND total > {{min_total}}
      """

      result = VariableResolver.resolve_variables(sql)

      assert length(result) == 2
      assert Enum.all?(result, &(&1.table == "orders"))
    end

    test "uses first table from FROM clause" do
      sql = """
      SELECT * FROM users, orders
      WHERE id = {{user_id}}
      """

      result = VariableResolver.resolve_variables(sql)

      # Should use "users" as primary table (first in FROM)
      assert [%{variable: "user_id", table: "users"}] = result
    end
  end

  describe "resolve_variables/1 precedence and deduplication" do
    test "explicit binding takes precedence over implicit" do
      sql = """
      SELECT * FROM users
      WHERE users.id = {{user_id}}
        AND id = {{user_id}}
      """

      result = VariableResolver.resolve_variables(sql)

      # Should only have one binding (deduplicated)
      assert length(result) == 1
      assert [%{variable: "user_id", table: "users", column: "id"}] = result
    end

    test "deduplicates by variable name" do
      sql = """
      SELECT * FROM users
      WHERE users.id = {{id}} OR users.backup_id = {{id}}
      """

      result = VariableResolver.resolve_variables(sql)

      # Only first occurrence kept
      assert length(result) == 1
      assert [%{variable: "id"}] = result
    end
  end

  describe "resolve_variables/1 edge cases" do
    test "handles SQL with no variables" do
      sql = "SELECT * FROM users WHERE active = true"

      result = VariableResolver.resolve_variables(sql)

      assert result == []
    end

    test "handles SQL with single-line comments" do
      sql = """
      SELECT * FROM users
      -- This is a comment with {{fake_var}}
      WHERE users.id = {{real_id}}
      """

      result = VariableResolver.resolve_variables(sql)

      # Should only find real_id, not fake_var in comment
      assert [%{variable: "real_id"}] = result
    end

    test "handles SQL with multi-line comments" do
      sql = """
      SELECT * FROM users
      /* This is a comment
         with {{fake_var}} inside */
      WHERE users.id = {{real_id}}
      """

      result = VariableResolver.resolve_variables(sql)

      assert [%{variable: "real_id"}] = result
    end

    test "handles case-insensitive SQL keywords" do
      sql = "select * FROM Users WHERE users.id = {{user_id}}"

      result = VariableResolver.resolve_variables(sql)

      assert [%{variable: "user_id", table: "users"}] = result
    end

    test "handles extra whitespace" do
      sql = "SELECT   *   FROM   users   WHERE   users.id   =   {{user_id}}"

      result = VariableResolver.resolve_variables(sql)

      assert [%{variable: "user_id", table: "users", column: "id"}] = result
    end

    test "returns nil table and column when no FROM clause" do
      sql = "SELECT {{value}} + 1"

      result = VariableResolver.resolve_variables(sql)

      assert [%{variable: "value", table: nil, column: nil}] = result
    end

    test "handles variable names with underscores and numbers" do
      sql = "SELECT * FROM users WHERE users.org_id_2 = {{org_id_2}}"

      result = VariableResolver.resolve_variables(sql)

      assert [%{variable: "org_id_2", column: "org_id_2"}] = result
    end
  end

  describe "resolve_variables/1 with complex queries" do
    test "handles subqueries" do
      sql = """
      SELECT * FROM users
      WHERE users.org_id = {{org_id}}
        AND users.id IN (SELECT user_id FROM admins)
      """

      result = VariableResolver.resolve_variables(sql)

      assert [%{variable: "org_id", table: "users"}] = result
    end

    test "handles INSERT statements" do
      sql = """
      INSERT INTO users (name, email)
      VALUES ({{name}}, {{email}})
      """

      result = VariableResolver.resolve_variables(sql)

      # INSERT doesn't have WHERE clause with column = {{var}} pattern
      # These are unbound variables with nil column
      assert length(result) == 2
      assert Enum.any?(result, &(&1.variable == "name"))
      assert Enum.any?(result, &(&1.variable == "email"))
    end

    test "handles UPDATE statements" do
      sql = """
      UPDATE users SET name = {{new_name}}
      WHERE users.id = {{user_id}}
      """

      result = VariableResolver.resolve_variables(sql)

      assert Enum.any?(result, &(&1.variable == "user_id" and &1.table == "users"))
    end

    test "handles CTEs (WITH clause)" do
      sql = """
      WITH active_users AS (
        SELECT * FROM users WHERE status = 'active'
      )
      SELECT * FROM active_users WHERE active_users.org_id = {{org_id}}
      """

      result = VariableResolver.resolve_variables(sql)

      assert [%{variable: "org_id", table: nil, column: "org_id"}] = result
    end
  end

  describe "resolve_variables/2 with schema-qualified tables" do
    test "binds an implicit column to the table and carries the schema" do
      sql = "SELECT * FROM public.users WHERE id = {{id}}"

      assert [%{variable: "id", schema: "public", table: "users", column: "id"}] =
               VariableResolver.resolve_variables(sql)
    end

    test "binds an explicit schema.table.column reference" do
      sql = "SELECT * FROM public.users WHERE public.users.id = {{id}}"

      assert [%{variable: "id", schema: "public", table: "users", column: "id"}] =
               VariableResolver.resolve_variables(sql)
    end

    test "resolves an alias of a schema-qualified table" do
      sql = "SELECT * FROM analytics.events e WHERE e.kind = {{kind}}"

      assert [%{variable: "kind", schema: "analytics", table: "events", column: "kind"}] =
               VariableResolver.resolve_variables(sql)
    end

    test "leaves the schema nil for an unqualified table" do
      assert [%{schema: nil, table: "users"}] =
               VariableResolver.resolve_variables("SELECT * FROM users WHERE id = {{id}}")
    end
  end

  describe "resolve_variables/2 with quoted identifiers" do
    alias Lotus.Query.Tokenizer.Profile

    test "keeps the case of double-quoted identifiers" do
      sql = ~S|SELECT * FROM "Users" WHERE "Id" = {{id}}|

      assert [%{variable: "id", table: "Users", column: "Id"}] =
               VariableResolver.resolve_variables(sql)
    end

    test "resolves a quoted alias of a quoted table" do
      sql = ~S|SELECT * FROM "Users" AS "U" WHERE "U"."Id" = {{id}}|

      assert [%{variable: "id", table: "Users", column: "Id"}] =
               VariableResolver.resolve_variables(sql)
    end

    test "folds unquoted identifiers to lowercase" do
      sql = "SELECT * FROM Users WHERE UserId = {{id}}"

      assert [%{variable: "id", table: "users", column: "userid"}] =
               VariableResolver.resolve_variables(sql)
    end

    test "uses the profile for backtick identifiers" do
      sql = "SELECT * FROM `shop`.`Orders` WHERE `Total` > {{min}}"

      assert [%{variable: "min", schema: "shop", table: "Orders", column: "Total"}] =
               VariableResolver.resolve_variables(sql, Profile.for_language("sql:mysql"))
    end

    test "ignores a placeholder inside a hash comment under the mysql profile" do
      sql = "SELECT * FROM users # {{note}}\nWHERE id = {{id}}"

      assert [%{variable: "id", table: "users"}] =
               VariableResolver.resolve_variables(sql, Profile.for_language("sql:mysql"))
    end
  end

  describe "resolve_variables/2 with derived tables" do
    test "returns no table for a column of a CTE" do
      sql = "WITH recent AS (SELECT * FROM orders) SELECT * FROM recent WHERE id = {{id}}"

      assert [%{variable: "id", table: nil, column: "id"}] =
               VariableResolver.resolve_variables(sql)
    end

    test "returns no table for an alias of a CTE" do
      sql = "WITH recent AS (SELECT * FROM orders) SELECT * FROM recent r WHERE r.id = {{id}}"

      assert [%{variable: "id", table: nil, column: "id"}] =
               VariableResolver.resolve_variables(sql)
    end

    test "recognizes every name of a WITH clause, including column lists and RECURSIVE" do
      sql = """
      WITH RECURSIVE tree(id, parent) AS (SELECT id, parent FROM nodes),
           leaves AS (SELECT * FROM tree WHERE parent IS NULL)
      SELECT * FROM leaves l JOIN users u ON u.id = l.id
      WHERE l.id = {{leaf}} AND u.email = {{email}}
      """

      result = VariableResolver.resolve_variables(sql)

      assert Enum.any?(result, &(&1.variable == "leaf" and is_nil(&1.table)))
      assert Enum.any?(result, &(&1.variable == "email" and &1.table == "users"))
    end

    test "still binds a base table joined next to a CTE" do
      sql = "WITH r AS (SELECT 1) SELECT * FROM users u, r WHERE u.id = {{id}}"

      assert [%{variable: "id", table: "users", column: "id"}] =
               VariableResolver.resolve_variables(sql)
    end

    test "returns no table when the FROM clause is a subquery" do
      sql = "SELECT * FROM (SELECT * FROM orders) o WHERE id = {{id}}"

      assert [%{variable: "id", table: nil, column: "id"}] =
               VariableResolver.resolve_variables(sql)
    end
  end

  describe "resolve_variables/2 token awareness" do
    test "does not read an alias out of a string literal" do
      sql = "SELECT * FROM users u WHERE u.note = 'from x y' AND u.id = {{id}}"

      assert [%{variable: "id", table: "users", column: "id"}] =
               VariableResolver.resolve_variables(sql)
    end

    test "does not treat a keyword after the table as an alias" do
      sql = "SELECT * FROM users WHERE id = {{id}} ORDER BY id"

      assert [%{variable: "id", table: "users", column: "id"}] =
               VariableResolver.resolve_variables(sql)
    end

    test "binds inside an optional block" do
      sql = "SELECT * FROM users WHERE 1=1 [[AND email = {{email}}]]"

      assert [%{variable: "email", table: "users", column: "email"}] =
               VariableResolver.resolve_variables(sql)
    end
  end
end
