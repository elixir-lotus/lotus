defmodule Lotus.Application do
  @moduledoc """
  OTP application entry point for Lotus.

  Starts `Lotus.Supervisor` when `:lotus` is listed in your application's
  `:extra_applications` or started as a dependency. Hosts that would rather
  own the supervision tree start `Lotus.Supervisor` themselves instead.
  """

  use Application

  require Logger

  def start(_type, _args) do
    :ok = warn_without_sake()
    :ok = Lotus.Delivery.Channels.Email.warn_if_misconfigured()
    Lotus.Supervisor.start_link([])
  end

  @doc false
  # Sake is optional, so without it `Lotus.MCP` is not compiled. A host that
  # configured MCP is told why, rather than left with a module that silently
  # does not exist.
  @spec warn_without_sake(boolean()) :: :ok
  def warn_without_sake(sake? \\ Code.ensure_loaded?(Sake.Server)) do
    if not sake? and Application.get_env(:lotus, :mcp) != nil do
      Logger.warning(
        "config :lotus, :mcp is set, but Sake is not a dependency, so Lotus.MCP is not " <>
          "compiled. Add {:sake, \"~> 0.4\"} to your deps and recompile lotus " <>
          "(mix deps.compile lotus --force) to serve MCP."
      )
    end

    :ok
  end
end
