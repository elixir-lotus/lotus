defmodule Lotus.Visibility.Policy do
  @moduledoc """
  Policy builders and validators for visibility rules.

  This module provides functions to create and validate visibility policies
  for different database resource types (schemas, tables, columns)

  ## Schema and Table Policies

  Schemas and tables use simple allow/deny policies:

      Policy.schema_allow()  # => :allow
      Policy.schema_deny()   # => :deny

  ## Column Policies

  Columns support more complex policies with various actions:

      # Simple actions
      Policy.column_allow()  # Show column normally
      Policy.column_omit()   # Remove from results
      Policy.column_error()  # Fail query if selected

      # Masking with strategies
      Policy.column_mask(:sha256)
      Policy.column_mask({:fixed, "REDACTED"})
      Policy.column_mask({:partial, keep_last: 4})

      # With options
      Policy.column_mask(:sha256, show_in_schema?: false)
  """

  @type schema_policy :: :allow | :deny
  @type table_policy :: :allow | :deny

  @type column_action :: :allow | :omit | :mask | :error
  @type mask_strategy ::
          :null
          | :sha256
          | {:fixed, any()}
          | {:partial, keyword()}

  @type column_policy :: %{
          action: column_action(),
          mask: mask_strategy() | nil,
          show_in_schema?: boolean()
        }

  @doc """
  Creates an allow policy for schemas.
  """
  @spec schema_allow() :: :allow
  def schema_allow, do: :allow

  @doc """
  Creates a deny policy for schemas.
  """
  @spec schema_deny :: :deny
  def schema_deny, do: :deny

  @doc """
  Creates an allow policy for tables.
  """
  @spec table_allow :: :allow
  def table_allow, do: :allow

  @doc """
  Creates a deny policy for tables.
  """
  @spec table_deny :: :deny
  def table_deny, do: :deny

  @doc """
  Creates a policy that allows a column to be shown normally.

  ## Examples

      iex> Policy.column_allow()
      %{action: :allow, show_in_schema?: true}
  """
  @spec column_allow(keyword()) :: column_policy()
  def column_allow(opts \\ []) do
    %{
      action: :allow,
      mask: nil,
      show_in_schema?: Keyword.get(opts, :show_in_schema?, true)
    }
  end

  @doc """
  Creates a policy that omits a column from query results.

  The column is removed entirely from the result set.

  ## Examples

      iex> Policy.column_omit()
      %{action: :omit, show_in_schema?: true}

      iex> Policy.column_omit(show_in_schema?: false)
      %{action: :omit, show_in_schema?: false}
  """
  @spec column_omit(keyword()) :: column_policy()
  def column_omit(opts \\ []) do
    %{
      action: :omit,
      mask: nil,
      show_in_schema?: Keyword.get(opts, :show_in_schema?, true)
    }
  end

  @doc """
  Creates a policy that causes queries to error if the column is selected.

  ## Examples

      iex> Policy.column_error()
      %{action: :error, show_in_schema?: true}
  """
  @spec column_error(keyword()) :: column_policy()
  def column_error(opts \\ []) do
    %{
      action: :error,
      mask: nil,
      show_in_schema?: Keyword.get(opts, :show_in_schema?, true)
    }
  end

  @doc """
  Creates a policy that masks column values using the specified strategy.

  ## Mask Strategies

  - `:null` - Replace with NULL
  - `:sha256` - Replace with SHA256 hash
  - `{:fixed, value}` - Replace with fixed value
  - `{:partial, opts}` - Partial masking with options:
    - `keep_first: n` - Keep first n characters
    - `keep_last: n` - Keep last n characters
    - `replacement: str` - Character to use for masking (default: "*")

  Partial masking keeps nothing when `keep_first` plus `keep_last` covers the
  whole value, so a value that leaves nothing to mask is masked completely.
  Binary values that do not hold text (`bytea`, `BLOB`, `VARBINARY`) become one
  replacement character per byte. Any other value is rendered with
  `Lotus.Value.to_display_string/1` and then masked as text.

  ## Examples

      iex> Policy.column_mask(:sha256)
      %{action: :mask, mask: :sha256, show_in_schema?: true}

      iex> Policy.column_mask({:fixed, "REDACTED"})
      %{action: :mask, mask: {:fixed, "REDACTED"}, show_in_schema?: true}

      iex> Policy.column_mask({:partial, keep_last: 4})
      %{action: :mask, mask: {:partial, keep_last: 4}, show_in_schema?: true}

      iex> Policy.column_mask(:sha256, show_in_schema?: false)
      %{action: :mask, mask: :sha256, show_in_schema?: false}
  """
  @spec column_mask(mask_strategy(), keyword()) :: column_policy()
  def column_mask(strategy, opts \\ []) do
    %{
      action: :mask,
      mask: validate_mask_strategy!(strategy),
      show_in_schema?: Keyword.get(opts, :show_in_schema?, true)
    }
  end

  @doc """
  Validates if a value is a valid schema policy.
  """
  @spec valid_schema_policy?(any()) :: boolean()
  def valid_schema_policy?(:allow), do: true
  def valid_schema_policy?(:deny), do: true
  def valid_schema_policy?(_), do: false

  @doc """
  Validates if a value is a valid table policy.
  """
  @spec valid_table_policy?(any()) :: boolean()
  def valid_table_policy?(:allow), do: true
  def valid_table_policy?(:deny), do: true
  def valid_table_policy?(_), do: false

  @doc """
  Validates if a value is a valid column policy.
  """
  @spec valid_column_policy?(any()) :: boolean()
  def valid_column_policy?(%{action: action}) when action in [:allow, :omit, :mask, :error] do
    true
  end

  def valid_column_policy?(_), do: false

  @doc """
  Validates a mask strategy, raising if invalid.
  """
  @spec validate_mask_strategy!(any()) :: mask_strategy() | no_return()
  def validate_mask_strategy!(:null), do: :null
  def validate_mask_strategy!(:sha256), do: :sha256
  def validate_mask_strategy!({:fixed, _value} = strategy), do: strategy

  def validate_mask_strategy!({:partial, opts} = strategy) when is_list(opts) do
    strategy
  end

  def validate_mask_strategy!(invalid) do
    raise ArgumentError, """
    Invalid mask strategy: #{inspect(invalid)}

    Valid strategies:
    - :null
    - :sha256
    - {:fixed, value}
    - {:partial, [keep_first: n, keep_last: n, replacement: str]}
    """
  end

  @doc """
  Normalizes a column policy from various input formats.

  Accepts:
  - Keyword list: `[action: :mask, mask: :sha256]`
  - Atom shorthand: `:omit`
  - Map: `%{action: :mask, mask: :null}`

  Returns a normalized policy map with all required fields.
  """
  @spec normalize_column_policy(keyword() | atom() | map()) :: column_policy()
  def normalize_column_policy(policy) when is_list(policy) do
    %{
      action: Keyword.get(policy, :action, :mask),
      mask: Keyword.get(policy, :mask, :null),
      show_in_schema?: Keyword.get(policy, :show_in_schema?, true)
    }
  end

  def normalize_column_policy(action) when is_atom(action) do
    case action do
      :allow -> column_allow()
      :omit -> column_omit()
      :error -> column_error()
      :mask -> column_mask(:null)
      other -> %{action: other, mask: :null, show_in_schema?: true}
    end
  end

  def normalize_column_policy(%{} = policy) do
    %{
      action: Map.get(policy, :action, :mask),
      mask: Map.get(policy, :mask, :null),
      show_in_schema?: Map.get(policy, :show_in_schema?, true)
    }
  end

  @doc """
  Checks if a column policy requires masking.
  """
  @spec requires_mask?(column_policy()) :: boolean()
  def requires_mask?(%{action: :mask}), do: true
  def requires_mask?(_), do: false

  @doc """
  Checks if a column policy causes an error.
  """
  @spec causes_error?(column_policy()) :: boolean()
  def causes_error?(%{action: :error}), do: true
  def causes_error?(_), do: false

  @doc """
  Checks if a column policy omits the column.
  """
  @spec omits_column?(column_policy()) :: boolean()
  def omits_column?(%{action: :omit}), do: true
  def omits_column?(_), do: false

  @doc """
  Checks if a column policy allows the column.
  """
  @spec allows_column?(column_policy()) :: boolean()
  def allows_column?(%{action: :allow}), do: true
  def allows_column?(_), do: false

  @doc """
  Checks if a column should be hidden from schema introspection.

  Returns true if the policy explicitly sets show_in_schema? to false,
  false otherwise (including when policy is nil).
  """
  @spec hidden_from_schema?(column_policy() | nil) :: boolean()
  def hidden_from_schema?(%{show_in_schema?: false}), do: true
  def hidden_from_schema?(_), do: false
end
