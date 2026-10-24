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
  """

  @type relation :: {String.t() | nil, String.t()}
  @type outcome :: [relation()] | {:unrestricted, String.t()} | {:skipped, String.t()}

  @doc """
  Narrows a preflight outcome to the list of relations it names.

  An unknown outcome names none, so it narrows to `[]`. Column visibility
  policies use this: a relation Lotus cannot name is a relation it cannot
  write a policy for.
  """
  @spec to_list(outcome()) :: [relation()]
  def to_list(relations) when is_list(relations), do: relations
  def to_list({tag, _reason}) when tag in [:unrestricted, :skipped], do: []
end
