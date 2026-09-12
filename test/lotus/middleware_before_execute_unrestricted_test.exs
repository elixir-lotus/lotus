defmodule Lotus.MiddlewareBeforeExecuteUnrestrictedTest do
  @moduledoc """
  An adapter that cannot name the relations a statement touches reaches
  `:before_execute` as `{:unrestricted, reason}`, not as `[]`.

  The distinction is the point: `[]` and `{:unrestricted, _}` both mean "Lotus
  cannot name the tables", but only the tuple says why, so a plug can log the
  adapter's own reason rather than guessing.
  """

  use ExUnit.Case, async: false
  use Mimic

  alias Lotus.Middleware
  alias Lotus.Query.Statement
  alias Lotus.Runner
  alias Lotus.Test.InMemoryAdapter

  @dataset_tables %{
    "users" => %{
      columns: ["id", "name"],
      rows: [[1, "Ada"]],
      types: %{"id" => "integer", "name" => "text"}
    }
  }

  defmodule CapturePlug do
    @moduledoc false
    def init(opts), do: opts

    def call(payload, _opts) do
      send(self(), {:before_execute, payload})
      {:cont, payload}
    end
  end

  setup :set_mimic_from_context

  setup do
    Mimic.copy(Lotus.Config)
    on_exit(fn -> :persistent_term.erase({Lotus.Middleware, :compiled}) end)
    :ok
  end

  defp adapter do
    InMemoryAdapter.adapter("mem", InMemoryAdapter.dataset(tables: @dataset_tables))
  end

  defp stmt(body), do: %Statement{adapter: InMemoryAdapter, body: body}

  test "an adapter that can name its relations yields the list" do
    stub(Lotus.Config, :allow_unrestricted_resources?, fn _name -> false end)
    Middleware.compile(%{before_execute: [{CapturePlug, []}]})

    assert {:ok, _result} = Runner.run_statement(adapter(), stmt(%{from: "users"}))

    assert_received {:before_execute, payload}
    assert payload.relations == [{nil, "users"}]
  end

  test "an adapter that cannot name its relations yields {:unrestricted, reason}" do
    stub(Lotus.Config, :allow_unrestricted_resources?, fn "mem" -> true end)
    Middleware.compile(%{before_execute: [{CapturePlug, []}]})

    # A DSL body with no `:from` is one the in-memory adapter cannot analyse,
    # so `extract_accessed_resources/2` returns `{:unrestricted, reason}`.
    Runner.run_statement(adapter(), stmt(%{select: ["id"]}))

    assert_received {:before_execute, payload}
    assert {:unrestricted, reason} = payload.relations
    assert reason =~ "missing :from"
  end
end
