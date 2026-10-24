defmodule Lotus.Storage.OwnershipTest do
  @moduledoc """
  The `owner_id` and `tenant_id` of queries and dashboards: set from options,
  never from attributes, filtered on in lists, and scoping the uniqueness of
  names.
  """

  use Lotus.Case, async: true

  alias Lotus.{Dashboards, Storage}
  alias Lotus.Storage.{Dashboard, Query}

  defp create_query(name, opts \\ []) do
    Storage.create_query(%{name: name, statement: "SELECT 1"}, opts)
  end

  describe "queries" do
    test "a create takes the owner and the tenant from the options" do
      assert {:ok, %Query{owner_id: "42", tenant_id: "acme"}} =
               create_query("Orders", owner_id: "42", tenant_id: "acme")

      assert {:ok, %Query{owner_id: nil, tenant_id: nil}} = create_query("Users")
    end

    test "an integer id is stored as a string, and \"\" as nil" do
      assert {:ok, %Query{owner_id: "42", tenant_id: nil}} =
               create_query("Orders", owner_id: 42, tenant_id: "")
    end

    test "an id that is neither is an error on the field" do
      assert {:error, changeset} = create_query("Orders", owner_id: %{id: 42})
      assert %{owner_id: ["must be a string, an integer or nil"]} = errors_on(changeset)
    end

    test "the attributes do not set them" do
      assert {:ok, %Query{owner_id: nil, tenant_id: nil}} =
               Storage.create_query(%{
                 "name" => "Orders",
                 "statement" => "SELECT 1",
                 "owner_id" => "42",
                 "tenant_id" => "acme"
               })
    end

    test "an update keeps what it is not given, and clears what it is given as nil" do
      {:ok, query} = create_query("Orders", owner_id: "42", tenant_id: "acme")

      assert {:ok, %Query{owner_id: "42", tenant_id: "acme"} = query} =
               Storage.update_query(query, %{name: "All orders"})

      assert {:ok, %Query{owner_id: "7", tenant_id: "acme"} = query} =
               Storage.update_query(query, %{}, owner_id: "7")

      assert {:ok, %Query{owner_id: "7", tenant_id: nil}} =
               Storage.update_query(query, %{}, tenant_id: nil)
    end

    test "a name is unique within a tenant" do
      assert {:ok, _} = create_query("Revenue", tenant_id: "acme")
      assert {:ok, _} = create_query("Revenue", tenant_id: "globex")
      assert {:ok, _} = create_query("Revenue")

      assert {:error, changeset} = create_query("Revenue", tenant_id: "acme")
      assert %{name: ["has already been taken"]} = errors_on(changeset)

      assert {:error, changeset} = create_query("Revenue")
      assert %{name: ["has already been taken"]} = errors_on(changeset)
    end

    test "list_queries_by/1 filters by owner and tenant" do
      {:ok, mine} = create_query("Mine", owner_id: "42", tenant_id: "acme")
      {:ok, theirs} = create_query("Theirs", owner_id: "7", tenant_id: "acme")
      {:ok, other} = create_query("Other tenant", owner_id: "42", tenant_id: "globex")
      {:ok, shared} = create_query("Shared")

      names = fn opts ->
        opts |> Storage.list_queries_by() |> Enum.map(& &1.name) |> Enum.sort()
      end

      assert names.(tenant_id: "acme") == ["Mine", "Theirs"]
      assert names.(tenant_id: "acme", owner_id: "42") == [mine.name]
      assert names.(owner_id: 42) == ["Mine", "Other tenant"]
      assert names.(tenant_id: nil) == [shared.name]
      assert names.(tenant_id: ["acme", nil]) == ["Mine", "Shared", "Theirs"]
      assert names.(tenant_id: ["acme", "globex"]) == ["Mine", "Other tenant", "Theirs"]
      assert names.(tenant_id: []) == []
      assert names.(tenant_id: "acme", search: "the") == [theirs.name]
      assert length(names.([])) == 4
      assert other.tenant_id == "globex"
    end

    test "a filter by something that is not an id raises" do
      assert_raise ArgumentError, ~r/:owner_id or :tenant_id filter/, fn ->
        Storage.list_queries_by(owner_id: [%{id: 42}])
      end
    end
  end

  describe "dashboards" do
    test "a create and an update take the owner and the tenant from the options" do
      assert {:ok, %Dashboard{owner_id: "42", tenant_id: "acme"} = dashboard} =
               Dashboards.create_dashboard(%{name: "Sales", tenant_id: "ignored"},
                 owner_id: "42",
                 tenant_id: "acme"
               )

      assert {:ok, %Dashboard{owner_id: nil, tenant_id: "acme"}} =
               Lotus.update_dashboard(dashboard, %{}, owner_id: nil)
    end

    test "a name is unique within a tenant" do
      assert {:ok, _} = Dashboards.create_dashboard(%{name: "Sales"}, tenant_id: "acme")
      assert {:ok, _} = Dashboards.create_dashboard(%{name: "Sales"}, tenant_id: "globex")

      assert {:error, changeset} =
               Dashboards.create_dashboard(%{name: "Sales"}, tenant_id: "acme")

      assert %{name: ["has already been taken"]} = errors_on(changeset)
    end

    test "list_dashboards_by/1 filters by owner and tenant" do
      {:ok, _} = Dashboards.create_dashboard(%{name: "A"}, owner_id: "42", tenant_id: "acme")
      {:ok, _} = Dashboards.create_dashboard(%{name: "B"}, owner_id: "7", tenant_id: "acme")
      {:ok, _} = Dashboards.create_dashboard(%{name: "C"})

      names = fn opts -> opts |> Lotus.list_dashboards_by() |> Enum.map(& &1.name) end

      assert names.(tenant_id: "acme") == ["A", "B"]
      assert names.(tenant_id: "acme", owner_id: "7") == ["B"]
      assert names.(owner_id: nil) == ["C"]
    end
  end
end
