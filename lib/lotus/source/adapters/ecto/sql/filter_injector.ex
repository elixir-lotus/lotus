defmodule Lotus.Source.Adapters.Ecto.SQL.FilterInjector do
  @moduledoc deprecated: "Use `Lotus.SQL.FilterInjector` instead."
  @moduledoc """
  Deprecated location of `Lotus.SQL.FilterInjector`.

  The helper does not depend on Ecto, so it moved to the neutral `Lotus.SQL`
  namespace where any SQL engine can reuse it. This module delegates to the
  new one and will be removed in v2.0.
  """

  @deprecated "Use Lotus.SQL.FilterInjector.apply/5 instead"
  defdelegate apply(sql, params, filters, quote_fn, placeholder_fn), to: Lotus.SQL.FilterInjector
end
