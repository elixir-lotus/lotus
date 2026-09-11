defmodule Lotus.AI.ActorThreadingTest do
  @moduledoc """
  AI actions run queries and list tables on behalf of a user. If the actor's
  `:context` and `:scope` do not reach those calls, an access-control plug or
  a scoped visibility resolver sees `nil` for every AI-initiated action — the
  AI would see more than the user it is acting for.
  """

  use Lotus.Case, async: true

  alias Lotus.AI.Actions
  alias Lotus.AI.Tool

  @actor %{context: %{user_id: 7}, scope: %{tenant_id: 2}}

  describe "Tool.from_action/2" do
    defmodule ContextCapturingAction do
      @moduledoc false
      @behaviour Lotus.AI.Action

      @impl true
      def name, do: "capture_context"

      @impl true
      def description, do: "Captures the context it was run with"

      @impl true
      def schema, do: [thing: [type: :string, required: true, doc: "anything"]]

      @impl true
      def run(_params, context) do
        send(self(), {:action_context, context})
        {:ok, %{ok: true}}
      end
    end

    test "passes the caller's context through to the action" do
      tool = Tool.from_action(ContextCapturingAction, bind: %{}, context: @actor)

      tool.callback.(%{"thing" => "x"})

      assert_received {:action_context, captured}
      assert captured.context == %{user_id: 7}
      assert captured.scope == %{tenant_id: 2}
    end

    test "defaults to an empty context when the caller supplies none" do
      tool = Tool.from_action(ContextCapturingAction, bind: %{})

      tool.callback.(%{"thing" => "x"})

      assert_received {:action_context, captured}
      assert captured == %{}
    end
  end

  describe "built-in actions forward the actor" do
    test "ListTables passes :context and :scope to Lotus.Schema" do
      assert {:ok, _} = Actions.ListTables.run(%{data_source: "postgres"}, @actor)
    end

    test "ListSchemas passes :context and :scope to Lotus.Schema" do
      assert {:ok, _} = Actions.ListSchemas.run(%{data_source: "postgres"}, @actor)
    end

    test "DescribeTable passes :context and :scope to Lotus.Schema" do
      assert {:ok, _} =
               Actions.DescribeTable.run(
                 %{data_source: "postgres", table_name: "test_users"},
                 @actor
               )
    end
  end

  describe "a scoped deny reaches AI-initiated execution" do
    defmodule DenyAllResolver do
      @moduledoc false
      @behaviour Lotus.Visibility.Resolver

      @impl true
      def schema_rules_for(_source, _scope), do: []

      @impl true
      def table_rules_for(_source, %{tenant_id: 2}), do: [deny: [{"public", "test_users"}]]
      def table_rules_for(_source, _scope), do: []

      @impl true
      def column_rules_for(_source, _scope), do: []
    end

    setup do
      previous = Application.get_env(:lotus, :visibility_resolver)
      Application.put_env(:lotus, :visibility_resolver, DenyAllResolver)
      Lotus.Config.reload!()

      on_exit(fn ->
        if previous do
          Application.put_env(:lotus, :visibility_resolver, previous)
        else
          Application.delete_env(:lotus, :visibility_resolver)
        end

        Lotus.Config.reload!()
      end)

      :ok
    end

    test "ExecuteSql under a denied scope is blocked" do
      # ExecuteStatement reports failures inside an :ok tuple so the LLM can read
      # them; what matters here is that the scoped deny stopped the query.
      assert {:ok, %{error: error}} =
               Actions.ExecuteStatement.run(
                 %{data_source: "postgres", sql: "SELECT id FROM test_users", label: "check"},
                 @actor
               )

      assert error =~ "blocked table"
      assert error =~ "test_users"
    end

    test "ExecuteSql under an allowed scope runs" do
      assert {:ok, _} =
               Actions.ExecuteStatement.run(
                 %{data_source: "postgres", sql: "SELECT id FROM test_users", label: "check"},
                 %{context: %{user_id: 7}, scope: %{tenant_id: 1}}
               )
    end
  end
end
