defmodule Lotus.Source.Adapters.Ecto.SQL.DeprecatedDelegatesTest do
  use ExUnit.Case, async: true

  alias Lotus.Query.Filter
  alias Lotus.Query.Sort

  @pairs [
    {Lotus.Source.Adapters.Ecto.SQL.FilterInjector, Lotus.SQL.FilterInjector},
    {Lotus.Source.Adapters.Ecto.SQL.SortInjector, Lotus.SQL.SortInjector},
    {Lotus.Source.Adapters.Ecto.SQL.Transformer, Lotus.SQL.Transformer},
    {Lotus.Source.Adapters.Ecto.SQL.Sanitizer, Lotus.SQL.Sanitizer},
    {Lotus.Source.Adapters.Ecto.SQL.Validator, Lotus.SQL.Validator},
    {Lotus.Source.Adapters.Ecto.SQL.Identifier, Lotus.SQL.Identifier}
  ]

  for {old, new} <- @pairs do
    test "#{inspect(old)} exports every function of #{inspect(new)} as a deprecated delegate" do
      old = unquote(old)
      new = unquote(new)
      Code.ensure_loaded!(old)
      Code.ensure_loaded!(new)

      {:docs_v1, _, _, _, _, module_meta, function_docs} = Code.fetch_docs(old)
      assert module_meta[:deprecated] == "Use `#{inspect(new)}` instead."

      deprecated =
        for {{:function, name, arity}, _, _, _, meta} <- function_docs,
            is_binary(meta[:deprecated]),
            do: {name, arity}

      for {name, arity} <- public_functions(new) do
        assert function_exported?(old, name, arity),
               "#{inspect(old)}.#{name}/#{arity} is missing"

        assert {name, arity} in deprecated or
                 Enum.any?(deprecated, fn {n, a} -> n == name and a > arity end),
               "#{inspect(old)}.#{name}/#{arity} is not marked @deprecated"
      end
    end
  end

  test "old names produce the same results as the new ones" do
    quote_fn = fn id -> ~s("#{id}") end
    placeholder_fn = fn idx -> "$#{idx}" end
    filters = [%Filter{column: "region", op: :eq, value: "US"}]
    sorts = [%Sort{column: "created_at", direction: :desc}]

    assert call(Lotus.Source.Adapters.Ecto.SQL.FilterInjector, :apply, [
             "SELECT 1",
             [],
             filters,
             quote_fn,
             placeholder_fn
           ]) == Lotus.SQL.FilterInjector.apply("SELECT 1", [], filters, quote_fn, placeholder_fn)

    assert call(Lotus.Source.Adapters.Ecto.SQL.SortInjector, :apply, ["SELECT 1", sorts, quote_fn]) ==
             Lotus.SQL.SortInjector.apply("SELECT 1", sorts, quote_fn)

    assert call(Lotus.Source.Adapters.Ecto.SQL.Transformer, :transform_wildcards, ["'%{{q}}%'"]) ==
             Lotus.SQL.Transformer.transform_wildcards("'%{{q}}%'")

    assert call(Lotus.Source.Adapters.Ecto.SQL.Sanitizer, :strip_trailing_semicolon, ["x; "]) ==
             "x"

    assert call(Lotus.Source.Adapters.Ecto.SQL.Identifier, :parse_table_name, ["public.users"]) ==
             {"public", "users"}
  end

  defp public_functions(module) do
    module.__info__(:functions)
  end

  defp call(module, name, args), do: apply(module, name, args)
end
