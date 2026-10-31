defmodule Lotus.PreflightPartitionsTest do
  # A rule for a partitioned table holds for its partitions, which the plan
  # names instead of it.
  use Lotus.Case, async: false
  use Mimic

  alias Lotus.Test.Repo

  setup do
    Repo.query!("CREATE TABLE lotus_part_events (id int, secret text) PARTITION BY RANGE (id)")

    Repo.query!(
      "CREATE TABLE part_events_low PARTITION OF lotus_part_events FOR VALUES FROM (0) TO (100)"
    )

    Repo.query!(
      "CREATE TABLE part_events_high PARTITION OF lotus_part_events FOR VALUES FROM (100) TO (200) " <>
        "PARTITION BY RANGE (id)"
    )

    Repo.query!(
      "CREATE TABLE part_events_high_a PARTITION OF part_events_high FOR VALUES FROM (100) TO (150)"
    )

    Repo.query!("INSERT INTO lotus_part_events VALUES (1, 'low'), (120, 'high')")

    stub(Lotus.Config, :visibility_for_source_name, fn _source ->
      %{table: [deny: [{"public", "lotus_part_events"}]]}
    end)

    :ok
  end

  test "a partition of a denied table is denied, at any depth" do
    for sql <- [
          "SELECT secret FROM lotus_part_events",
          "SELECT secret FROM part_events_low",
          "SELECT secret FROM part_events_high_a"
        ] do
      assert {:error, "Query touches blocked table(s): " <> tables} =
               Lotus.run_statement(sql, [], repo: "postgres"),
             sql

      assert tables =~ "public.lotus_part_events"
    end
  end

  test "a table that is no partition is not touched" do
    assert {:ok, _} = Lotus.run_statement("SELECT title FROM test_posts", [], repo: "postgres")
  end
end
