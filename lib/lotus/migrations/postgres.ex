defmodule Lotus.Migrations.Postgres do
  @moduledoc false

  @behaviour Lotus.Migration

  use Ecto.Migration

  @latest_version 4
  @default_prefix "public"

  @impl Lotus.Migration
  def up(opts \\ []) do
    opts = with_defaults(opts, @latest_version)
    initial = migrated_version(opts)

    cond do
      initial == 0 ->
        change(1..opts.version, :up, opts)

      initial < opts.version ->
        change((initial + 1)..opts.version, :up, opts)

      true ->
        :ok
    end
  end

  @impl Lotus.Migration
  def down(opts \\ []) do
    opts = with_defaults(opts, 1)
    initial = max(migrated_version(opts), 1)

    if initial >= opts.version do
      change(initial..opts.version//-1, :down, opts)
    end
  end

  @impl Lotus.Migration
  def migrated_version(opts \\ []) do
    opts = with_defaults(opts, @latest_version)

    repo_module = Map.get_lazy(opts, :repo, fn -> repo() end)

    escaped_prefix = Map.fetch!(opts, :escaped_prefix)

    query = """
    SELECT pg_catalog.obj_description(pg_class.oid, 'pg_class')
    FROM pg_class
    LEFT JOIN pg_namespace ON pg_namespace.oid = pg_class.relnamespace
    WHERE pg_class.relname = 'lotus_queries'
    AND pg_namespace.nspname = '#{escaped_prefix}'
    """

    case repo_module.query(query, [], log: false) do
      {:ok, %{rows: [[version]]}} when is_binary(version) -> String.to_integer(version)
      _ -> 0
    end
  end

  defp change(range, direction, opts) do
    for index <- range do
      [__MODULE__, "V#{index}"]
      |> Module.concat()
      |> apply(direction, [opts])
    end

    case direction do
      :up -> record_version(opts, Enum.max(range))
      :down -> record_version(opts, Enum.min(range) - 1)
    end
  end

  defp with_defaults(opts, version) do
    opts = Enum.into(opts, %{prefix: @default_prefix, version: version})

    opts
    |> Map.put(:quoted_prefix, inspect(opts.prefix))
    |> Map.put(:escaped_prefix, String.replace(opts.prefix, "'", "\\'"))
  end

  defp record_version(_opts, 0), do: :ok

  defp record_version(opts, version) do
    opts = with_defaults(opts, version)
    quoted_prefix = Map.fetch!(opts, :quoted_prefix)
    execute("COMMENT ON TABLE #{quoted_prefix}.lotus_queries IS '#{version}'")
  end
end
