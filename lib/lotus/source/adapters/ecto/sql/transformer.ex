defmodule Lotus.Source.Adapters.Ecto.SQL.Transformer do
  @moduledoc deprecated: "Use `Lotus.SQL.Transformer` instead."
  @moduledoc """
  Deprecated location of `Lotus.SQL.Transformer`.

  The helper does not depend on Ecto, so it moved to the neutral `Lotus.SQL`
  namespace where any SQL engine can reuse it. This module delegates to the
  new one and will be removed in v2.0.
  """

  alias Lotus.Query.Tokenizer.Profile

  @deprecated "Use Lotus.SQL.Transformer.strip_quoted_variables/2 instead"
  defdelegate strip_quoted_variables(sql, profile \\ Profile.for_language("sql")),
    to: Lotus.SQL.Transformer

  @deprecated "Use Lotus.SQL.Transformer.transform_wildcards/3 instead"
  defdelegate transform_wildcards(
                sql,
                operator \\ :pipe,
                profile \\ Profile.for_language("sql")
              ),
              to: Lotus.SQL.Transformer

  @deprecated "Use Lotus.SQL.Transformer.transform_pg_intervals/2 instead"
  defdelegate transform_pg_intervals(sql, profile \\ Profile.for_language("sql")),
    to: Lotus.SQL.Transformer
end
