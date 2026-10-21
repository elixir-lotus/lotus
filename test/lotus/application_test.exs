defmodule Lotus.ApplicationTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  setup do
    mcp = Application.fetch_env(:lotus, :mcp)

    on_exit(fn ->
      case mcp do
        {:ok, value} -> Application.put_env(:lotus, :mcp, value)
        :error -> Application.delete_env(:lotus, :mcp)
      end
    end)
  end

  describe "warn_without_sake/1" do
    test "warns when MCP is configured but Sake is missing" do
      Application.put_env(:lotus, :mcp, authorize: {MyApp, :mcp?})

      log = capture_log(fn -> assert :ok = Lotus.Application.warn_without_sake(false) end)

      assert log =~ "config :lotus, :mcp is set, but Sake is not a dependency"
      assert log =~ ~s(Add {:sake, "~> 0.4"})
    end

    test "says nothing when MCP is not configured, or Sake is there" do
      Application.delete_env(:lotus, :mcp)
      assert capture_log(fn -> Lotus.Application.warn_without_sake(false) end) == ""

      Application.put_env(:lotus, :mcp, authorize: {MyApp, :mcp?})
      assert capture_log(fn -> Lotus.Application.warn_without_sake(true) end) == ""
    end
  end
end
