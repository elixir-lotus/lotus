defmodule Lotus.AI.Request do
  @moduledoc false

  # What Lotus is about to ask the model, and the `:before_ai_request`
  # middleware that may refuse it or change its system prompt.

  alias Lotus.Middleware

  @type feature :: :generation | :optimization | :explanation

  @doc """
  Runs `:before_ai_request` and returns the system prompt to send: the one a
  plug continued with, if it is a string, else `system_prompt`. A plug that
  halts refuses the request: `{:error, {:halted, reason}}`.
  """
  @spec prepare(feature(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, Middleware.halted()}
  def prepare(feature, system_prompt, opts) do
    payload = %{
      feature: feature,
      model: Keyword.fetch!(opts, :model),
      data_source: Keyword.fetch!(opts, :data_source),
      prompt: Keyword.fetch!(opts, :prompt),
      system_prompt: system_prompt,
      context: Keyword.get(opts, :context),
      scope: Keyword.get(opts, :scope)
    }

    # A system prompt that is not a string is ignored rather than trusted,
    # as a statement `:before_query` returns is.
    case Middleware.run(:before_ai_request, payload) do
      {:cont, %{system_prompt: prompt}} when is_binary(prompt) -> {:ok, prompt}
      {:cont, _payload} -> {:ok, system_prompt}
      {:halt, reason} -> {:error, {:halted, reason}}
    end
  end

  @doc "The telemetry metadata of the request, for `Lotus.AI.Tool.run/4`."
  @spec metadata(feature(), keyword()) :: map()
  def metadata(feature, opts) do
    %{
      feature: feature,
      data_source: Keyword.fetch!(opts, :data_source),
      prompt: Keyword.fetch!(opts, :prompt),
      context: Keyword.get(opts, :context),
      scope: Keyword.get(opts, :scope)
    }
  end
end
