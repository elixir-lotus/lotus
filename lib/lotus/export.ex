defmodule Lotus.Export do
  @moduledoc """
  Export functionality for Lotus.Result to various formats.
  """

  alias Lotus.Config
  alias Lotus.{Dashboards, Result}
  alias Lotus.Storage.{Dashboard, Query}
  alias Lotus.Value

  @default_page_size 1000

  @doc """
  Converts a Result struct to CSV format using NimbleCSV.
  Returns iodata for efficient streaming.
  """
  NimbleCSV.define(CSVParser, separator: ",", escape: "\"")

  @spec to_csv(Result.t()) :: [binary() | iodata()]
  def to_csv(%Result{columns: columns, rows: rows}) do
    header = CSVParser.dump_to_iodata([columns])

    body =
      rows
      |> Stream.map(&normalize_row_for_csv/1)
      |> Stream.map(&CSVParser.dump_to_iodata([&1]))
      |> Enum.to_list()

    [header | body]
  end

  @doc """
  Runs a Query and converts the full, unpaginated result to CSV iodata.

  Accepts a `%Lotus.Storage.Query{}` and Lotus options such as `:repo`, `:vars`,
  and `:search_path`. Pagination is explicitly disabled (no window) to fetch all
  matching rows.

  Raises on execution errors.
  """
  @spec to_csv(Query.t(), keyword()) :: [binary() | iodata()]
  def to_csv(%Query{} = q, opts \\ []) do
    run_opts = Keyword.merge(opts, window: nil)

    case Lotus.run_query(q, run_opts) do
      {:ok, %Result{} = res} -> to_csv(res)
      {:error, err} -> raise ArgumentError, "to_csv/2 failed: #{inspect(err)}"
    end
  end

  @doc """
  Converts a Result struct to JSON format.
  Returns a binary string containing a JSON array of objects.
  """
  @spec to_json(Result.t()) :: binary()
  def to_json(%Result{columns: columns, rows: rows}) do
    rows
    |> Stream.map(&row_to_map_for_json(columns, &1))
    |> Enum.to_list()
    |> Lotus.JSON.encode!()
  end

  @doc """
  Converts a Result struct to JSONL (JSON Lines) format.
  Returns a binary string with one JSON object per line.
  """
  @spec to_jsonl(Result.t()) :: binary()
  def to_jsonl(%Result{columns: columns, rows: rows}) do
    rows
    |> Stream.map(&row_to_map_for_json(columns, &1))
    |> Stream.map(&Lotus.JSON.encode!/1)
    |> Stream.intersperse("\n")
    |> Enum.join()
  end

  @doc """
  Stream a CSV export for a Query by fetching pages of results.

  Uses windowed pagination under the hood and outputs CSV iodata chunks. The
  first yielded chunk contains the header row. Subsequent chunks contain rows.

  Options:
  - `:page_size` — page size used for windowed fetching (defaults to configured
    Lotus default page size or 1000)
  - Any `Lotus.run_query/2` option such as `:repo`, `:vars`, `:search_path`.

  Raises on execution errors during streaming.
  """
  @spec stream_csv(Query.t(), keyword()) :: Enumerable.t()
  def stream_csv(%Query{} = q, opts \\ []) do
    page_size = Keyword.get(opts, :page_size, Config.default_page_size() || @default_page_size)

    Stream.resource(
      fn -> %{offset: 0, header?: false} end,
      fn %{offset: off, header?: header?} = state ->
        run_opts = Keyword.merge(opts, window: [limit: page_size, offset: off, count: :none])

        Lotus.run_query(q, run_opts)
        |> handle_csv_query_result(state, off, header?)
      end,
      fn _ -> :ok end
    )
  end

  @doc """
  Streams a saved query's export to `fun`, without holding the whole result:
  the rows are read from the source as `fun` consumes the export (see
  `Lotus.stream_query/3`), one chunk at a time.

  `format` is `:csv` (a header line, then a line per row) or `:jsonl` (a JSON
  object per row, one per line). `fun` receives an `Enumerable` of iodata
  and runs inside the query's transaction, so it writes the export where it
  goes (a file, an upload, a chunked HTTP response) before it returns.

      {:ok, :ok} =
        Lotus.Export.stream(query, :csv, [vars: %{"region" => "north"}], fn iodata ->
          File.open!("orders.csv", [:write], fn file -> Enum.each(iodata, &IO.binwrite(file, &1)) end)
          :ok
        end)

  Returns `{:ok, fun_result}` or `{:error, reason}`. Takes the options of
  `Lotus.stream_query/3`, so the same checks, middleware and column policies
  apply as for any run. Unlike `stream_csv/2`, which runs one paginated query
  per page, it runs the query once.
  """
  @spec stream(Query.t(), :csv | :jsonl, keyword(), (Enumerable.t() -> result)) ::
          {:ok, result} | {:error, term()}
        when result: term()
  def stream(%Query{} = q, format, opts \\ [], fun)
      when format in [:csv, :jsonl] and is_function(fun, 1) do
    Lotus.stream_query(q, opts, fn chunks -> fun.(encode_chunks(chunks, format)) end)
  end

  defp encode_chunks(chunks, :csv) do
    Stream.transform(chunks, false, fn %Result{columns: cols, rows: rows}, header? ->
      header = if header?, do: [], else: [CSVParser.dump_to_iodata([cols])]
      body = Enum.map(rows, &CSVParser.dump_to_iodata([normalize_row_for_csv(&1)]))
      {header ++ body, true}
    end)
  end

  defp encode_chunks(chunks, :jsonl) do
    Stream.flat_map(chunks, fn %Result{columns: cols, rows: rows} ->
      Enum.map(rows, &[Lotus.JSON.encode!(row_to_map_for_json(cols, &1)), "\n"])
    end)
  end

  defp handle_csv_query_result({:ok, %Result{columns: _cols, rows: []}}, state, _off, _header?) do
    {:halt, state}
  end

  defp handle_csv_query_result({:ok, %Result{columns: cols, rows: rows}}, _state, off, header?) do
    header = if header?, do: [], else: [CSVParser.dump_to_iodata([cols])]

    body =
      rows
      |> Stream.map(&normalize_row_for_csv/1)
      |> Stream.map(&CSVParser.dump_to_iodata([&1]))
      |> Enum.to_list()

    next = %{offset: off + length(rows), header?: true}
    {header ++ body, next}
  end

  defp handle_csv_query_result({:error, err}, _state, _off, _header?) do
    raise "stream_csv(query) execution error: #{inspect(err)}"
  end

  defp row_to_map_for_json(columns, row) do
    columns
    |> Enum.zip(row)
    |> Enum.map(fn {col, val} -> {col, Value.for_json(val)} end)
    |> Map.new()
  end

  defp normalize_row_for_csv(row) do
    Enum.map(row, &Value.to_csv_string/1)
  end

  @doc """
  Exports a dashboard to a ZIP archive containing CSV files for each query card.

  Each query card's results are exported as a separate CSV file named after the
  card (using title if set, otherwise "card_{id}.csv").

  ## Options

    * `:filter_values` - Map of filter names to their current values
    * Any `Lotus.run_query/2` option such as `:repo`, `:vars`, `:search_path`

  Returns `{:ok, binary}` where binary is the ZIP file content, or
  `{:error, reason}` on failure.

  ## Examples

      {:ok, zip_binary} = Lotus.Export.export_dashboard(dashboard)
      File.write!("dashboard_export.zip", zip_binary)

      {:ok, zip_binary} = Lotus.Export.export_dashboard(dashboard,
        filter_values: %{"date_range" => "2024-01-01,2024-12-31"}
      )

  """
  @spec export_dashboard(Dashboard.t(), keyword()) :: {:ok, binary()} | {:error, term()}
  def export_dashboard(%Dashboard{} = dashboard, opts \\ []) do
    cards = Dashboards.list_dashboard_cards(dashboard.id)
    query_cards = Enum.filter(cards, &(&1.card_type == :query))
    results = Dashboards.run_dashboard(dashboard.id, opts)

    zip_entries =
      query_cards
      |> Enum.map(fn card ->
        filename = card_filename(card)

        case Map.get(results, card.id) do
          {:ok, result} ->
            csv_data = to_csv(result) |> IO.iodata_to_binary()
            {String.to_charlist(filename), csv_data}

          {:error, reason} ->
            error_content = "Error executing query: #{inspect(reason)}"
            {String.to_charlist(filename <> ".error.txt"), error_content}
        end
      end)

    manifest = build_dashboard_manifest(dashboard, query_cards, results)
    manifest_entry = {~c"manifest.json", Lotus.JSON.encode!(manifest)}

    all_entries = [manifest_entry | zip_entries]

    case :zip.create(~c"dashboard.zip", all_entries, [:memory]) do
      {:ok, {_filename, zip_binary}} -> {:ok, zip_binary}
      {:error, reason} -> {:error, reason}
    end
  end

  defp card_filename(card) do
    base_name =
      if card.title && String.trim(card.title) != "" do
        card.title
        |> String.downcase()
        |> String.replace(~r/[^a-z0-9]+/, "_")
        |> String.trim("_")
      else
        "card_#{card.id}"
      end

    "#{base_name}.csv"
  end

  defp build_dashboard_manifest(dashboard, cards, results) do
    %{
      "dashboard" => %{
        "id" => dashboard.id,
        "name" => dashboard.name,
        "description" => dashboard.description,
        "exported_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      },
      "cards" =>
        Enum.map(cards, fn card ->
          result_info =
            case Map.get(results, card.id) do
              {:ok, result} ->
                %{"status" => "success", "row_count" => result.num_rows}

              {:error, reason} ->
                %{"status" => "error", "error" => inspect(reason)}
            end

          %{
            "id" => card.id,
            "title" => card.title,
            "query_id" => card.query_id,
            "filename" => card_filename(card)
          }
          |> Map.merge(result_info)
        end)
    }
  end
end
