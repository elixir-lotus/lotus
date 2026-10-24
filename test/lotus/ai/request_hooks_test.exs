defmodule Lotus.AI.RequestHooksTest do
  @moduledoc """
  Every AI request fires `:before_ai_request`, which can refuse it or change
  its system prompt, and each request that reaches the model is bracketed by
  `[:lotus, :ai, :request, ...]` telemetry with the usage of every round of
  the tool loop.
  """
  use Lotus.AICase, async: false

  alias Lotus.AI.{QueryExplainer, QueryGenerator, QueryOptimizer}
  alias Lotus.Middleware
  alias Lotus.Query.Statement

  @context %{user_id: 42}
  @scope %{tenant_id: "acme"}

  defmodule CapturePlug do
    @moduledoc false
    def init(opts), do: opts

    def call(payload, _opts) do
      send(self(), {:before_ai_request, payload})
      {:cont, payload}
    end
  end

  defmodule RefusePlug do
    @moduledoc false
    def init(opts), do: opts
    def call(_payload, _opts), do: {:halt, :ai_quota_reached}
  end

  defmodule GroundPlug do
    @moduledoc false
    def init(opts), do: opts

    def call(%{system_prompt: prompt} = payload, _opts),
      do: {:cont, %{payload | system_prompt: prompt <> "\n\nGLOSSARY: MRR is monthly revenue."}}
  end

  defmodule NotAStringPlug do
    @moduledoc false
    def init(opts), do: opts
    def call(payload, _opts), do: {:cont, %{payload | system_prompt: :replaced}}
  end

  setup do
    stub(Lotus.Source, :source_type, fn _ -> :postgres end)
    stub(Lotus.Schema, :list_tables, fn _, _opts -> {:ok, table_list()} end)

    ref = make_ref()
    pid = self()

    :telemetry.attach_many(
      "#{inspect(ref)}",
      [
        [:lotus, :ai, :request, :start],
        [:lotus, :ai, :request, :stop],
        [:lotus, :ai, :request, :exception]
      ],
      fn event, measurements, metadata, _ -> send(pid, {event, measurements, metadata}) end,
      nil
    )

    on_exit(fn ->
      :telemetry.detach("#{inspect(ref)}")
      :persistent_term.erase({Lotus.Middleware, :compiled})
    end)

    :ok
  end

  defp generate(opts \\ []) do
    QueryGenerator.generate_statement(
      "openai:gpt-4o",
      [
        prompt: "Show active users",
        data_source: "postgres",
        api_key: "sk-test",
        context: @context,
        scope: @scope
      ] ++ opts
    )
  end

  defp system_prompt(messages) do
    Enum.find_value(messages, fn
      %{role: :system, content: [%{text: text} | _]} -> text
      _ -> nil
    end)
  end

  defp response(message, usage, finish_reason) do
    %ReqLLM.Response{
      id: "mock-#{System.unique_integer([:positive])}",
      message: message,
      context: ReqLLM.Context.new([message]),
      finish_reason: finish_reason,
      usage: usage,
      model: "gpt-4o"
    }
  end

  describe ":before_ai_request" do
    test "carries the request and the actor" do
      Middleware.compile(%{before_ai_request: [{CapturePlug, []}]})
      mock_successful_generation()

      assert {:ok, _} = generate()

      assert_received {:before_ai_request, payload}

      assert %{
               feature: :generation,
               model: "openai:gpt-4o",
               data_source: "postgres",
               prompt: "Show active users",
               context: @context,
               scope: @scope
             } = payload

      assert is_binary(payload.system_prompt)
    end

    test "a halt refuses the request before it reaches the model" do
      Middleware.compile(%{before_ai_request: [{RefusePlug, []}]})
      reject(&ReqLLM.generate_text/3)

      assert {:error, {:halted, :ai_quota_reached}} = generate()
      refute_received {[:lotus, :ai, :request, :start], _, _}
    end

    test "a system prompt a plug continues with is sent" do
      Middleware.compile(%{before_ai_request: [{GroundPlug, []}]})

      mock_with_assertion(fn _model, messages, _opts ->
        assert system_prompt(messages) =~ "GLOSSARY: MRR is monthly revenue."
      end)

      assert {:ok, _} = generate()
    end

    test "a system prompt that is not a string is ignored" do
      Middleware.compile(%{before_ai_request: [{NotAStringPlug, []}]})

      mock_with_assertion(fn _model, messages, _opts ->
        assert is_binary(system_prompt(messages))
      end)

      assert {:ok, _} = generate()
    end

    test "explanations and optimizations fire it with their feature" do
      Middleware.compile(%{before_ai_request: [{CapturePlug, []}]})
      mock_explanation()
      mock_optimization_suggestions()

      assert {:ok, _} =
               QueryExplainer.explain_query("openai:gpt-4o",
                 statement: "SELECT * FROM users",
                 data_source: "postgres",
                 api_key: "sk-test",
                 context: @context
               )

      assert_received {:before_ai_request,
                       %{feature: :explanation, context: @context, prompt: prompt}}

      assert prompt =~ "SELECT * FROM users"

      assert {:ok, _} =
               QueryOptimizer.suggest_optimizations("openai:gpt-4o",
                 statement: Statement.new("SELECT * FROM users"),
                 data_source: "postgres",
                 api_key: "sk-test"
               )

      assert_received {:before_ai_request, %{feature: :optimization, context: nil}}
    end
  end

  describe "telemetry" do
    test "a request is bracketed, with its usage as measurements" do
      mock_successful_generation()

      assert {:ok, %{usage: usage}} = generate()

      assert_received {[:lotus, :ai, :request, :start], %{system_time: _}, start}

      assert start == %{
               feature: :generation,
               model: "openai:gpt-4o",
               data_source: "postgres",
               context: @context,
               scope: @scope
             }

      assert_received {[:lotus, :ai, :request, :stop], measurements, stop}
      assert %{prompt_tokens: 150, completion_tokens: 50, total_tokens: 200} = measurements
      assert is_integer(measurements.duration)
      assert %{usage: ^usage, tool_calls: [], iterations: 1, feature: :generation} = stop
    end

    test "the usage of every round of the tool loop is summed, and the tools listed" do
      tool_call = ReqLLM.ToolCall.new("call_1", "list_tables", "{}")
      asking = ReqLLM.Context.assistant("", tool_calls: [tool_call])
      answer = ReqLLM.Context.assistant("```sql\nSELECT * FROM users\n```")

      expect(ReqLLM, :generate_text, fn _model, _messages, _opts ->
        {:ok,
         response(asking, %{input_tokens: 100, output_tokens: 10, total_tokens: 110}, :tool_calls)}
      end)

      expect(ReqLLM, :generate_text, fn _model, _messages, _opts ->
        {:ok, response(answer, %{input_tokens: 130, output_tokens: 20, total_tokens: 150}, :stop)}
      end)

      assert {:ok, %{usage: usage}} = generate()
      assert usage == %{prompt_tokens: 230, completion_tokens: 30, total_tokens: 260}

      assert_received {[:lotus, :ai, :request, :stop], %{total_tokens: 260},
                       %{tool_calls: ["list_tables"], iterations: 2}}
    end

    test "a failed call to the provider emits :exception with the reason" do
      mock_api_error("Rate limit exceeded")

      assert {:error, reason} = generate()

      assert_received {[:lotus, :ai, :request, :exception], %{total_tokens: 0},
                       %{reason: ^reason, feature: :generation, iterations: 0}}

      refute_received {[:lotus, :ai, :request, :stop], _, _}
    end
  end
end
