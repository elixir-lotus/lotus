defmodule Lotus.Source.Adapters.Ecto.SQL.Sanitizer do
  @moduledoc deprecated: "Use `Lotus.SQL.Sanitizer` instead."
  @moduledoc """
  Deprecated location of `Lotus.SQL.Sanitizer`.

  The helper does not depend on Ecto, so it moved to the neutral `Lotus.SQL`
  namespace where any SQL engine can reuse it. This module delegates to the
  new one and will be removed in v2.0.
  """

  @deprecated "Use Lotus.SQL.Sanitizer.strip_trailing_semicolon/1 instead"
  defdelegate strip_trailing_semicolon(sql), to: Lotus.SQL.Sanitizer
end
