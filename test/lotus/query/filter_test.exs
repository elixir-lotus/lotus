defmodule Lotus.Query.FilterTest do
  use ExUnit.Case, async: true

  alias Lotus.Query.Filter

  doctest Lotus.Query.Filter

  describe "new/3" do
    test "creates a filter with column, op, and value" do
      filter = Filter.new("region", :eq, "US")
      assert %Filter{column: "region", op: :eq, value: "US"} = filter
    end

    test "creates a filter without value for nullary operators" do
      filter = Filter.new("deleted_at", :is_null)
      assert %Filter{column: "deleted_at", op: :is_null, value: nil} = filter
    end

    test "raises for invalid operator" do
      assert_raise FunctionClauseError, fn ->
        Filter.new("col", runtime_term(:invalid), "val")
      end
    end
  end

  describe "operators/0" do
    test "returns all valid operators" do
      ops = Filter.operators()
      assert :eq in ops
      assert :neq in ops
      assert :gt in ops
      assert :lt in ops
      assert :gte in ops
      assert :lte in ops
      assert :like in ops
      assert :contains in ops
      assert :starts_with in ops
      assert :ends_with in ops
      assert :is_null in ops
      assert :is_not_null in ops
    end
  end

  describe "text_operators/0" do
    test "are the operators that match text as written" do
      assert Filter.text_operators() == [:contains, :starts_with, :ends_with]
      assert Filter.text_operators() -- Filter.operators() == []
    end
  end

  describe "like_pattern/3" do
    test "wraps the text for its operator" do
      assert Filter.like_pattern(:contains, "ann", "!") == "%ann%"
      assert Filter.like_pattern(:starts_with, "ann", "!") == "ann%"
      assert Filter.like_pattern(:ends_with, "ann", "!") == "%ann"
    end

    test "escapes the wildcards and the escape itself, so they match as themselves" do
      assert Filter.like_pattern(:contains, "50%", "!") == "%50!%%"
      assert Filter.like_pattern(:contains, "user_id", "!") == "%user!_id%"
      assert Filter.like_pattern(:contains, "hi!", "!") == "%hi!!%"
      assert Filter.like_pattern(:contains, ~S(a\b), "!") == ~S(%a\b%)
    end
  end

  describe "operator_label/1" do
    test "returns display labels for operators" do
      assert Filter.operator_label(:eq) == "="
      assert Filter.operator_label(:neq) == "≠"
      assert Filter.operator_label(:gt) == ">"
      assert Filter.operator_label(:lt) == "<"
      assert Filter.operator_label(:gte) == "≥"
      assert Filter.operator_label(:lte) == "≤"
      assert Filter.operator_label(:like) == "LIKE"
      assert Filter.operator_label(:contains) == "contains"
      assert Filter.operator_label(:starts_with) == "starts with"
      assert Filter.operator_label(:ends_with) == "ends with"
      assert Filter.operator_label(:is_null) == "IS NULL"
      assert Filter.operator_label(:is_not_null) == "IS NOT NULL"
    end
  end

  # Hands the value over as an opaque term() so Elixir 1.20's type checker can't
  # statically reject the deliberately-invalid argument above. The point is to
  # exercise the *runtime* guard, which is what real (dynamic) callers hit.
  @spec runtime_term(term()) :: term()
  defp runtime_term(value), do: value
end
