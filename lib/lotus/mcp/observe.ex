if Code.ensure_loaded?(Sake.Server) do
  defmodule Lotus.MCP.Observe do
    @moduledoc false
    # Every tool call and resource read of Lotus.MCP, as the
    # `[:lotus, :mcp, :call]` telemetry event (`Lotus.Telemetry`): when it
    # starts (`:before_call`, `:before_read`), its start time goes in the
    # request's assigns; when it answers, the event carries it with the
    # actor Lotus ran it as.

    alias Lotus.MCP.Support

    @event [:lotus, :mcp, :call]

    def init(opts), do: opts

    def call(%{result: result, ctx: ctx, assigns: assigns} = payload, _opts) do
      {kind, name, arguments} = called(payload)
      started = assigns[:lotus_mcp_started] || System.monotonic_time()
      actor = Support.actor_opts(ctx)

      :telemetry.execute(@event, %{duration: System.monotonic_time() - started}, %{
        kind: kind,
        name: name,
        arguments: arguments,
        status: status(result),
        context: actor[:context],
        scope: actor[:scope]
      })

      {:cont, payload}
    end

    def call(%{assigns: assigns} = payload, _opts) do
      {:cont, %{payload | assigns: Map.put(assigns, :lotus_mcp_started, System.monotonic_time())}}
    end

    defp called(%{tool: tool, arguments: arguments}), do: {:tool, tool.name, arguments}
    defp called(%{uri: uri} = payload), do: {:resource, uri, payload[:params] || %{}}

    defp status(%{"isError" => true}), do: :error
    defp status(_result), do: :ok
  end
end
