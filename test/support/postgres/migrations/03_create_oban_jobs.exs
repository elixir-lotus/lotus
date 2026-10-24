defmodule Lotus.Test.Repo.Migrations.CreateObanJobs do
  use Ecto.Migration

  # For Lotus.Scheduler.Oban: a host that runs schedules through Oban has
  # its tables.
  def up, do: Oban.Migrations.up()
  def down, do: Oban.Migrations.down()
end
