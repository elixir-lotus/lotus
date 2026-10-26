defmodule Lotus.Visibility.MatcherTest do
  use ExUnit.Case, async: true
  use Mimic

  alias Lotus.Visibility
  alias Lotus.Visibility.Matcher
  alias Lotus.Visibility.Policy

  describe "compile/2" do
    test "returns a matcher and leaves a matcher unchanged" do
      matcher = Visibility.compile(%{table: [deny: ["secrets"]]})

      assert %Matcher{} = matcher
      assert Visibility.compile(matcher) == matcher
    end

    test "raw rules carry no builtin denies" do
      matcher = Visibility.compile(%{})

      assert Visibility.allowed_relation?(matcher, {"pg_catalog", "pg_class"})
    end

    test "raw rules still deny the tables of Lotus Pro and Sake" do
      matcher = Visibility.compile(%{})

      refute Visibility.allowed_relation?(matcher, {"public", "lotus_access_policies"})
      refute Visibility.allowed_relation?(matcher, {nil, "sake_oauth_tokens"})
      refute Visibility.allowed_relation?(matcher, {nil, "sake_tasks"})
      assert Visibility.allowed_relation?(matcher, {"public", "lotus_sub"})
    end

    test "the adapter option merges the adapter's builtin denies" do
      adapter = Lotus.Source.resolve!("postgres", nil)
      matcher = Visibility.compile(%{}, adapter: adapter)

      refute Visibility.allowed_relation?(matcher, {"pg_catalog", "pg_class"})
      refute Visibility.allowed_schema?(matcher, "pg_catalog")
      assert Visibility.allowed_relation?(matcher, {"public", "users"})
    end
  end

  describe "checks with a matcher" do
    test "allow posture is scoped to the schemas the allow rules name" do
      matcher = Visibility.compile(%{table: [allow: [{"restricted", "allowed_table"}]]})

      assert Visibility.allowed_relation?(matcher, {"restricted", "allowed_table"})
      refute Visibility.allowed_relation?(matcher, {"restricted", "other"})
      assert Visibility.allowed_relation?(matcher, {"public", "anything"})
    end

    test "a bare table name in a deny rule matches in every schema" do
      matcher = Visibility.compile(%{table: [deny: ["api_keys"]]})

      refute Visibility.allowed_relation?(matcher, {"public", "api_keys"})
      refute Visibility.allowed_relation?(matcher, {nil, "api_keys"})
      assert Visibility.allowed_relation?(matcher, {"public", "users"})
    end

    test "a nil schema rule matches only relations without a schema" do
      matcher = Visibility.compile(%{table: [deny: [{nil, "private"}]]})

      refute Visibility.allowed_relation?(matcher, {nil, "private"})
      refute Visibility.allowed_relation?(matcher, {"", "private"})
      assert Visibility.allowed_relation?(matcher, {"public", "private"})
    end

    test "schema denies gate table rules" do
      matcher = Visibility.compile(%{schema: [deny: ["legacy"]]})

      refute Visibility.allowed_schema?(matcher, "legacy")
      refute Visibility.allowed_relation?(matcher, {"legacy", "users"})
      assert Visibility.allowed_schema?(matcher, "public")
    end

    test "regex rules match schemas and tables" do
      matcher =
        Visibility.compile(%{
          schema: [allow: [~r/^tenant_/, "public"]],
          table: [deny: [{"public", ~r/^raw_/}]]
        })

      assert Visibility.allowed_schema?(matcher, "tenant_1")
      refute Visibility.allowed_schema?(matcher, "other")
      refute Visibility.allowed_relation?(matcher, {"public", "raw_events"})
      assert Visibility.allowed_relation?(matcher, {"public", "events"})
    end

    test "column rules keep list order within a pass" do
      matcher =
        Visibility.compile(%{
          column: [{~r/^s/, :omit}, {"ssn", :error}, {"email", [mask: :sha256]}]
        })

      assert %{action: :omit} =
               Visibility.column_policy_for(matcher, [{"public", "users"}], "ssn")

      assert %{action: :mask, mask: :sha256} = Visibility.column_policy_for(matcher, [], "email")
      assert Visibility.column_policy_for(matcher, [], "name") == nil
    end

    test "the most specific column pass wins" do
      matcher =
        Visibility.compile(%{
          column: [
            {"password", :error},
            {"users", "password", :omit},
            {"public", "users", "password", [mask: :sha256]}
          ]
        })

      assert %{action: :mask} =
               Visibility.column_policy_for(matcher, [{"public", "users"}], "password")

      assert %{action: :omit} =
               Visibility.column_policy_for(matcher, [{"other", "users"}], "password")

      assert %{action: :error} = Visibility.column_policy_for(matcher, [], "password")
    end

    test "column rules match a result column name in any case" do
      matcher =
        Visibility.compile(%{
          column: [
            {"public", "users", "ssn", :omit},
            {"users", "pin", :error},
            {"email", [mask: :sha256]},
            {~r/_secret$/, :mask}
          ]
        })

      rels = [{"public", "users"}]

      assert %{action: :omit} = Visibility.column_policy_for(matcher, rels, "SSN")
      assert %{action: :error} = Visibility.column_policy_for(matcher, rels, "Pin")
      assert %{action: :mask, mask: :sha256} = Visibility.column_policy_for(matcher, [], "EMAIL")
      assert %{action: :mask} = Visibility.column_policy_for(matcher, [], "API_SECRET")

      upper = Visibility.compile(%{column: [{"SSN", :omit}]})
      assert %{action: :omit} = Visibility.column_policy_for(upper, [], "ssn")
    end

    test "a name matching rules in two cases gets the stricter policy" do
      exact_allows = Visibility.compile(%{column: [{"ssn", :mask}, {"SSN", :allow}]})
      assert %{action: :mask} = Visibility.column_policy_for(exact_allows, [], "SSN")

      folded_allows =
        Visibility.compile(%{column: [{"users", "SSN", :allow}, {"users", "ssn", :omit}]})

      assert %{action: :omit} =
               Visibility.column_policy_for(folded_allows, [{"public", "users"}], "ssn")
    end

    test "a name over several relations gets the strictest policy any of them has" do
      users = {"public", "users"}
      orders = {"public", "orders"}

      for rules <- [
            [{"orders", "ssn", :allow}, {"users", "ssn", :mask}],
            [{"users", "ssn", :mask}, {"orders", "ssn", :allow}]
          ] do
        matcher = Visibility.compile(%{column: rules})

        assert %{action: :mask} = Visibility.column_policy_for(matcher, [users, orders], "ssn")
        assert %{action: :mask} = Visibility.column_policy_for(matcher, [orders, users], "ssn")
        assert %{action: :allow} = Visibility.column_policy_for(matcher, [orders], "ssn")
      end

      # A relation without a rule for the name falls back to the column-only
      # rule, which still counts.
      fallback = Visibility.compile(%{column: [{"orders", "ssn", :allow}, {"ssn", :omit}]})
      assert %{action: :omit} = Visibility.column_policy_for(fallback, [orders, users], "ssn")
      assert %{action: :allow} = Visibility.column_policy_for(fallback, [orders], "ssn")
    end

    test "policies rank error, omit, then masks by what they show, then allow" do
      ranked = [
        :error,
        :omit,
        [mask: :null],
        [mask: {:fixed, "x"}],
        [mask: :sha256],
        [mask: {:partial, keep_last: 4}],
        :allow
      ]

      tables = Enum.map(1..length(ranked), &"t#{&1}")
      rels = Enum.map(tables, &{"public", &1})

      for {policy, i} <- Enum.with_index(ranked), policy != :allow do
        # This policy and every less strict one, on the later relations.
        rules = for {p, j} <- Enum.with_index(ranked), j >= i, do: {Enum.at(tables, j), "c", p}
        expected = Policy.normalize_column_policy(policy)

        assert Visibility.column_policy_for(
                 Visibility.compile(%{column: Enum.reverse(rules)}),
                 rels,
                 "c"
               ) ==
                 expected
      end
    end

    test "filter and validate helpers take a matcher" do
      matcher = Visibility.compile(%{schema: [deny: ["legacy"]]})

      assert Visibility.filter_schemas(["public", "legacy"], matcher) == ["public"]

      assert Visibility.filter_relations([{"public", "a"}, {"legacy", "b"}], matcher) ==
               [{"public", "a"}]

      assert {:error, :schema_not_visible, denied: ["legacy"]} =
               Visibility.validate_schemas(["public", "legacy"], matcher)
    end

    test "raw rules are accepted wherever a matcher is" do
      assert Visibility.allowed_relation?(%{table: [deny: ["x"]]}, {"public", "y"})
      refute Visibility.allowed_relation?(%{table: [deny: ["x"]]}, {"public", "x"})
    end
  end

  describe "matcher_for/2" do
    defmodule CompiledResolver do
      @moduledoc false
      @behaviour Lotus.Visibility.Resolver

      @impl true
      def schema_rules_for(_name, _scope), do: []
      @impl true
      def table_rules_for(_name, _scope), do: []
      @impl true
      def column_rules_for(_name, _scope), do: []

      @impl true
      def matcher_for(name, scope) do
        send(self(), {:matcher_for, name, scope})
        Lotus.Visibility.compile(%{table: [deny: ["from_matcher"]]})
      end
    end

    defmodule RulesOnlyResolver do
      @moduledoc false
      @behaviour Lotus.Visibility.Resolver

      @impl true
      def schema_rules_for(_name, _scope), do: [deny: ["legacy"]]
      @impl true
      def table_rules_for(_name, _scope), do: [deny: ["secrets"]]
      @impl true
      def column_rules_for(_name, _scope), do: [{"ssn", :omit}]
    end

    test "uses the resolver's matcher_for/2 when it exports one" do
      stub(Lotus.Config, :visibility_resolver, fn -> CompiledResolver end)

      matcher = Visibility.matcher_for("postgres", %{role: :admin})

      assert_received {:matcher_for, "postgres", %{role: :admin}}
      refute Visibility.allowed_relation?(matcher, {"public", "from_matcher"})
    end

    test "compiles the rule callbacks and merges the source's builtin denies otherwise" do
      stub(Lotus.Config, :visibility_resolver, fn -> RulesOnlyResolver end)

      matcher = Visibility.matcher_for("postgres")

      refute Visibility.allowed_schema?(matcher, "legacy")
      refute Visibility.allowed_relation?(matcher, {"public", "secrets"})
      refute Visibility.allowed_relation?(matcher, {"pg_catalog", "pg_class"})
      assert %{action: :omit} = Visibility.column_policy_for(matcher, [], "ssn")
    end
  end
end
