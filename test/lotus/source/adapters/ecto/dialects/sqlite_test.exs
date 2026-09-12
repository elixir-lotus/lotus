defmodule Lotus.Source.Adapters.Ecto.Dialects.SQLite3Test do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Lotus.Source.Adapters.Ecto.Dialects.Default
  alias Lotus.Source.Adapters.Ecto.Dialects.SQLite3

  defmodule PragmaRaisingRepo do
    def checkout(fun), do: fun.()

    def query("PRAGMA query_only"), do: raise(Process.get(:pragma_error))

    def transaction(fun, _opts), do: {:ok, fun.()}
  end

  describe "execute_in_transaction/3 when PRAGMA query_only raises" do
    test "runs the transaction without the pragma when SQLite does not know it" do
      Process.put(:pragma_error, %Exqlite.Error{message: "no such pragma: query_only"})

      log =
        capture_log(fn ->
          assert {:ok, :ran} =
                   SQLite3.execute_in_transaction(PragmaRaisingRepo, fn -> :ran end, [])
        end)

      assert log =~ "does not support PRAGMA query_only"
    end

    test "returns the error for any other Exqlite error" do
      Process.put(:pragma_error, %Exqlite.Error{message: "database is locked"})

      assert {:error, "database is locked"} =
               SQLite3.execute_in_transaction(PragmaRaisingRepo, fn -> :ran end, [])
    end

    test "returns the error for a non-Exqlite exception with a pragma message" do
      Process.put(:pragma_error, %RuntimeError{message: "no such pragma: query_only"})

      assert {:error, "no such pragma: query_only"} =
               SQLite3.execute_in_transaction(PragmaRaisingRepo, fn -> :ran end, [])
    end
  end

  describe "format_error/1" do
    test "prefixes an Exqlite error message" do
      assert SQLite3.format_error(%Exqlite.Error{message: "no such table: missing"}) ==
               "SQLite Error: no such table: missing"
    end

    test "delegates other errors to the default dialect" do
      assert SQLite3.format_error("boom") == Default.format_error("boom")
    end
  end
end
