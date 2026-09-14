defmodule Lotus.Visibility.Mask do
  @moduledoc """
  Applies a column mask strategy to one value.

  `Lotus.Runner` masks the values of a result column with this module when the
  column policy is `action: :mask`. A middleware plug that masks values itself,
  at `:after_query` for example, can call `apply/2` to get the same output.

  ## Strategies

  - `:null` - replaces the value with `nil`
  - `:sha256` - replaces the value with its SHA-256 digest in lowercase hex
  - `{:fixed, value}` - replaces the value with `value`
  - `{:partial, opts}` - keeps the ends of the value and masks the middle:
    - `keep_first: n` - keeps the first n characters (default: 0)
    - `keep_last: n` - keeps the last n characters (default: 4)
    - `replacement: str` - the string for each masked character (default: `"*"`)
    - `keep_domain: true` - keeps `@` and the domain after the last `@`, and
      applies the options above to the local part only. A value with no `@` is
      masked completely.

  ## Values

  `:sha256` and `{:partial, opts}` operate on a string. A binary is used as its
  bytes, `nil` becomes the empty string, and any other value is rendered with
  `Lotus.Value.to_display_string/1`.

  Partial masking never lets a value through unchanged. When `keep_first` plus
  `keep_last` covers the whole value, or the whole local part with
  `keep_domain: true`, nothing is kept. A binary that is not valid UTF-8 has no
  readable prefix or suffix, so it becomes one replacement per byte.

  A strategy that this module does not know replaces the value with `nil`, so
  an invalid policy never shows the value.
  """

  import Kernel, except: [apply: 2]

  alias Lotus.Value
  alias Lotus.Visibility.Policy

  @doc """
  Masks `value` with `strategy`.

  ## Examples

      iex> Lotus.Visibility.Mask.apply("secret", {:fixed, "REDACTED"})
      "REDACTED"

      iex> Lotus.Visibility.Mask.apply("555-123-4567", {:partial, keep_last: 4})
      "********4567"

      iex> Lotus.Visibility.Mask.apply("alice@example.com", {:partial, keep_domain: true, keep_first: 1, keep_last: 0})
      "a****@example.com"
  """
  @spec apply(term(), Policy.mask_strategy()) :: term()
  def apply(value, strategy)

  def apply(_value, :null), do: nil
  def apply(_value, {:fixed, fixed_value}), do: fixed_value
  def apply(value, :sha256), do: value |> to_mask_string() |> sha256_hex()
  def apply(value, {:partial, opts}), do: value |> to_mask_string() |> partial(opts)
  def apply(_value, _unknown_strategy), do: nil

  defp to_mask_string(nil), do: ""

  # Binaries stay as they are so a mask sees the stored bytes rather than a
  # rendering of them. Everything else — maps from `jsonb`, structs, tuples —
  # goes through the same display normalization the UI and exports use, since
  # `to_string/1` raises for most of them.
  defp to_mask_string(value) when is_binary(value), do: value
  defp to_mask_string(value), do: Value.to_display_string(value)

  defp sha256_hex(s) do
    :crypto.hash(:sha256, s) |> Base.encode16(case: :lower)
  end

  defp partial(s, opts) do
    cond do
      not String.valid?(s) -> mask_every_byte(s, opts)
      Keyword.get(opts, :keep_domain) == true -> partial_keeping_domain(s, opts)
      true -> partial_text(s, opts)
    end
  end

  defp mask_every_byte(s, opts) do
    String.duplicate(replacement(opts), byte_size(s))
  end

  defp partial_keeping_domain(s, opts) do
    case :binary.matches(s, "@") do
      [] ->
        String.duplicate(replacement(opts), String.length(s))

      matches ->
        {at, 1} = List.last(matches)
        local_part = binary_part(s, 0, at)
        domain = binary_part(s, at + 1, byte_size(s) - at - 1)
        partial_text(local_part, opts) <> "@" <> domain
    end
  end

  defp partial_text(s, opts) do
    keep_last = Keyword.get(opts, :keep_last, 4)
    keep_first = Keyword.get(opts, :keep_first, 0)
    repl = replacement(opts)

    len = String.length(s)
    left = min(keep_first, len)
    right = min(keep_last, max(len - left, 0))
    mid = max(len - left - right, 0)

    if mid == 0 do
      String.duplicate(repl, len)
    else
      left_part = String.slice(s, 0, left)
      right_part = if right > 0, do: String.slice(s, len - right, right), else: ""
      left_part <> String.duplicate(repl, mid) <> right_part
    end
  end

  defp replacement(opts), do: Keyword.get(opts, :replacement, "*")
end
