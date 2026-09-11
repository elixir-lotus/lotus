defmodule Lotus.AI.Action do
  @moduledoc """
  Behaviour for AI tool actions.

  Defines the contract for modules that can be used as LLM tools via
  `Lotus.AI.Tool.from_action/2`. Implement this behaviour
  to create custom tools that the AI agent can invoke.

  ## Example

      defmodule MyApp.AI.Actions.SearchDocs do
        @behaviour Lotus.AI.Action

        @impl true
        def name, do: "search_docs"

        @impl true
        def description, do: "Search internal documentation for relevant articles"

        @impl true
        def schema do
          [
            query: [type: :string, required: true, doc: "Search query string"],
            limit: [type: :integer, doc: "Max results to return (default: 10)"]
          ]
        end

        @impl true
        def run(params, _context) do
          results = MyApp.Docs.search(params.query, limit: params[:limit] || 10)
          {:ok, %{results: results}}
        end
      end

  The schema uses NimbleOptions format. See `NimbleOptions` for available types.
  """

  @doc """
  Returns the tool name used by the LLM (e.g., "list_schemas", "execute_statement").
  """
  @callback name() :: String.t()

  @doc """
  Returns a description of what the tool does, shown to the LLM.
  """
  @callback description() :: String.t()

  @doc """
  Returns the parameter schema in NimbleOptions format.

  Each key defines a parameter the LLM can provide. Use `:doc` to describe
  the parameter to the LLM, `:required` to mark mandatory params, and
  `:type` for the data type.
  """
  @callback schema() :: keyword()

  @doc """
  Executes the action with validated parameters.

  Returns `{:ok, result_map}` on success or `{:error, reason}` on failure.
  The result map will be JSON-encoded and returned to the LLM.
  """
  @callback run(params :: map(), context :: map()) ::
              {:ok, map()} | {:error, term()}

  @doc """
  Turn an action's `context` into the `:context` / `:scope` options the
  `Lotus` functions take.

  An action that queries or introspects on the user's behalf must pass these
  on, or middleware and the visibility resolver see no actor for anything the
  AI does:

      def run(params, context) do
        Lotus.Schema.list_tables(params.data_source, Action.actor_opts(context))
      end

  Keys the caller did not supply are omitted rather than passed as `nil`, so
  the behaviour matches calling the function without them.
  """
  @spec actor_opts(map()) :: keyword()
  def actor_opts(context) when is_map(context) do
    Enum.flat_map([:context, :scope], fn key ->
      case Map.fetch(context, key) do
        {:ok, value} -> [{key, value}]
        :error -> []
      end
    end)
  end

  def actor_opts(_), do: []
end
