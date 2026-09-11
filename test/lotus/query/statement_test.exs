defmodule Lotus.Query.StatementTest do
  use ExUnit.Case, async: true

  alias Lotus.Query.Statement

  describe "new/2" do
    test "defaults params to an empty list" do
      assert %Statement{body: "SELECT 1", params: []} = Statement.new("SELECT 1")
    end

    test "accepts positional params as a list" do
      assert %Statement{params: [1, "a"]} = Statement.new("SELECT $1, $2", [1, "a"])
    end

    test "accepts named params as a map" do
      params = %{"since" => ~D[2026-01-01], "limit" => 10}

      assert %Statement{params: ^params} = Statement.new("SELECT :since", params)
    end

    test "keeps a non-binary body opaque" do
      body = %{"query" => %{"match_all" => %{}}}

      assert %Statement{body: ^body} = Statement.new(body)
    end

    test "rejects params that are neither a list nor a map" do
      assert_raise FunctionClauseError, fn -> Statement.new("SELECT 1", :nope) end
    end
  end
end
