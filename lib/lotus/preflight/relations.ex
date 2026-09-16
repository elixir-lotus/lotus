defmodule Lotus.Preflight.Relations do
  @moduledoc """
  The preflight outcome: what Lotus knows about the relations a statement
  touches.

  The outcome is one of:

    * a list of `{schema, table}` relations preflight proved the statement
      touches — an empty list means it touches none;
    * `{:unrestricted, reason}` for an adapter that cannot name the relations
      a statement touches, when the host opted in;
    * `{:skipped, reason}` for a statement the adapter does not preflight.

  The two tuples both mean "unknown". A consumer that gates on the list
  matches `when is_list/1` and refuses any tuple rather than reading it as an
  empty set.

  `Lotus.Preflight.analyze/4` returns the outcome as a value, and
  `Lotus.Runner` carries it down the pipeline explicitly: middleware reads it
  from the `:relations` key of the `:before_execute` and `:after_query`
  payloads. The runner neither writes nor reads the process dictionary.

  `put/1`, `get/0`, `take/0` and `clear/0` still store an outcome in the
  process dictionary for callers that did so themselves. They are deprecated:
  process state is invisible to supervision, leaks across queries in a reused
  process and cannot cross a `Task` boundary. They are removed in v2.0.
  """

  @process_key :lotus_preflight_relations

  @type relation :: {String.t() | nil, String.t()}
  @type outcome :: [relation()] | {:unrestricted, String.t()} | {:skipped, String.t()}

  @doc """
  Stores a preflight outcome in the process dictionary.
  """
  @deprecated "Carry the outcome of Lotus.Preflight.analyze/4 as a value instead"
  @spec put(outcome()) :: :ok
  def put(relations) when is_list(relations), do: store(relations)

  def put({tag, reason} = outcome) when tag in [:unrestricted, :skipped] and is_binary(reason),
    do: store(outcome)

  defp store(outcome) do
    Process.put(@process_key, outcome)
    :ok
  end

  @doc """
  Retrieves the stored preflight outcome, or an empty list.
  """
  @deprecated "Read the :relations key of the :before_execute or :after_query middleware payload, or call Lotus.Preflight.analyze/4"
  @spec get() :: outcome()
  def get do
    Process.get(@process_key) || []
  end

  @doc """
  Retrieves and clears the stored preflight outcome.
  """
  @deprecated "Read the :relations key of the :before_execute or :after_query middleware payload, or call Lotus.Preflight.analyze/4"
  @spec take() :: outcome()
  def take do
    outcome = get()
    clear()
    outcome
  end

  @doc """
  Narrows a preflight outcome to the list of relations it names.

  An unknown outcome names none, so it narrows to `[]`. Column visibility
  policies use this: a relation Lotus cannot name is a relation it cannot
  write a policy for.
  """
  @spec to_list(outcome()) :: [relation()]
  def to_list(relations) when is_list(relations), do: relations
  def to_list({tag, _reason}) when tag in [:unrestricted, :skipped], do: []

  @doc """
  Clears the stored preflight outcome.
  """
  @deprecated "Nothing needs clearing once the outcome travels as a value"
  @spec clear() :: :ok
  def clear do
    Process.delete(@process_key)
    :ok
  end
end
