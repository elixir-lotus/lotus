defmodule Lotus.ConfigRenamedKeysTest do
  @moduledoc """
  A v0.x config must fail with an error that names the rename, not with a
  "required :storage_repo option not found" that points at the wrong problem.
  """

  use ExUnit.Case, async: false

  setup do
    original = Application.get_all_env(:lotus)

    on_exit(fn ->
      for {k, _} <- Application.get_all_env(:lotus), do: Application.delete_env(:lotus, k)
      for {k, v} <- original, do: Application.put_env(:lotus, k, v)
      Lotus.Config.reload!()
    end)

    :ok
  end

  test "a renamed key raises and names both the old and the new key" do
    Application.put_env(:lotus, :ecto_repo, Lotus.Test.Repo)

    assert_raise ArgumentError, ~r/renamed in Lotus v1\.0.*:ecto_repo -> :storage_repo/s, fn ->
      Lotus.Config.reload!()
    end
  end

  test "every renamed key present is listed, not just the first" do
    Application.put_env(:lotus, :data_repos, %{})
    Application.put_env(:lotus, :default_repo, "main")

    error = assert_raise(ArgumentError, fn -> Lotus.Config.reload!() end)

    assert error.message =~ ":data_repos -> :data_sources"
    assert error.message =~ ":default_repo -> :default_source"
  end
end
