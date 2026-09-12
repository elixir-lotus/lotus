defmodule Lotus.Preflight.Relations do
  @moduledoc """
  Manages the preflight outcome stored in the process dictionary.

  This module provides a clean interface for storing and retrieving
  the relations discovered during SQL preflight authorization, which are
  later used for column-level visibility policies and handed to
  `:before_execute` middleware.

  The stored value is either a list of `{schema, table}` relations or
  `{:unrestricted, reason}` for an adapter that cannot name the relations a
  statement touches. The second form lets a caller tell "this statement
  touches no table" apart from "this adapter cannot say".
  """

  @process_key :lotus_preflight_relations

  @type relation :: {String.t() | nil, String.t()}
  @type outcome :: [relation()] | {:unrestricted, String.t()}

  @doc """
  Stores the preflight outcome in the process dictionary.

  Accepts the list of relations discovered during preflight authorization,
  or `{:unrestricted, reason}` when the adapter cannot name them.
  """
  @spec put(outcome()) :: :ok
  def put(relations) when is_list(relations), do: store(relations)
  def put({:unrestricted, reason} = outcome) when is_binary(reason), do: store(outcome)

  defp store(outcome) do
    Process.put(@process_key, outcome)
    :ok
  end

  @doc """
  Retrieves the preflight outcome from the process dictionary.

  Returns an empty list if no outcome has been stored.
  """
  @spec get() :: outcome()
  def get do
    Process.get(@process_key) || []
  end

  @doc """
  Retrieves and clears the preflight outcome from the process dictionary.

  This is typically called after the outcome has been consumed
  to ensure it doesn't leak to subsequent operations.
  """
  @spec take() :: outcome()
  def take do
    outcome = get()
    clear()
    outcome
  end

  @doc """
  Narrows a preflight outcome to the list of relations it names.

  An `{:unrestricted, reason}` outcome names none, so it narrows to `[]`.
  Column visibility policies use this: a relation Lotus cannot name is a
  relation it cannot write a policy for.
  """
  @spec to_list(outcome()) :: [relation()]
  def to_list(relations) when is_list(relations), do: relations
  def to_list({:unrestricted, _reason}), do: []

  @doc """
  Clears the stored outcome from the process dictionary.
  """
  @spec clear() :: :ok
  def clear do
    Process.delete(@process_key)
    :ok
  end
end
