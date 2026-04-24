defmodule Lotus.AI.Tool do
  @moduledoc """
  Tool utilities for LLM interactions.

  Provides two concerns:

  - **`from_action/2`** — Converts a `Lotus.AI.Action` module into a
    `ReqLLM.tool()`, with support for binding context parameters.
  - **`run/4`** — Runs the recursive tool-calling loop: sends messages
    to the LLM, executes tool calls, appends results, and repeats until
    the LLM produces a final text response or the iteration limit is reached.

  ## Examples

      # Build a tool from an action, hiding data_source from the LLM
      tool = Tool.from_action(DescribeTable, bind: %{data_source: "postgres"})

      # Run the tool-calling loop
      {:ok, response} = Tool.run("openai:gpt-4o", context, tools, api_key: "sk-...")
  """

  alias Lotus.AI.Error

  require Logger

  @default_max_iterations 10

  # --- Tool Construction ---

  @doc """
  Converts an action module to a `ReqLLM.tool()`.

  ## Options

  - `:bind` - Map of parameter values to inject into every call.
    Bound parameters are removed from the tool's parameter schema
    so the LLM doesn't see or fill them.
  """
  @spec from_action(module(), keyword()) :: map()
  def from_action(action_module, opts \\ []) do
    bound_params = Keyword.get(opts, :bind, %{})

    parameter_schema =
      action_module.schema()
      |> nimble_to_json_schema()
      |> strip_bound_params(bound_params)

    ReqLLM.tool(
      name: action_module.name(),
      description: action_module.description(),
      parameter_schema: parameter_schema,
      callback: fn llm_args ->
        merged_params = merge_params(llm_args, bound_params)

        case action_module.run(merged_params, %{}) do
          {:ok, result} ->
            {:ok, Lotus.JSON.encode!(result)}

          {:error, reason} ->
            {:ok, Lotus.JSON.encode!(%{error: inspect(reason)})}
        end
      end
    )
  end

  # --- Tool-Calling Loop ---

  @doc """
  Runs the tool-calling loop.

  Sends messages to the LLM with the given tools. If the LLM responds
  with tool calls, executes them, appends results to the context, and
  repeats. Stops when the LLM produces a text response or the iteration
  limit is reached.

  ## Options

  - `:api_key` (required) - API key for the LLM provider
  - `:temperature` - LLM temperature (default: `0.2`)
  - `:max_iterations` - Maximum number of tool-call rounds (default: `10`)
  - `:on_max_iterations` - Callback `(response -> term)` called when limit is hit.
    Defaults to logging a warning.

  ## Returns

  - `{:ok, response}` - Final LLM response
  - `{:error, reason}` - LLM API error
  """
  @spec run(String.t(), struct(), [map()], keyword()) ::
          {:ok, struct()} | {:error, term()}
  def run(model, context, tools, opts \\ []) do
    api_key = Keyword.fetch!(opts, :api_key)
    temperature = Keyword.get(opts, :temperature, 0.2)
    max_iterations = Keyword.get(opts, :max_iterations, @default_max_iterations)
    on_max = Keyword.get(opts, :on_max_iterations)

    do_run(model, context, tools, api_key, temperature, max_iterations, on_max, 1)
  end

  # --- Private: Loop ---

  defp do_run(model, context, tools, api_key, temperature, max, on_max, iteration) do
    messages = ReqLLM.Context.to_list(context)

    case ReqLLM.generate_text(model, messages,
           tools: tools,
           api_key: api_key,
           temperature: temperature
         ) do
      {:ok, response} ->
        case ReqLLM.Response.classify(response) do
          %{type: :tool_calls, tool_calls: tool_calls} when iteration < max ->
            updated_context =
              ReqLLM.Context.execute_and_append_tools(response.context, tool_calls, tools)

            do_run(
              model,
              updated_context,
              tools,
              api_key,
              temperature,
              max,
              on_max,
              iteration + 1
            )

          %{type: :tool_calls} ->
            if on_max do
              on_max.(response)
            else
              Logger.warning("Tool loop reached max iterations (#{max})")
            end

            {:ok, response}

          _ ->
            {:ok, response}
        end

      {:error, raw_error} ->
        Logger.error("AI service error: #{inspect(raw_error)}")
        {:error, Error.wrap(raw_error)}
    end
  end

  # --- Usage Normalization ---

  @doc """
  Normalizes ReqLLM usage stats into a consistent format.

  ReqLLM returns `input_tokens`/`output_tokens`, but Lotus uses
  `prompt_tokens`/`completion_tokens` for consistency with OpenAI conventions.
  """
  @spec normalize_usage(map() | nil) :: map()
  def normalize_usage(nil), do: %{prompt_tokens: 0, completion_tokens: 0, total_tokens: 0}

  def normalize_usage(usage) do
    %{
      prompt_tokens: usage[:input_tokens] || 0,
      completion_tokens: usage[:output_tokens] || 0,
      total_tokens: usage[:total_tokens] || 0
    }
  end

  # --- Private: Schema Conversion ---

  defp nimble_to_json_schema([]) do
    %{"type" => "object", "properties" => %{}, "required" => []}
  end

  defp nimble_to_json_schema(schema) do
    properties =
      Map.new(schema, fn {key, opts} ->
        type_info = nimble_type_to_json(opts[:type])
        description = opts[:doc] || "No description provided."
        {to_string(key), Map.put(type_info, "description", description)}
      end)

    required =
      schema
      |> Enum.filter(fn {_key, opts} -> opts[:required] end)
      |> Enum.map(fn {key, _opts} -> to_string(key) end)

    %{"type" => "object", "properties" => properties, "required" => required}
  end

  defp nimble_type_to_json(:string), do: %{"type" => "string"}
  defp nimble_type_to_json(:integer), do: %{"type" => "integer"}
  defp nimble_type_to_json(:float), do: %{"type" => "number"}
  defp nimble_type_to_json(:boolean), do: %{"type" => "boolean"}

  defp nimble_type_to_json({:list, subtype}),
    do: %{"type" => "array", "items" => nimble_type_to_json(subtype)}

  defp nimble_type_to_json(_), do: %{"type" => "string"}

  # --- Private: Parameter Handling ---

  defp strip_bound_params(schema, bound_params) when map_size(bound_params) == 0, do: schema

  defp strip_bound_params(schema, bound_params) do
    bound_keys = bound_params |> Map.keys() |> MapSet.new(&to_string/1)

    properties =
      schema
      |> Map.get("properties", %{})
      |> Map.reject(fn {key, _} -> MapSet.member?(bound_keys, key) end)

    required =
      schema
      |> Map.get("required", [])
      |> Enum.reject(&MapSet.member?(bound_keys, &1))

    schema
    |> Map.put("properties", properties)
    |> Map.put("required", required)
  end

  defp merge_params(llm_args, bound_params) do
    atomized_llm =
      Map.new(llm_args, fn {k, v} ->
        key =
          if is_binary(k) do
            try do
              String.to_existing_atom(k)
            rescue
              ArgumentError -> k
            end
          else
            k
          end

        {key, v}
      end)

    Map.merge(atomized_llm, bound_params)
  end
end
