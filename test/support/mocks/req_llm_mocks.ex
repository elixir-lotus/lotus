defmodule Lotus.ReqLLMMocks do
  @moduledoc """
  Mimic-based mocks for ReqLLM modules.

  Provides mocks for testing AI provider integrations without calling real APIs.
  """

  import Mimic
  import Lotus.AIFixtures

  @doc """
  Setup Mimic copies for ReqLLM modules.

  Call this in test setup blocks before using ReqLLM mocks.
  """
  def setup_mocks do
    Mimic.copy(ReqLLM)
  end

  @doc """
  Mock successful SQL generation from LLM.

  Returns a canned successful response with SQL in markdown format.
  """
  def mock_successful_generation do
    expect(ReqLLM, :generate_text, fn _model, _context, _opts ->
      {:ok, build_response(successful_sql_response())}
    end)
  end

  @doc """
  Mock LLM refusing to generate SQL (non-SQL question).

  Returns response with UNABLE_TO_GENERATE marker.
  """
  def mock_unable_to_generate do
    expect(ReqLLM, :generate_text, fn _model, _context, _opts ->
      {:ok, build_response(unable_to_generate_response())}
    end)
  end

  @doc """
  Mock plain SQL response without markdown wrapper.
  """
  def mock_plain_sql do
    expect(ReqLLM, :generate_text, fn _model, _context, _opts ->
      {:ok, build_response(plain_sql_response())}
    end)

    expect(Lotus.Source.Adapter, :validate_statement, fn _adapter, _statement, _opts -> :ok end)
  end

  @doc """
  Mock complex SQL with JOINs.
  """
  def mock_complex_sql do
    expect(ReqLLM, :generate_text, fn _model, _context, _opts ->
      {:ok, build_response(complex_sql_response())}
    end)
  end

  @doc """
  Mock successful SQL generation with variable configurations.
  """
  def mock_sql_with_variables do
    expect(ReqLLM, :generate_text, fn _model, _context, _opts ->
      {:ok, build_response(sql_with_variables_response())}
    end)
  end

  @doc """
  Mock API error (rate limiting, auth failure, etc.).
  """
  def mock_api_error(error_message \\ "Rate limit exceeded") do
    expect(ReqLLM, :generate_text, fn _model, _context, _opts ->
      {:error, error_message}
    end)
  end

  @doc """
  Mock network timeout.
  """
  def mock_timeout do
    expect(ReqLLM, :generate_text, fn _model, _context, _opts ->
      {:error, :timeout}
    end)
  end

  @doc """
  Mock successful generation with assertion on parameters.

  Useful for verifying that the correct model, options, etc. are passed.
  """
  def mock_with_assertion(assertion_fn) when is_function(assertion_fn, 3) do
    expect(ReqLLM, :generate_text, fn model, context, opts ->
      assertion_fn.(model, context, opts)
      {:ok, build_response(successful_sql_response())}
    end)
  end

  def mock_with_assertion(assertion_fn) when is_function(assertion_fn, 1) do
    expect(ReqLLM, :generate_text, fn model, context, opts ->
      assertion_fn.(%{model: model, context: context, opts: opts})
      {:ok, build_response(successful_sql_response())}
    end)
  end

  @doc """
  Mock successful optimization suggestions from LLM.
  """
  def mock_optimization_suggestions do
    expect(ReqLLM, :generate_text, fn _model, _context, _opts ->
      {:ok, build_response(optimization_suggestions_response())}
    end)
  end

  @doc """
  Mock optimization response with no suggestions (already optimized).
  """
  def mock_no_optimizations do
    expect(ReqLLM, :generate_text, fn _model, _context, _opts ->
      {:ok, build_response(no_optimizations_response())}
    end)
  end

  @doc """
  Mock successful query explanation from LLM.
  """
  def mock_explanation do
    expect(ReqLLM, :generate_text, fn _model, _context, _opts ->
      {:ok, build_response(explanation_response())}
    end)
  end

  @doc """
  Mock successful fragment explanation from LLM.
  """
  def mock_fragment_explanation do
    expect(ReqLLM, :generate_text, fn _model, _context, _opts ->
      {:ok, build_response(fragment_explanation_response())}
    end)
  end

  defp build_response(response_fixture) do
    usage = build_usage(response_fixture.usage)
    message = ReqLLM.Context.assistant(response_fixture.content)

    %ReqLLM.Response{
      id: "mock-#{System.unique_integer([:positive])}",
      message: message,
      context: ReqLLM.Context.new([message]),
      finish_reason: :stop,
      usage: usage,
      model: response_fixture.model
    }
  end

  defp build_usage(usage_map) do
    input =
      usage_map["prompt_tokens"] || usage_map["input_tokens"] ||
        usage_map["promptTokenCount"] || 0

    output =
      usage_map["completion_tokens"] || usage_map["output_tokens"] ||
        usage_map["candidatesTokenCount"] || 0

    %{
      input_tokens: input,
      output_tokens: output,
      total_tokens: input + output
    }
  end
end
