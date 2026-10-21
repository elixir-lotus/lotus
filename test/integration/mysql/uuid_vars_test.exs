defmodule Lotus.Integration.Mysql.UuidVarsTest do
  @moduledoc """
  A variable compared with a UUID column must be bound in the form the column
  stores: text for char(36) and char(32), 16 raw bytes for binary(16).
  Binding the bytes against a text column matches nothing, without an error.
  """

  use Lotus.Case, async: false

  @moduletag :mysql

  alias Lotus.Storage.Query
  alias Lotus.Test.MysqlRepo

  # Lotus looks up a bound column's type only for a schema-qualified MySQL
  # table, so the statements name the database.
  @database MysqlRepo.config()[:database]

  @uuid "550e8400-e29b-41d4-a716-446655440000"
  @hex "550e8400e29b41d4a716446655440000"

  setup do
    {:ok, bytes} = Ecto.UUID.dump(@uuid)

    MysqlRepo.query!(
      "INSERT INTO test_uuid_keys (text_id, hex_id, binary_id, label) VALUES (?, ?, ?, ?)",
      [@uuid, @hex, bytes, "match"]
    )

    :ok
  end

  defp run(column, value) do
    query = %Query{
      statement: "SELECT label FROM #{@database}.test_uuid_keys WHERE #{column} = {{id}}",
      variables: [%{name: "id", type: :text, default: nil}],
      data_source: "mysql"
    }

    Lotus.run_query(query, vars: %{"id" => value})
  end

  test "a char(36) column matches the UUID string" do
    assert {:ok, %{rows: [["match"]]}} = run("text_id", @uuid)
  end

  test "a char(32) column matches the hex form" do
    assert {:ok, %{rows: [["match"]]}} = run("hex_id", @hex)
  end

  test "a binary(16) column matches the UUID string, bound as its bytes" do
    assert {:ok, %{rows: [["match"]]}} = run("binary_id", @uuid)
  end

  test "a binary(16) column still rejects a value that is not a UUID" do
    assert {:error, message} = run("binary_id", "not-a-uuid")
    assert message =~ "Invalid UUID format"
  end
end
