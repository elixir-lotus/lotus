# Needs ReqLLM, an optional dependency: see `Lotus.AI.available?/0`.
if Code.ensure_loaded?(ReqLLM) do
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
    alias Lotus.Telemetry

    require Logger

    @default_max_iterations 10

    # --- Tool Construction ---

    @doc """
    Converts an action module to a `ReqLLM.tool()`.

    ## Options

    - `:bind` - Map of parameter values to inject into every call.
      Bound parameters are removed from the tool's parameter schema
      so the LLM doesn't see or fill them.
    - `:context` - Map handed to the action's `run/2` as its second argument.
      Carries the actor on whose behalf the AI is working — typically
      `%{context: ..., scope: ...}` — so actions can pass it on to the
      `Lotus` calls they make. Without it every AI-initiated query and
      introspection call reaches middleware and the visibility resolver with
      no actor, and the AI sees more than the user it is acting for.
    """
    @spec from_action(module(), keyword()) :: map()
    def from_action(action_module, opts \\ []) do
      bound_params = Keyword.get(opts, :bind, %{})
      action_context = Keyword.get(opts, :context, %{})

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

          case action_module.run(merged_params, action_context) do
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

    The loop is one AI request: it emits the `[:lotus, :ai, :request, ...]`
    telemetry events (see `Lotus.Telemetry`), and the final response's usage
    is the sum of every round's, as each round is a call the provider bills.

    ## Options

    - `:api_key` (required) - API key for the LLM provider
    - `:temperature` - LLM temperature (default: `0.2`)
    - `:max_iterations` - Maximum number of tool-call rounds (default: `10`)
    - `:on_max_iterations` - Callback `(response -> term)` called when limit is hit.
      Defaults to logging a warning.
    - `:request` - Map of what the request is for, added to the telemetry
      metadata: `:feature`, `:data_source`, `:context`, `:scope`
    - `:on_tool_call` - Function of one argument, called as each tool runs, so
      that an interface can show the work while the request is still going.
      It is called with `%{phase: :start, id: id, tool: name, args: args}`
      before the tool runs and with the same keys plus `:result` (the text
      handed back to the model) and `:duration` (native time units) after.
      It runs in the process that runs the loop; what it raises is logged
      and does not stop the request.
    - `:on_text` - Function of one argument. When given, each round streams,
      and it is called with each piece of the model's text as it arrives, so
      that an interface can show an answer as it is written. A round that
      ends in tool calls may have sent some text first. Like
      `:on_tool_call`, what it raises is logged.
    - `:on_round` - Function of one argument, called after each round's
      response, before its tool calls run, with
      `%{iteration: n, usage: usage, tool_calls: names}`: the usage so far
      (as `normalize_usage/1` gives it) and every tool called so far. When
      it returns `:halt`, the loop stops there and returns that round's
      response, its tool calls not run, as when it reaches
      `:max_iterations`, so a caller can hold a request to a budget of
      tokens or of rounds. Anything else goes on. What it raises is logged
      and the loop goes on.

    ## Returns

    - `{:ok, response}` - Final LLM response
    - `{:error, reason}` - LLM API error
    """
    @spec run(String.t(), struct(), [map()], keyword()) ::
            {:ok, struct()} | {:error, term()}
    def run(model, context, tools, opts \\ []) do
      loop = %{
        model: model,
        tools: observe_tools(tools, Keyword.get(opts, :on_tool_call)),
        api_key: Keyword.fetch!(opts, :api_key),
        temperature: Keyword.get(opts, :temperature, 0.2),
        max: Keyword.get(opts, :max_iterations, @default_max_iterations),
        on_max: Keyword.get(opts, :on_max_iterations),
        on_text: Keyword.get(opts, :on_text),
        on_round: Keyword.get(opts, :on_round)
      }

      metadata = opts |> Keyword.get(:request, %{}) |> Map.put(:model, model)
      start_time = Telemetry.ai_request_start(metadata)
      acc = %{iterations: 0, usage: nil, tool_calls: []}

      case do_run(loop, context, acc) do
        {:ok, response, acc} ->
          response = %{response | usage: acc.usage}
          answered = Map.put(finished(acc), :response, ReqLLM.Response.text(response))
          Telemetry.ai_request_stop(start_time, Map.merge(metadata, answered))
          {:ok, response}

        {:error, error, acc} ->
          Telemetry.ai_request_exception(
            start_time,
            metadata |> Map.merge(finished(acc)) |> Map.put(:reason, error)
          )

          {:error, error}
      end
    end

    # --- Private: Loop ---

    defp do_run(loop, context, acc) do
      messages = ReqLLM.Context.to_list(context)

      case request(loop, messages) do
        {:ok, response} ->
          acc = %{
            acc
            | iterations: acc.iterations + 1,
              usage: add_usage(acc.usage, ReqLLM.Response.usage(response))
          }

          case {ReqLLM.Response.classify(response), round(loop, acc)} do
            {%{type: :tool_calls}, :halt} ->
              {:ok, response, acc}

            {%{type: :tool_calls, tool_calls: tool_calls}, _go_on}
            when acc.iterations < loop.max ->
              updated_context =
                ReqLLM.Context.execute_and_append_tools(response.context, tool_calls, loop.tools)

              do_run(loop, updated_context, add_tool_calls(acc, tool_calls))

            {%{type: :tool_calls}, _go_on} ->
              if loop.on_max do
                loop.on_max.(response)
              else
                Logger.warning("Tool loop reached max iterations (#{loop.max})")
              end

              {:ok, response, acc}

            _answered ->
              {:ok, response, acc}
          end

        {:error, raw_error} ->
          Logger.error("AI service error: #{inspect(raw_error)}")
          {:error, Error.wrap(raw_error), acc}
      end
    end

    # What `:on_round` says of the round just answered: `:halt`, or go on.
    defp round(%{on_round: nil}, _acc), do: :cont

    defp round(%{on_round: on_round}, acc) do
      on_round.(%{
        iteration: acc.iterations,
        usage: normalize_usage(acc.usage),
        tool_calls: acc.tool_calls
      })
    rescue
      error ->
        Logger.warning("on_round raised: " <> Exception.message(error))
        :cont
    end

    defp request(loop, messages) do
      opts = [tools: loop.tools, api_key: loop.api_key, temperature: loop.temperature]

      case loop.on_text do
        nil ->
          ReqLLM.generate_text(loop.model, messages, opts)

        on_text ->
          with {:ok, stream} <- ReqLLM.stream_text(loop.model, messages, opts) do
            ReqLLM.StreamResponse.process_stream(stream,
              on_result: &notify(on_text, &1, :on_text)
            )
          end
      end
    end

    # Each tool's callback, wrapped to tell `:on_tool_call` when the tool
    # starts and what it returned.
    defp observe_tools(tools, nil), do: tools

    defp observe_tools(tools, on_tool_call) when is_function(on_tool_call, 1),
      do: Enum.map(tools, &observe_tool(&1, on_tool_call))

    defp observe_tool(%{name: name, callback: callback} = tool, on_tool_call) do
      %{
        tool
        | callback: fn args ->
            call = %{id: make_ref(), tool: name, args: args}
            notify(on_tool_call, Map.put(call, :phase, :start))
            started = System.monotonic_time()
            result = call_tool(callback, args)

            notify(
              on_tool_call,
              Map.merge(call, %{
                phase: :stop,
                result: tool_result(result),
                duration: System.monotonic_time() - started
              })
            )

            result
          end
      }
    end

    defp call_tool(fun, args) when is_function(fun, 1), do: fun.(args)
    defp call_tool({module, function}, args), do: apply(module, function, [args])
    defp call_tool({module, function, extra}, args), do: apply(module, function, extra ++ [args])

    defp tool_result({:ok, result}), do: result
    defp tool_result({:error, reason}), do: {:error, reason}

    defp notify(callback, event, name \\ :on_tool_call) do
      callback.(event)
    rescue
      error -> Logger.warning("#{name} raised: " <> Exception.message(error))
    end

    defp add_tool_calls(acc, tool_calls),
      do: %{acc | tool_calls: acc.tool_calls ++ Enum.map(tool_calls, & &1.name)}

    # Every numeric field of the usage is summed across rounds: tokens, and
    # the costs some providers report.
    defp add_usage(total, nil), do: total
    defp add_usage(nil, usage), do: usage

    defp add_usage(total, usage) do
      Map.merge(total, usage, fn
        _key, a, b when is_number(a) and is_number(b) -> a + b
        _key, _a, b -> b
      end)
    end

    defp finished(acc) do
      %{
        usage: normalize_usage(acc.usage),
        tool_calls: acc.tool_calls,
        iterations: acc.iterations
      }
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
end
