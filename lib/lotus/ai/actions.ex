defmodule Lotus.AI.Actions do
  @moduledoc """
  Convenience module for AI actions.

  Actions implement the `Lotus.AI.Action` behaviour and serve as both
  executable functions and LLM tool definitions via `Tool.from_action/2`.
  """

  alias __MODULE__.{
    ExecuteSQL,
    GetColumnValues,
    DescribeTable,
    ListDataSources,
    ListSchemas,
    ListTables
  }

  @doc """
  Returns all schema introspection action modules.
  """
  def schema_actions do
    [ListSchemas, ListTables, DescribeTable, GetColumnValues]
  end

  @doc """
  Returns all action modules available to the investigation agent.
  """
  def investigation_actions do
    [ListDataSources, ListSchemas, ListTables, DescribeTable, GetColumnValues, ExecuteSQL]
  end
end
