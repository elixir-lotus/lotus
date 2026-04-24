defmodule Lotus.Storage.Query do
  @moduledoc """
  Represents a saved Lotus query.

  Queries can be stored, updated, listed, and executed by the host app.
  Supports `{{var}}` placeholders in the SQL `statement` for value substitution
  only. Variables are bound at runtime using configured variables and are only
  safe for SQL values (WHERE clauses, ORDER BY values, etc.), never for
  identifiers like table names, column names, or schema names.
  """

  use Ecto.Schema
  import Ecto.Changeset
  require Logger

  alias Lotus.Config
  alias Lotus.Query.OptionalClause
  alias Lotus.Query.Statement
  alias Lotus.Source
  alias Lotus.Source.Adapter
  alias Lotus.Storage.{QueryVariable, SchemaCache, TypeCaster, VariableResolver}

  @type t :: %__MODULE__{
          id: term(),
          name: String.t(),
          description: String.t() | nil,
          statement: String.t(),
          variables: [QueryVariable.t()],
          data_source: String.t() | nil,
          search_path: String.t() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @primary_key {:id, :id, autogenerate: true}
  @foreign_key_type :id

  json_encoder = Lotus.JSON.encoder()

  @derive {json_encoder,
           only: [
             :id,
             :name,
             :description,
             :statement,
             :variables,
             :data_source,
             :search_path,
             :inserted_at,
             :updated_at
           ]}

  schema "lotus_queries" do
    field(:name, :string)
    field(:description, :string)
    field(:statement, :string)
    field(:data_source, :string)
    field(:search_path, :string)

    embeds_many(:variables, QueryVariable, on_replace: :delete)

    timestamps(type: :utc_datetime_usec)
  end

  @required ~w(name statement)a
  @permitted ~w(name description statement data_source search_path)a

  def new(attrs), do: changeset(%__MODULE__{}, attrs)
  def update(query, attrs), do: changeset(query, attrs)

  def changeset(query, attrs) do
    query
    |> cast(attrs, @permitted)
    |> cast_embed(:variables, with: &QueryVariable.changeset/2)
    |> validate_required(@required)
    |> validate_length(:name, min: 1, max: 255)
    |> validate_statement()
    |> validate_data_source()
    |> validate_search_path()
    |> maybe_add_unique_constraint()
  end

  @doc """
  Builds the final SQL statement and parameter list for a query.

  Returns `{:ok, sql, params}` on success, or `{:error, reason}` when a
  required variable is missing, a list variable is empty, or a supplied
  value fails type casting.

  Use `to_sql_params!/2` if you prefer a raising variant.
  """
  @spec to_sql_params(t(), map()) ::
          {:ok, String.t(), [term()]} | {:error, String.t()}
  def to_sql_params(%__MODULE__{statement: sql, variables: vars} = q, supplied_vars \\ %{}) do
    # A stored query's `data_source` can become stale when the source is
    # renamed or removed. Fall back to the default source so compilation
    # still succeeds — the caller (Runner/Preflight) will surface a clear
    # error at execution if the default source doesn't match the query's
    # dialect expectations.
    adapter =
      try do
        Source.resolve!(q.data_source, nil)
      rescue
        ArgumentError -> Source.resolve!(nil, nil)
      end

    # Process optional clauses before transformation
    processed_sql = OptionalClause.process(sql, supplied_vars)

    # Rewrite the raw statement before variables are bound (dialect or
    # adapter-specific preprocessing — e.g., wildcard rewriting).
    transform_input = %Statement{adapter: adapter.module, text: processed_sql}
    %Statement{text: transformed_sql} = Adapter.transform_statement(adapter, transform_input)

    # Extract variables from SQL
    vars_in_order = Lotus.Variables.extract_names(transformed_sql)

    variable_bindings = VariableResolver.resolve_variables(transformed_sql)

    enriched_bindings =
      enrich_bindings_with_types(variable_bindings, adapter, q.search_path)

    # Build the statement by folding each variable through the adapter's
    # substitution callback. The adapter owns placeholder syntax and param
    # accumulation — this loop is adapter-agnostic.
    init_statement = %Statement{adapter: adapter.module, text: transformed_sql}

    result =
      Enum.reduce_while(vars_in_order, {:ok, init_statement}, fn var, {:ok, statement} ->
        case substitute_variable(
               var,
               vars,
               supplied_vars,
               enriched_bindings,
               adapter,
               statement
             ) do
          {:ok, _} = ok -> {:cont, ok}
          {:error, _} = err -> {:halt, err}
        end
      end)

    case result do
      {:ok, %Statement{text: final_sql, params: final_params}} ->
        {:ok, final_sql, final_params}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Same as `to_sql_params/2` but raises `ArgumentError` on error.
  """
  @spec to_sql_params!(t(), map()) :: {String.t(), [term()]}
  def to_sql_params!(%__MODULE__{} = q, supplied_vars \\ %{}) do
    case to_sql_params(q, supplied_vars) do
      {:ok, sql, params} -> {sql, params}
      {:error, reason} -> raise ArgumentError, reason
    end
  end

  defp substitute_variable(var, vars, supplied_vars, enriched_bindings, adapter, statement) do
    meta = Enum.find(vars, %{}, &(&1.name == var))

    with {:ok, value} <- fetch_var_value(var, meta, supplied_vars) do
      manual_type = Map.get(meta, :type)
      binding = Enum.find(enriched_bindings, &(&1.variable == var))
      is_list = Map.get(meta, :list, false)

      if is_list do
        substitute_list_variable(var, value, manual_type, binding, adapter, statement)
      else
        substitute_scalar_variable(var, value, manual_type, binding, adapter, statement)
      end
    end
  end

  defp fetch_var_value(var, meta, supplied_vars) do
    case Map.fetch(supplied_vars, var) do
      {:ok, nil} -> fetch_default(var, meta)
      {:ok, value} -> {:ok, value}
      :error -> fetch_default(var, meta)
    end
  end

  defp fetch_default(var, meta) do
    case Map.get(meta, :default) do
      nil -> {:error, "Missing required variable: #{var}"}
      default -> {:ok, default}
    end
  end

  defp substitute_list_variable(var, value, manual_type, binding, adapter, statement) do
    case normalize_list_value(value) do
      [] ->
        {:error, "List variable '#{var}' must have at least one value"}

      values ->
        with {:ok, {final_type, casted_values}} <-
               cast_list_values(values, manual_type, binding) do
          Adapter.substitute_list_variable(adapter, statement, var, casted_values, final_type)
        end
    end
  end

  defp substitute_scalar_variable(var, value, manual_type, binding, adapter, statement) do
    with {:ok, {final_type, casted_value}} <- determine_type_and_cast(value, manual_type, binding) do
      Adapter.substitute_variable(adapter, statement, var, casted_value, final_type)
    end
  end

  defp cast_list_values(values, manual_type, binding) do
    init = {:ok, {nil, []}}

    reduced =
      Enum.reduce_while(values, init, fn v, {:ok, {acc_type, acc_values}} ->
        case determine_type_and_cast(v, manual_type, binding) do
          {:ok, {final_type, casted}} ->
            # All values in a list share the same type — the variable's
            # binding is per-variable, not per-value — so it's safe to carry
            # the last `final_type` out as the group's type.
            {:cont, {:ok, {final_type || acc_type, [casted | acc_values]}}}

          {:error, _} = err ->
            {:halt, err}
        end
      end)

    with {:ok, {final_type, rev_values}} <- reduced do
      {:ok, {final_type, Enum.reverse(rev_values)}}
    end
  end

  @doc """
  Extracts unique variable names from an SQL statement in order of first occurrence.

  Variables are identified by the `{{variable_name}}` syntax.

  ## Examples

      iex> Lotus.Storage.Query.extract_variables_from_statement("SELECT * FROM users WHERE id = {{user_id}} AND status = {{status}}")
      ["user_id", "status"]

      iex> Lotus.Storage.Query.extract_variables_from_statement("SELECT * FROM users WHERE id = {{user_id}} OR id = {{user_id}}")
      ["user_id"]

      iex> Lotus.Storage.Query.extract_variables_from_statement("SELECT * FROM users")
      []

  """
  @spec extract_variables_from_statement(String.t()) :: [String.t()]
  def extract_variables_from_statement(statement) do
    regex = ~r/\{\{\s*([A-Za-z_][A-Za-z0-9_]*)\s*\}\}/

    Regex.scan(regex, statement, capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
  end

  @doc """
  Returns a `MapSet` of variable names that appear inside `[[...]]` optional
  clause blocks in the given SQL statement.
  """
  @spec extract_optional_variable_names(String.t()) :: MapSet.t()
  def extract_optional_variable_names(statement) do
    OptionalClause.extract_optional_variable_names(statement)
  end

  defp enrich_bindings_with_types(bindings, %Adapter{} = adapter, search_path) do
    Enum.map(bindings, fn binding ->
      schema = resolve_schema(binding.table, search_path)

      case SchemaCache.get_column_type(adapter, schema, binding.table, binding.column) do
        {:ok, db_type} ->
          lotus_type = Adapter.db_type_to_lotus_type(adapter, db_type)
          Map.put(binding, :lotus_type, lotus_type)

        :not_found ->
          Logger.debug(
            "Column type not found: #{schema}.#{binding.table}.#{binding.column}, " <>
              "defaulting to :text"
          )

          Map.put(binding, :lotus_type, :text)
      end
    end)
  rescue
    # Narrowly rescue only transient connection failures so type enrichment
    # degrades gracefully when the DB is unreachable. Other exceptions
    # (ArgumentError from bad config, FunctionClauseError from callback
    # mismatches) indicate real bugs — let them propagate to the caller.
    error in DBConnection.ConnectionError ->
      Logger.warning(
        "Type enrichment failed: #{Exception.message(error)}, " <>
          "defaulting all bindings to :text"
      )

      Enum.map(bindings, &Map.put(&1, :lotus_type, :text))
  end

  defp resolve_schema(table, search_path) when is_binary(table) do
    # Check if table name includes schema prefix (e.g., "public.users")
    case String.split(table, ".", parts: 2) do
      [schema, _table_name] ->
        # Explicit schema in table name
        schema

      [_table_name] ->
        # No schema prefix - use search_path or default
        resolve_from_search_path(search_path)
    end
  end

  defp resolve_schema(nil, search_path), do: resolve_from_search_path(search_path)

  defp resolve_from_search_path(search_path) when is_binary(search_path) do
    search_path
    |> String.split(",")
    |> List.first()
    |> case do
      nil -> "public"
      schema -> String.trim(schema)
    end
  end

  defp resolve_from_search_path(_), do: "public"

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp determine_type_and_cast(value, manual_type, binding) do
    cond do
      # If we have automatic detection with a non-text type, prefer it
      binding && Map.has_key?(binding, :lotus_type) && binding.lotus_type != :text ->
        lotus_type = binding.lotus_type
        column_info = %{table: binding.table, column: binding.column}

        if requires_casting?(lotus_type, value) do
          case TypeCaster.cast_value(value, lotus_type, column_info) do
            {:ok, casted_value} -> {:ok, {lotus_type, casted_value}}
            {:error, error_msg} -> {:error, error_msg}
          end
        else
          # Pass through without casting for text/varchar
          {:ok, {lotus_type, value}}
        end

      # If automatic detection returned :text but we have a manual type, prefer manual
      manual_type != nil ->
        with {:ok, casted} <- cast_value(value, manual_type) do
          {:ok, {manual_type, casted}}
        end

      # If automatic detection found text type and no manual type, use text
      binding && Map.has_key?(binding, :lotus_type) ->
        {:ok, {binding.lotus_type, value}}

      # No type information - use as-is
      true ->
        {:ok, {nil, value}}
    end
  end

  defp normalize_list_value(value) when is_list(value), do: value

  defp normalize_list_value(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
  end

  defp normalize_list_value(value), do: [value]

  defp requires_casting?(:text, _value), do: false
  defp requires_casting?(:binary, value) when is_binary(value), do: false
  defp requires_casting?(:enum, _value), do: false
  defp requires_casting?(:uuid, _value), do: true
  defp requires_casting?(:number, _value), do: true
  defp requires_casting?(:integer, _value), do: true
  defp requires_casting?(:float, _value), do: true
  defp requires_casting?(:decimal, _value), do: true
  defp requires_casting?(:boolean, _value), do: true
  defp requires_casting?(:date, _value), do: true
  defp requires_casting?(:time, _value), do: true
  defp requires_casting?(:datetime, _value), do: true
  defp requires_casting?(:json, _value), do: true
  defp requires_casting?(:composite, _value), do: true
  defp requires_casting?({:array, _element_type}, _value), do: true
  defp requires_casting?(_, _value), do: false

  defp cast_value(value, :number) when is_binary(value) do
    case Integer.parse(value) do
      {int_value, ""} ->
        {:ok, int_value}

      {_int_value, _remainder} ->
        case Float.parse(value) do
          {float_value, ""} ->
            {:ok, float_value}

          {_float_value, _remainder} ->
            {:error, "Invalid number format: '#{value}' contains non-numeric characters"}

          :error ->
            {:error, "Invalid number format: '#{value}' is not a valid number"}
        end

      :error ->
        {:error, "Invalid number format: '#{value}' is not a valid number"}
    end
  end

  defp cast_value(value, :date) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} ->
        {:ok, date}

      {:error, _reason} ->
        {:error, "Invalid date format: '#{value}' is not a valid ISO8601 date"}
    end
  end

  defp cast_value(value, _), do: {:ok, value}

  defp validate_statement(changeset) do
    case get_field(changeset, :statement) do
      nil ->
        changeset

      sql when is_binary(sql) ->
        if String.trim(sql) == "" do
          add_error(changeset, :statement, "cannot be empty")
        else
          changeset
        end

      _ ->
        add_error(changeset, :statement, "must be a string")
    end
  end

  defp validate_data_source(changeset) do
    case get_change(changeset, :data_source) do
      nil ->
        changeset

      "" ->
        put_change(changeset, :data_source, nil)

      source_name when is_binary(source_name) ->
        if source_name in Map.keys(Config.data_sources()) do
          changeset
        else
          add_error(
            changeset,
            :data_source,
            "must be one of: #{Enum.join(Map.keys(Config.data_sources()), ", ")}"
          )
        end

      _ ->
        add_error(changeset, :data_source, "must be a string")
    end
  end

  defp validate_search_path(changeset) do
    case get_change(changeset, :search_path) do
      nil ->
        changeset

      "" ->
        put_change(changeset, :search_path, nil)

      sp when is_binary(sp) ->
        if valid_search_path?(sp),
          do: changeset,
          else:
            add_error(changeset, :search_path, "must be a comma-separated list of identifiers")

      _ ->
        add_error(changeset, :search_path, "is invalid")
    end
  end

  defp valid_search_path?(sp) do
    sp
    |> String.split(",")
    |> Enum.all?(fn schema ->
      schema = String.trim(schema)
      Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_]*$/, schema)
    end)
  end

  defp maybe_add_unique_constraint(changeset) do
    if Config.unique_names?() do
      unique_constraint(changeset, :name, name: "lotus_queries_name_index")
    else
      changeset
    end
  end
end
