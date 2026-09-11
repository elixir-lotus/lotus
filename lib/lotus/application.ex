defmodule Lotus.Application do
  @moduledoc """
  OTP application entry point for Lotus.

  Starts `Lotus.Supervisor` when `:lotus` is listed in your application's
  `:extra_applications` or started as a dependency. Hosts that would rather
  own the supervision tree start `Lotus.Supervisor` themselves instead.
  """

  use Application

  def start(_type, _args) do
    Lotus.Supervisor.start_link([])
  end
end
