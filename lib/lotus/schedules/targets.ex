defmodule Lotus.Schedules.Targets do
  @moduledoc """
  The schedule targets registered under `config :lotus, scheduler:
  [targets: %{...}]`, by name. See `Lotus.Schedules.Target`.
  """

  @doc "The registered targets, by name."
  @spec all() :: %{String.t() => module()}
  def all, do: Keyword.get(Lotus.Config.scheduler(), :targets) || %{}

  @doc "The module of a target, or `nil`."
  @spec fetch(String.t() | nil) :: module() | nil
  def fetch(nil), do: nil
  def fetch(type), do: Map.get(all(), type)

  @doc """
  What a schedule's target is, for people, as `c:Lotus.Schedules.Target.get/2`
  gives it, or `nil` when its type is not registered or it is gone.
  """
  @spec entry(Lotus.Storage.Schedule.t(), keyword()) :: Lotus.Schedules.Target.entry() | nil
  def entry(%{target_type: type, target_id: id}, opts \\ []) do
    case fetch(type) do
      nil -> nil
      module -> module.get(id, opts)
    end
  end
end
