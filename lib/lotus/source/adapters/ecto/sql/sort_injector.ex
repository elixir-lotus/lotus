defmodule Lotus.Source.Adapters.Ecto.SQL.SortInjector do
  @moduledoc deprecated: "Use `Lotus.SQL.SortInjector` instead."
  @moduledoc """
  Deprecated location of `Lotus.SQL.SortInjector`.

  The helper does not depend on Ecto, so it moved to the neutral `Lotus.SQL`
  namespace where any SQL engine can reuse it. This module delegates to the
  new one and will be removed in v2.0.
  """

  @deprecated "Use Lotus.SQL.SortInjector.apply/3 instead"
  defdelegate apply(sql, sorts, quote_fn), to: Lotus.SQL.SortInjector
end
