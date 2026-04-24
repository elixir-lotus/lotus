defmodule Lotus.Query.Statement do
  @moduledoc """
  Adapter-opaque query payload that flows through the Lotus pipeline.

  A `Statement` decouples the query pipeline (`apply_filters/3`, `apply_sorts/3`,
  `apply_pagination/3`, `transform_bound_query/3`, `transform_statement/2`) from
  the adapter's internal representation. The built-in Ecto adapter carries SQL
  text, non-SQL adapters can carry a JSON object, a DSL AST, or any other term.

  ## Fields

    * `:adapter` — module implementing `Lotus.Source.Adapter` that owns this
      statement's `:text` shape. Used for routing and debugging; core treats it
      as opaque.

    * `:text` — the adapter-native query payload. `term()` by design: SQL
      binaries for Ecto-backed adapters, decoded JSON for Elasticsearch, an
      AST for DSL-based adapters. Core never inspects this field.

    * `:params` — bound parameter values in the order the adapter expects.
      Adapters that inline values (no parameterization) keep this as `[]`.

    * `:meta` — adapter-specific metadata carried through the pipeline, e.g.
      a `count_spec` produced by `apply_pagination/3`, or search-path hints.
      Core only reads keys it owns; adapters may stash their own keys.

  ## Immutability contract

  Pipeline callbacks return a new `%Statement{}` with the relevant field updated.
  Adapters must not mutate the struct in place (Elixir doesn't allow this
  anyway; the contract is explicit to rule out external state side channels).
  """

  @type t :: %__MODULE__{
          adapter: module() | nil,
          text: term(),
          params: list(),
          meta: map()
        }

  @enforce_keys [:text]
  defstruct adapter: nil, text: nil, params: [], meta: %{}

  @doc """
  Build a statement from text and optional bound params.

  Typically the pipeline builds statements via `Lotus.execute_with_options/7`,
  but callers (Runner integration tests, adapter-author examples) sometimes
  need to construct one directly.
  """
  @spec new(text :: term(), params :: list()) :: t()
  def new(text, params \\ []) when is_list(params) do
    %__MODULE__{text: text, params: params}
  end
end
