defmodule Lotus.Source.Adapters.Ecto.SQL.Identifier do
  @moduledoc deprecated: "Use `Lotus.SQL.Identifier` instead."
  @moduledoc """
  Deprecated location of `Lotus.SQL.Identifier`.

  The helper does not depend on Ecto, so it moved to the neutral `Lotus.SQL`
  namespace where any SQL engine can reuse it. This module delegates to the
  new one and will be removed in v2.0.
  """

  @deprecated "Use Lotus.SQL.Identifier.parse_table_name/1 instead"
  defdelegate parse_table_name(table_name), to: Lotus.SQL.Identifier

  @deprecated "Use Lotus.SQL.Identifier.validate_identifier/2 instead"
  defdelegate validate_identifier(value, label), to: Lotus.SQL.Identifier

  @deprecated "Use Lotus.SQL.Identifier.validate_identifier!/2 instead"
  defdelegate validate_identifier!(value, label), to: Lotus.SQL.Identifier

  @deprecated "Use Lotus.SQL.Identifier.validate_table_parts/2 instead"
  defdelegate validate_table_parts(schema, table), to: Lotus.SQL.Identifier

  @deprecated "Use Lotus.SQL.Identifier.validate_search_path!/1 instead"
  defdelegate validate_search_path!(search_path), to: Lotus.SQL.Identifier
end
