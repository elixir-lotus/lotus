defmodule Lotus.Storage.RenamedAttrsTest do
  @moduledoc """
  A stale `data_repo` attribute must fail the changeset rather than save a
  query with no source, which would silently run against the default database.
  """

  use Lotus.Case, async: true

  alias Lotus.Storage.Query

  @base %{name: "Stale", statement: "SELECT 1"}

  test "an atom-keyed data_repo attribute is rejected" do
    changeset = Query.changeset(%Query{}, Map.put(@base, :data_repo, "analytics"))

    refute changeset.valid?
    assert {msg, _} = changeset.errors[:data_source]
    assert msg =~ "renamed to `data_source`"
  end

  test "a string-keyed data_repo attribute is rejected" do
    attrs = %{"name" => "Stale", "statement" => "SELECT 1", "data_repo" => "analytics"}
    changeset = Query.changeset(%Query{}, attrs)

    refute changeset.valid?
    assert changeset.errors[:data_source]
  end

  test "data_source is accepted" do
    changeset = Query.changeset(%Query{}, Map.put(@base, :data_source, "postgres"))

    assert changeset.valid?
    assert Ecto.Changeset.get_field(changeset, :data_source) == "postgres"
  end
end
