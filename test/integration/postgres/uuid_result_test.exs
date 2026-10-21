defmodule Lotus.Integration.Postgres.UuidResultTest do
  @moduledoc """
  Postgrex returns a uuid column as 16 raw bytes, and those bytes are valid
  UTF-8 for about one v4 UUID in 15,000. Such a UUID must still come out of
  a result in its string form, not as the raw bytes.
  """

  use Lotus.Case, async: true

  @moduletag :postgres

  test "a uuid whose bytes are valid UTF-8 comes out as a UUID string" do
    uuid = "17d1945a-6f6a-43c6-a81f-6d74d2bbc5a3"

    assert {:ok, result} =
             Lotus.run_statement("SELECT '#{uuid}'::uuid AS id", [], repo: "postgres")

    assert [[raw]] = result.rows
    assert String.valid?(raw)

    assert %{rows: [[^uuid]]} = Lotus.Result.to_encodable(result)
    assert Lotus.Value.to_display_string(raw) == uuid
  end
end
