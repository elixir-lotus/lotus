defmodule Lotus.Query.Filter do
  @moduledoc """
  Represents a filter condition to apply on query results.

  Filters are source-agnostic data structures that describe a column-level
  predicate. Each source adapter knows how to translate filters into its
  native query language (e.g., SQL WHERE clauses via CTE wrapping).

  ## Examples

      %Filter{column: "region", op: :eq, value: "US"}
      %Filter{column: "price", op: :gt, value: 100}
      %Filter{column: "deleted_at", op: :is_null}
      %Filter{column: "name", op: :contains, value: "50%_off"}

  `:like` takes a SQL `LIKE` pattern as it is, `%` and `_` included.
  `:contains`, `:starts_with` and `:ends_with` take text: it is matched as
  written (a `%` or `_` in it is that character, not a wildcard) and
  without regard to case. They are for text columns.
  """

  @type operator ::
          :eq
          | :neq
          | :gt
          | :lt
          | :gte
          | :lte
          | :like
          | text_operator()
          | :is_null
          | :is_not_null

  @typedoc "An operator that matches text as written, without regard to case."
  @type text_operator :: :contains | :starts_with | :ends_with

  @type t :: %__MODULE__{
          column: String.t(),
          op: operator(),
          value: term()
        }

  @enforce_keys [:column, :op]
  defstruct [:column, :op, :value]

  @text_operators ~w(contains starts_with ends_with)a
  @operators ~w(eq neq gt lt gte lte like)a ++ @text_operators ++ ~w(is_null is_not_null)a

  @doc """
  Creates a new filter, validating the operator.
  """
  @spec new(String.t(), operator(), term()) :: t()
  def new(column, op, value \\ nil) when op in @operators do
    %__MODULE__{column: column, op: op, value: value}
  end

  @doc """
  Returns the list of valid operator atoms.
  """
  @spec operators() :: [operator(), ...]
  def operators, do: @operators

  @doc """
  Returns the operators that match text as written, without regard to
  case: `:contains`, `:starts_with` and `:ends_with`.

  An adapter that does not implement `supported_filter_operators/1` is not
  taken to support them (see `c:Lotus.Source.Adapter.supported_filter_operators/1`).
  """
  @spec text_operators() :: [text_operator(), ...]
  def text_operators, do: @text_operators

  @doc """
  The `LIKE` pattern of a text operator's value, with `escape` before each
  `%`, `_` and `escape` in it, so that they match as themselves.

      iex> Lotus.Query.Filter.like_pattern(:contains, "50%_off", "!")
      "%50!%!_off%"

      iex> Lotus.Query.Filter.like_pattern(:starts_with, "a!b", "!")
      "a!!b%"
  """
  @spec like_pattern(text_operator(), String.t(), String.t()) :: String.t()
  def like_pattern(op, value, escape) when op in @text_operators and is_binary(value) do
    escaped = String.replace(value, [escape, "%", "_"], &(escape <> &1))

    case op do
      :contains -> "%" <> escaped <> "%"
      :starts_with -> escaped <> "%"
      :ends_with -> "%" <> escaped
    end
  end

  @doc """
  Returns a human-readable label for the given operator.
  """
  @spec operator_label(operator()) :: String.t()
  def operator_label(:eq), do: "="
  def operator_label(:neq), do: "≠"
  def operator_label(:gt), do: ">"
  def operator_label(:lt), do: "<"
  def operator_label(:gte), do: "≥"
  def operator_label(:lte), do: "≤"
  def operator_label(:like), do: "LIKE"
  def operator_label(:contains), do: "contains"
  def operator_label(:starts_with), do: "starts with"
  def operator_label(:ends_with), do: "ends with"
  def operator_label(:is_null), do: "IS NULL"
  def operator_label(:is_not_null), do: "IS NOT NULL"
end
