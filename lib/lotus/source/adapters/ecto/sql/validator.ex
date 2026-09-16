defmodule Lotus.Source.Adapters.Ecto.SQL.Validator do
  @moduledoc deprecated: "Use `Lotus.SQL.Validator` instead."
  @moduledoc """
  Deprecated location of `Lotus.SQL.Validator`.

  The helper does not depend on Ecto, so it moved to the neutral `Lotus.SQL`
  namespace where any SQL engine can reuse it. This module delegates to the
  new one and will be removed in v2.0.
  """

  @deprecated "Use Lotus.SQL.Validator.validate/2 instead"
  defdelegate validate(sql, data_source), to: Lotus.SQL.Validator
end
