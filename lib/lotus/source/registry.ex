defmodule Lotus.Source.Registry do
  @moduledoc """
  Names the processes an adapter starts for a source, without minting atoms.

  Sources created in a UI carry arbitrary string names, and a registered
  process normally needs an atom. This `Registry` has unique keys, so a
  per-source process is reached through a via tuple whose key is a term:

      name = Lotus.Source.Registry.via(MyApp.Adapters.HTTP, "warehouse")
      {MyApp.Pool, name: name}

  `Lotus.Source.Supervisor` starts the registry. An adapter names the
  children it returns from `c:Lotus.Source.Adapter.source_children/2`
  through `via/2` and reaches them later with `whereis/2`. Adapters that run
  more than one process per source tag them with `via/3`.
  """

  @registry __MODULE__

  @type key :: {module(), String.t()} | {module(), String.t(), term()}

  @doc false
  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(_opts), do: Registry.child_spec(keys: :unique, name: @registry)

  @doc """
  Returns the via tuple for the process an adapter runs for `name`.
  """
  @spec via(module(), String.t()) :: {:via, Registry, {module(), key()}}
  def via(module, name) when is_atom(module) do
    {:via, Registry, {@registry, {module, name}}}
  end

  @doc """
  Returns the via tuple for one of several processes an adapter runs for
  `name`, told apart by `tag`.
  """
  @spec via(module(), String.t(), term()) :: {:via, Registry, {module(), key()}}
  def via(module, name, tag) when is_atom(module) do
    {:via, Registry, {@registry, {module, name, tag}}}
  end

  @doc """
  Returns the pid registered through `via/2`, or `nil` when the process is
  not running.
  """
  @spec whereis(module(), String.t()) :: pid() | nil
  def whereis(module, name) when is_atom(module), do: lookup({module, name})

  @doc """
  Returns the pid registered through `via/3`, or `nil` when the process is
  not running.
  """
  @spec whereis(module(), String.t(), term()) :: pid() | nil
  def whereis(module, name, tag) when is_atom(module), do: lookup({module, name, tag})

  defp lookup(key) do
    case Registry.lookup(@registry, key) do
      [{pid, _value}] -> pid
      [] -> nil
    end
  end
end
