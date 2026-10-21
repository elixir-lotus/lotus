# Postgres-specific type normalizers
# Only compiled when Postgrex types are available

if Code.ensure_loaded?(Postgrex.Range) do
  defimpl Lotus.Normalizer, for: Postgrex.Range do
    def normalize(%Postgrex.Range{} = range) do
      lower_bound = if range.lower_inclusive, do: "[", else: "("
      upper_bound = if range.upper_inclusive, do: "]", else: ")"

      lower = format_range_value(range.lower)
      upper = format_range_value(range.upper)

      "#{lower_bound}#{lower},#{upper}#{upper_bound}"
    end

    defp format_range_value(nil), do: ""
    defp format_range_value(:unbound), do: ""

    defp format_range_value(value) do
      Lotus.Normalizer.normalize(value)
    end
  end
end

if Code.ensure_loaded?(Postgrex.INET) do
  defimpl Lotus.Normalizer, for: Postgrex.INET do
    def normalize(%Postgrex.INET{address: address, netmask: netmask}) do
      addr_str = format_address(address)

      case netmask do
        nil -> addr_str
        # IPv4 full mask
        32 -> addr_str
        # IPv6 full mask
        128 -> addr_str
        mask -> "#{addr_str}/#{mask}"
      end
    end

    defp format_address(address) when is_tuple(address) do
      case tuple_size(address) do
        # IPv4
        4 ->
          address |> Tuple.to_list() |> Enum.join(".")

        # IPv6
        8 ->
          address
          |> Tuple.to_list()
          |> Enum.map_join(":", &Integer.to_string(&1, 16))
      end
    end
  end
end

if Code.ensure_loaded?(Postgrex.Interval) do
  defimpl Lotus.Normalizer, for: Postgrex.Interval do
    # Postgrex.Interval has: months, days, secs, microsecs
    def normalize(%Postgrex.Interval{} = interval) do
      parts = build_date_parts(interval)
      time_parts = build_time_parts(interval)

      format_duration(parts, time_parts)
    end

    defp build_date_parts(interval) do
      []
      |> add_years_months(interval.months || 0)
      |> add_days(interval.days)
    end

    defp add_years_months(parts, 0), do: parts

    defp add_years_months(parts, total_months) do
      years = div(total_months, 12)
      months = rem(total_months, 12)

      parts
      |> add_if_nonzero(years, "Y")
      |> add_if_nonzero(months, "M")
    end

    defp add_days(parts, nil), do: parts
    defp add_days(parts, 0), do: parts
    defp add_days(parts, days), do: parts ++ ["#{days}D"]

    defp add_if_nonzero(parts, 0, _suffix), do: parts
    defp add_if_nonzero(parts, value, suffix), do: parts ++ ["#{value}#{suffix}"]

    defp build_time_parts(interval) do
      total_microsecs = (interval.secs || 0) * 1_000_000 + (interval.microsecs || 0)
      format_time_parts(total_microsecs)
    end

    defp format_duration([], []), do: "P0D"
    defp format_duration(parts, []), do: "P" <> Enum.join(parts)

    defp format_duration(parts, time_parts) do
      "P" <> Enum.join(parts ++ ["T"] ++ time_parts)
    end

    defp format_time_parts(0), do: []

    defp format_time_parts(microsecs) do
      total_secs = div(microsecs, 1_000_000)
      remaining_microsecs = rem(microsecs, 1_000_000)

      hours = div(total_secs, 3600)
      minutes = div(rem(total_secs, 3600), 60)
      seconds = rem(total_secs, 60)

      parts = []

      parts =
        if seconds != 0 or remaining_microsecs != 0 do
          if remaining_microsecs != 0 do
            # Format with fractional seconds
            frac_seconds = seconds + remaining_microsecs / 1_000_000
            parts ++ ["#{Float.to_string(frac_seconds)}S"]
          else
            parts ++ ["#{seconds}S"]
          end
        else
          parts
        end

      parts = if minutes != 0, do: ["#{minutes}M"] ++ parts, else: parts
      parts = if hours != 0, do: ["#{hours}H"] ++ parts, else: parts

      parts
    end
  end
end

if Code.ensure_loaded?(Postgrex.Point) do
  defimpl Lotus.Normalizer, for: Postgrex.Point do
    def normalize(%Postgrex.Point{x: x, y: y}) do
      "(#{x},#{y})"
    end
  end
end

if Code.ensure_loaded?(Postgrex.LineSegment) do
  defimpl Lotus.Normalizer, for: Postgrex.LineSegment do
    def normalize(%Postgrex.LineSegment{point1: p1, point2: p2}) do
      "[#{Lotus.Normalizer.normalize(p1)},#{Lotus.Normalizer.normalize(p2)}]"
    end
  end
end

if Code.ensure_loaded?(Postgrex.Box) do
  defimpl Lotus.Normalizer, for: Postgrex.Box do
    def normalize(%Postgrex.Box{upper_right: ur, bottom_left: bl}) do
      "(#{Lotus.Normalizer.normalize(ur)},#{Lotus.Normalizer.normalize(bl)})"
    end
  end
end

if Code.ensure_loaded?(Postgrex.Path) do
  defimpl Lotus.Normalizer, for: Postgrex.Path do
    def normalize(%Postgrex.Path{points: points, open: open}) do
      points_str = Enum.map_join(points, ",", &Lotus.Normalizer.normalize/1)

      if open do
        "[#{points_str}]"
      else
        "(#{points_str})"
      end
    end
  end
end

if Code.ensure_loaded?(Postgrex.Polygon) do
  defimpl Lotus.Normalizer, for: Postgrex.Polygon do
    def normalize(%Postgrex.Polygon{vertices: vertices}) do
      points_str = Enum.map_join(vertices, ",", &Lotus.Normalizer.normalize/1)

      "(#{points_str})"
    end
  end
end

if Code.ensure_loaded?(Postgrex.Circle) do
  defimpl Lotus.Normalizer, for: Postgrex.Circle do
    def normalize(%Postgrex.Circle{center: center, radius: radius}) do
      "<#{Lotus.Normalizer.normalize(center)},#{radius}>"
    end
  end
end

if Code.ensure_loaded?(Postgrex.Line) do
  defimpl Lotus.Normalizer, for: Postgrex.Line do
    def normalize(%Postgrex.Line{a: a, b: b, c: c}) do
      "{#{a},#{b},#{c}}"
    end
  end
end

if Code.ensure_loaded?(Postgrex.MACADDR) do
  defimpl Lotus.Normalizer, for: Postgrex.MACADDR do
    def normalize(%Postgrex.MACADDR{address: address}) do
      address
      |> Tuple.to_list()
      |> Enum.map_join(":", &(&1 |> Integer.to_string(16) |> String.pad_leading(2, "0")))
      |> String.downcase()
    end
  end
end

if Code.ensure_loaded?(Postgrex.Lexeme) do
  # A tsvector arrives as a list of lexemes, so each renders as PostgreSQL
  # writes one lexeme: quoted, then its positions and any weight but D.
  defimpl Lotus.Normalizer, for: Postgrex.Lexeme do
    def normalize(%Postgrex.Lexeme{word: word, positions: positions}) do
      quoted = "'" <> String.replace(word, ["'", "\\"], &(&1 <> &1)) <> "'"

      case positions do
        empty when empty in [nil, []] -> quoted
        positions -> quoted <> ":" <> Enum.map_join(positions, ",", &format_position/1)
      end
    end

    defp format_position({position, nil}), do: Integer.to_string(position)
    defp format_position({position, weight}), do: "#{position}#{weight}"
  end
end

if Code.ensure_loaded?(Postgrex.Multirange) do
  defimpl Lotus.Normalizer, for: Postgrex.Multirange do
    def normalize(%Postgrex.Multirange{ranges: ranges}) do
      "{" <> Enum.map_join(ranges || [], ",", &Lotus.Normalizer.normalize/1) <> "}"
    end
  end
end
