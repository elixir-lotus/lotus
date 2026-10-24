defmodule Lotus.AIDependencyTest do
  # A node without ReqLLM, AI's optional dependency: the application's
  # setting stands for it, so these tests run alone.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Lotus.AI
  alias Lotus.Query.Statement

  setup do
    :persistent_term.erase({AI, :warned_missing})
    Application.put_env(:lotus, :ai, enabled: true, api_key: "sk-test")
    Lotus.Config.reload!()

    on_exit(fn ->
      Application.delete_env(:lotus, :ai)
      Application.delete_env(:lotus, :__ai_dependency__)
      :persistent_term.erase({AI, :warned_missing})
      Lotus.Config.reload!()
    end)
  end

  defp without_dependency, do: Application.put_env(:lotus, :__ai_dependency__, NoSuch.ReqLLM)

  test "with ReqLLM, AI is available, and enabled when configured" do
    assert AI.available?()
    assert AI.enabled?()
  end

  test "without it, AI is not available, nor enabled though configured, and says so once" do
    without_dependency()

    refute AI.available?()

    log = capture_log(fn -> refute AI.enabled?() end)
    assert log =~ "its dependency is missing"
    assert log =~ ~s({:req_llm, "~> 1.29"})

    # Once a node: the UIs ask on every render.
    assert capture_log(fn -> refute AI.enabled?() end) == ""
  end

  test "without it, the AI functions refuse, and call nothing of ReqLLM's" do
    without_dependency()

    capture_log(fn ->
      assert {:error, :dependency_missing} =
               AI.generate_query(prompt: "users", data_source: "postgres")

      assert {:error, :dependency_missing} =
               AI.generate_query_with_context(prompt: "users", data_source: "postgres")

      assert {:error, :dependency_missing} =
               AI.suggest_optimizations(
                 statement: Statement.new("SELECT 1"),
                 data_source: "postgres"
               )

      assert {:error, :dependency_missing} =
               AI.explain_query(statement: "SELECT 1", data_source: "postgres")

      assert {:error, :dependency_missing} = AI.model()
    end)
  end

  test "AI switched off says nothing of the dependency" do
    without_dependency()
    Application.put_env(:lotus, :ai, enabled: false)
    Lotus.Config.reload!()

    assert capture_log(fn -> refute AI.enabled?() end) == ""
    assert {:error, :not_configured} = AI.model()
  end
end
