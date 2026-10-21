if Code.ensure_loaded?(Sake.Server) do
  defmodule Lotus.MCP.Host do
    @moduledoc """
    How the Sake server that serves `Lotus.MCP` tells it who may use Lotus
    and as which actor, instead of `config :lotus, :mcp`. A middleware for
    `:before_request`:

        defmodule MyApp.MCP do
          use Sake.Server, name: "my-app", version: "1.0.0"

          mount Lotus.MCP, prefix: "lotus"

          middleware :before_request, [
            {Lotus.MCP.Host, authorize: {MyApp.Reporting, :lotus_user?},
                             actor: {MyApp.Reporting, :lotus_actor}}
          ]
        end

    `:authorize` and `:actor` take what the same keys of `config :lotus, :mcp`
    take, as `{module, function}`, and mean the same. `Lotus.Web.MCP`
    declares it with your resolver, so a host serving Lotus Web's server sets
    neither.

    `config :lotus, :mcp` still wins where it sets a key: an app that has it
    keeps the decisions it made there.
    """

    @behaviour Sake.Middleware

    alias Lotus.MCP.Support

    @keys [:authorize, :actor]

    @impl true
    def init(opts) do
      case Keyword.keys(opts) -- @keys do
        [] ->
          opts

        keys ->
          raise ArgumentError, "Lotus.MCP.Host takes :authorize and :actor, got #{inspect(keys)}"
      end
    end

    @impl true
    def call(%{assigns: assigns} = payload, opts),
      do: {:cont, %{payload | assigns: Map.put(assigns, __MODULE__, opts)}}

    @doc false
    # The `key` of `config :lotus, :mcp`, else the one the serving server
    # declared for this request.
    @spec setting(map(), atom()) :: term()
    def setting(assigns, key) do
      case Support.config()[key] do
        nil -> assigns |> Map.get(__MODULE__, []) |> Keyword.get(key)
        value -> value
      end
    end
  end
end
