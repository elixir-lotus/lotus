if Code.ensure_loaded?(Sake.Server) do
  defmodule Lotus.MCP.Support do
    @moduledoc false
    # What the MCP tools and resources share: the actor the host's principal
    # stands for, the data sources the endpoint exposes, and how results and
    # errors are shaped for a model to read.

    alias Lotus.MCP.Host
    alias Lotus.{Normalizer, Result}
    alias Lotus.Query.Statement
    alias Lotus.Source.Adapter

    require Logger

    @default_max_rows 500

    @doc "The host's `config :lotus, :mcp` settings."
    @spec config() :: keyword()
    def config, do: Application.get_env(:lotus, :mcp, [])

    @doc """
    The `:context` and `:scope` options the `Lotus` functions take, for the
    principal Sake put in `ctx.scope`. With `actor: {module, function}`
    configured (in `config :lotus, :mcp`, or by the serving server with
    `Lotus.MCP.Host`), the function receives the principal and returns both, as a
    keyword list or a map with atom keys; without it, the principal is
    both. Anything else raises rather than run with a `nil` scope the
    visibility resolver would read as nobody's.
    """
    @spec actor_opts(Sake.Context.t()) :: keyword()
    def actor_opts(%{scope: principal, assigns: assigns}) do
      case Host.setting(assigns, :actor) do
        {module, function} -> actor!(apply(module, function, [principal]))
        fun when is_function(fun, 1) -> actor!(fun.(principal))
        nil -> [context: principal, scope: principal]
      end
    end

    defp actor!(actor) when is_list(actor) or is_map(actor) do
      if Keyword.keyword?(Enum.to_list(actor)) and
           Enum.all?([:context, :scope], &has_key?(actor, &1)),
         do: [context: get(actor, :context), scope: get(actor, :scope)],
         else: invalid_actor!()
    end

    defp actor!(_other), do: invalid_actor!()

    # The value itself stays out of the message: it is the host's principal.
    @spec invalid_actor!() :: no_return()
    defp invalid_actor! do
      raise ArgumentError,
            "the :actor of `config :lotus, :mcp` must return [context: _, scope: _] " <>
              "or %{context: _, scope: _}"
    end

    defp has_key?(actor, key) when is_map(actor), do: Map.has_key?(actor, key)
    defp has_key?(actor, key), do: Keyword.has_key?(actor, key)
    defp get(actor, key) when is_map(actor), do: Map.fetch!(actor, key)
    defp get(actor, key), do: Keyword.fetch!(actor, key)

    @doc "The data sources the endpoint exposes: `data_sources:` in the config, or all."
    @spec data_source_names() :: [String.t()]
    def data_source_names do
      names = Lotus.list_data_source_names()

      case config()[:data_sources] do
        nil -> Enum.sort(names)
        allowed -> Enum.filter(Enum.sort(names), &(&1 in allowed))
      end
    end

    @doc """
    Checks that `name` is a data source the endpoint exposes. `nil` stands for
    the default source, which must be exposed too.
    """
    @spec data_source(String.t() | nil) :: {:ok, String.t()} | {:error, String.t()}
    def data_source(nil) do
      {name, _} = Lotus.default_data_source()
      data_source(name)
    end

    def data_source(name) when is_binary(name) do
      if name in data_source_names(),
        do: {:ok, name},
        else:
          {:error,
           "Unknown data source #{inspect(name)}. Call list_data_sources for the ones available."}
    end

    @doc "A saved query that runs against a data source the endpoint exposes."
    @spec fetch_query(term()) :: {:ok, Lotus.Storage.Query.t()} | {:error, String.t()}
    def fetch_query(id) do
      with %{} = query <- Lotus.get_query(id),
           true <- exposed?(query) do
        {:ok, query}
      else
        _ -> {:error, "No saved query with id #{inspect(id)}"}
      end
    end

    @doc "Whether a saved query runs against a data source the endpoint exposes."
    @spec exposed?(Lotus.Storage.Query.t()) :: boolean()
    def exposed?(query), do: match?({:ok, _}, data_source(query.data_source))

    @doc "A dashboard by id."
    @spec fetch_dashboard(term()) :: {:ok, Lotus.Storage.Dashboard.t()} | {:error, String.t()}
    def fetch_dashboard(id) do
      case Lotus.get_dashboard(id) do
        nil -> {:error, "No dashboard with id #{inspect(id)}"}
        dashboard -> {:ok, dashboard}
      end
    end

    @doc """
    Values by name (a query's variables, a dashboard's filters) as Lotus takes
    them: string keys. Anything but an object is no values.
    """
    @spec vars(term()) :: %{String.t() => term()}
    def vars(values) when is_map(values), do: Map.new(values, fn {k, v} -> {to_string(k), v} end)
    def vars(_values), do: %{}

    @variable_keys ~w(name type label default list widget)

    @doc """
    A saved query's variables from a tool's arguments: each an object with a
    name, a type (text, number or date) and optionally a label, a default, a
    widget and `list`. An options query is not taken: it is a statement of
    its own, which only a person should save.
    """
    @spec variables(term()) :: {:ok, [map()]} | {:error, String.t()}
    def variables(nil), do: {:ok, []}

    def variables(variables) when is_list(variables) do
      Enum.reduce_while(variables, {:ok, []}, fn variable, {:ok, acc} ->
        case variable_attrs(variable) do
          {:ok, attrs} -> {:cont, {:ok, acc ++ [attrs]}}
          {:error, _} = error -> {:halt, error}
        end
      end)
    end

    def variables(_variables), do: {:error, "variables must be a list of objects"}

    defp variable_attrs(variable) when is_map(variable) do
      attrs =
        variable
        |> Map.new(fn {k, v} -> {to_string(k), v} end)
        |> Map.take(@variable_keys)

      if variable_name?(attrs["name"]),
        do: default(attrs),
        else:
          {:error, "A variable's name must be letters, digits and _, starting with a letter or _"}
    end

    defp variable_attrs(_variable), do: {:error, "variables must be a list of objects"}

    defp variable_name?(name),
      do: is_binary(name) and Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_]*\z/, name)

    defp default(attrs) do
      case attrs["default"] do
        default when is_nil(default) or is_binary(default) ->
          {:ok, attrs}

        default when is_number(default) or is_boolean(default) ->
          {:ok, Map.put(attrs, "default", to_string(default))}

        _other ->
          {:error, "A variable's default must be a string, a number or a boolean"}
      end
    end

    @doc """
    Refuses a statement to save that would write: a saved query runs again
    later, in Lotus Web too, where `config :lotus, read_only: false` may let
    it.
    """
    @spec read_only_statement(String.t(), String.t()) :: :ok | {:error, String.t()}
    def read_only_statement(statement, data_source) do
      adapter = Lotus.Source.resolve!(data_source, nil)
      Adapter.sanitize_query(adapter, Statement.new(statement), read_only: true)
    end

    @list_limit 200

    @doc "The most items a list tool or resource list returns."
    def list_limit, do: @list_limit

    @doc "The row cap: `max_rows:` in the config, 500 by default."
    @spec max_rows() :: pos_integer()
    def max_rows, do: config()[:max_rows] || @default_max_rows

    @doc "The window options for a page of `limit` rows (capped) from `offset`."
    @spec window(integer() | nil, integer() | nil) :: keyword()
    def window(limit, offset) do
      limit = min(limit || 100, max_rows())
      [limit: limit, offset: offset || 0, count: :none]
    end

    @doc """
    A result as the model gets it: columns, rows as JSON-safe values, and
    whether more rows may follow the page.
    """
    @spec result(Result.t(), keyword()) :: map()
    def result(%Result{} = result, window) do
      rows = Enum.map(result.rows, fn row -> Enum.map(row, &Normalizer.normalize/1) end)
      limit = window[:limit]

      %{
        columns: result.columns,
        rows: rows,
        num_rows: length(rows),
        offset: window[:offset],
        has_more: limit != nil and length(rows) >= limit,
        duration_ms: result.duration_ms
      }
    end

    @doc "An error as a message for the model."
    @spec error(term()) :: String.t()
    def error(%Ecto.Changeset{} = changeset) do
      changeset
      |> Ecto.Changeset.traverse_errors(fn {message, opts} ->
        Enum.reduce(opts, message, fn {key, value}, acc ->
          String.replace(acc, "%{#{key}}", to_string(inspect_value(value)))
        end)
      end)
      |> Enum.map_join("; ", fn {field, messages} -> "#{field} #{inspect_errors(messages)}" end)
    end

    def error({:halted, reason}) when is_binary(reason), do: "Refused: #{reason}"
    def error({:halted, _reason}), do: "Refused"
    def error(:not_found), do: "Not found"
    # A data source's own message: the model needs it to fix its statement.
    def error(message) when is_binary(message), do: message

    def error(other) do
      Logger.warning("Lotus.MCP: #{inspect(other)}")
      "The operation failed"
    end

    defp inspect_value(value) when is_binary(value) or is_number(value) or is_atom(value),
      do: value

    defp inspect_value(value), do: inspect(value)

    defp inspect_errors(messages) when is_list(messages) do
      Enum.map_join(messages, ", ", fn
        message when is_binary(message) -> message
        nested -> inspect(nested)
      end)
    end

    defp inspect_errors(nested), do: inspect(nested)

    @doc "A timestamp as ISO 8601, or nil."
    @spec timestamp(DateTime.t() | NaiveDateTime.t() | nil) :: String.t() | nil
    def timestamp(nil), do: nil
    def timestamp(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
    def timestamp(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)

    @doc "A saved query's summary."
    @spec query_summary(Lotus.Storage.Query.t()) :: map()
    def query_summary(query) do
      %{
        id: query.id,
        name: query.name,
        description: query.description,
        data_source: query.data_source,
        variables: Enum.map(query.variables, &variable/1),
        updated_at: timestamp(query.updated_at)
      }
    end

    @doc "A saved query in full: its summary, statement and charts."
    @spec query_detail(Lotus.Storage.Query.t()) :: map()
    def query_detail(query) do
      query
      |> query_summary()
      |> Map.merge(%{
        statement: query.statement,
        charts:
          Enum.map(Lotus.list_visualizations(query.id), fn viz ->
            %{id: viz.id, name: viz.name, config: viz.config}
          end)
      })
    end

    defp variable(v) do
      %{
        name: v.name,
        type: v.type,
        label: v.label,
        default: v.default,
        list: v.list
      }
    end

    @doc "A dashboard's summary."
    @spec dashboard_summary(Lotus.Storage.Dashboard.t()) :: map()
    def dashboard_summary(dashboard) do
      %{
        id: dashboard.id,
        name: dashboard.name,
        description: dashboard.description,
        updated_at: timestamp(dashboard.updated_at)
      }
    end

    @doc "A dashboard in full: its summary, cards and filters."
    @spec dashboard_detail(Lotus.Storage.Dashboard.t()) :: map()
    def dashboard_detail(dashboard) do
      dashboard
      |> dashboard_summary()
      |> Map.merge(%{
        cards: Enum.map(dashboard_cards(dashboard), &card/1),
        filters:
          Enum.map(Lotus.list_dashboard_filters(dashboard.id), fn f ->
            %{
              id: f.id,
              name: f.name,
              label: f.label,
              type: f.filter_type,
              default: f.default_value
            }
          end)
      })
    end

    @doc """
    A dashboard's cards, with their queries, leaving out a query card whose
    query runs against a data source the endpoint does not expose.
    """
    @spec dashboard_cards(Lotus.Storage.Dashboard.t()) :: [Lotus.Storage.DashboardCard.t()]
    def dashboard_cards(dashboard) do
      dashboard.id
      |> Lotus.list_dashboard_cards(preload: [:query])
      |> Enum.filter(fn
        %{card_type: :query, query: %{} = query} -> exposed?(query)
        %{card_type: :query} -> false
        _card -> true
      end)
    end

    @doc "A dashboard card."
    @spec card(Lotus.Storage.DashboardCard.t()) :: map()
    def card(card) do
      %{
        id: card.id,
        type: card.card_type,
        title: card.title,
        query_id: card.query_id,
        chart: card.visualization_config,
        content: card.content,
        position: card.position,
        layout: card.layout && Map.take(card.layout, [:x, :y, :w, :h])
      }
    end
  end
end
