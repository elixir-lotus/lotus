defmodule Lotus.UnsupportedOperatorError do
  @moduledoc """
  Raised when a caller attempts to apply a `Lotus.Query.Filter` operator
  that the adapter has not declared as supported via
  `supported_filter_operators/1`.

  Rather than silently degrading (substring-match when `:like` is asked
  for, or ignoring `:is_null`), Lotus fails loudly so host applications
  catch the mismatch early and gate their UI on
  `Lotus.Source.supported_filter_operators/1`.
  """

  defexception [:message, :operator, :source]

  @impl true
  def exception(opts) do
    op = Keyword.fetch!(opts, :operator)
    source = Keyword.fetch!(opts, :source)
    supported = Keyword.get(opts, :supported, [])

    msg =
      "Filter operator #{inspect(op)} is not supported by source #{inspect(source)}. " <>
        "Supported operators: #{inspect(supported)}."

    %__MODULE__{message: msg, operator: op, source: source}
  end
end
