defmodule Lotus.AI.Error do
  @moduledoc """
  Domain errors for AI service failures.

  Wraps raw provider errors (from ReqLLM) into Lotus-owned exceptions
  with user-friendly messages. The raw error is logged server-side;
  only the wrapped error is returned to callers.
  """

  defmodule RateLimitError do
    @moduledoc "The AI provider rejected the request due to rate limits or quota."
    defexception message:
                   "The AI service is temporarily unavailable due to rate limits. Please try again later."
  end

  defmodule AuthenticationError do
    @moduledoc "The AI provider rejected the request due to invalid or missing credentials."
    defexception message:
                   "AI service authentication failed. Please check your API key configuration."
  end

  defmodule ServerError do
    @moduledoc "The AI provider returned a server-side error (5xx)."
    defexception message: "The AI service is temporarily unavailable. Please try again later."
  end

  defmodule TimeoutError do
    @moduledoc "The AI request timed out."
    defexception message: "The AI request timed out. Please try again."
  end

  defmodule ServiceError do
    @moduledoc "Catch-all for unexpected AI service errors."
    defexception message: "An unexpected error occurred with the AI service. Please try again."
  end

  @doc """
  Wraps a raw LLM provider error into a Lotus AI domain error.

  Pattern-matches on known `ReqLLM.Error` types and HTTP status codes
  to return the appropriate exception. Unknown errors become `ServiceError`.

  ## Examples

      iex> raw = %ReqLLM.Error.API.Request{status: 429, reason: "rate limited"}
      iex> %Lotus.AI.Error.RateLimitError{} = Lotus.AI.Error.wrap(raw)

      iex> Lotus.AI.Error.wrap(:something_unexpected)
      %Lotus.AI.Error.ServiceError{}

  """
  @spec wrap(term()) :: Exception.t()
  # ReqLLM's errors, when it is loaded (an optional dependency).
  if Code.ensure_loaded?(ReqLLM) do
    def wrap(%ReqLLM.Error.API.Request{status: 429}), do: %RateLimitError{}

    def wrap(%ReqLLM.Error.API.Request{status: status}) when status in [401, 403],
      do: %AuthenticationError{}

    def wrap(%ReqLLM.Error.API.Request{status: status})
        when is_integer(status) and status >= 500,
        do: %ServerError{}

    def wrap(%ReqLLM.Error.API.Request{reason: reason}) when is_binary(reason) do
      if reason =~ ~r/timed?\s*out/i, do: %TimeoutError{}, else: %ServiceError{}
    end
  end

  def wrap(_error), do: %ServiceError{}
end
