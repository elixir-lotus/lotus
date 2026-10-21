if Code.ensure_loaded?(Sake.Server) do
  defmodule Lotus.MCP.Authorize do
    @moduledoc false
    # Who may use Lotus over MCP at all, asked of the host on every request:
    # `config :lotus, :mcp, authorize: {module, function}` (or a one-argument
    # function), or the `authorize:` the serving server declared with
    # `Lotus.MCP.Host`, takes the principal and returns true to allow. Without
    # either, nobody may: a signed-in person is not a Lotus user until the
    # host says so, since its login may be its customers' too.
    #
    # It filters the lists, and so every call, since Sake asks `:after_list`
    # again before a call reaches a component: what a refused principal is
    # not shown, it cannot call or read.

    alias Lotus.MCP.Host

    require Logger

    def init(opts), do: opts

    def call(%{items: _, ctx: ctx, assigns: assigns} = payload, _opts) do
      if allowed?(ctx.scope, assigns),
        do: {:cont, payload},
        else: {:cont, %{payload | items: []}}
    end

    @doc "Whether the host allows `principal` to use Lotus over MCP."
    @spec allowed?(term(), map()) :: boolean()
    def allowed?(principal, assigns) do
      case Host.setting(assigns, :authorize) do
        {module, function} ->
          apply(module, function, [principal]) == true

        fun when is_function(fun, 1) ->
          fun.(principal) == true

        nil ->
          Logger.warning(
            "Lotus.MCP refused a request: set `config :lotus, :mcp, authorize: ...`, " <>
              "or declare Lotus.MCP.Host on the server that serves it, " <>
              "to say who may use Lotus over MCP (see the MCP guide)"
          )

          false
      end
    end
  end
end
