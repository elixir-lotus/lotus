defmodule Lotus.SettingsTest do
  @moduledoc """
  Settings a `Lotus.Settings` module changes at run time, over the config.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Lotus.{Config, Settings}

  defmodule Answers do
    @moduledoc false
    @behaviour Lotus.Settings

    @impl true
    def get(key), do: :persistent_term.get({__MODULE__, key}, :default)
  end

  setup do
    previous = Application.get_all_env(:lotus)
    Application.put_env(:lotus, :settings, Answers)
    Application.put_env(:lotus, :ai, enabled: false, model: "openai:gpt-4o", api_key: "sk-config")
    Config.reload!()

    on_exit(fn ->
      for key <- Settings.overridable(), do: :persistent_term.erase({Answers, key})
      Application.delete_env(:lotus, :settings)
      Application.put_env(:lotus, :ai, previous[:ai] || [])
      Config.reload!()
    end)
  end

  defp answer(key, value), do: :persistent_term.put({Answers, key}, value)

  test "a value replaces the config's" do
    assert Config.read_only?()
    answer(:read_only, {:ok, false})
    refute Config.read_only?()

    answer(:default_page_size, {:ok, 250})
    assert Config.default_page_size() == 250
  end

  test "a keyword list or a map is merged into the config's" do
    answer(:ai, {:ok, [enabled: true, model: "anthropic:claude-sonnet-4-5"]})

    assert Config.ai()[:enabled]
    assert Config.ai()[:model] == "anthropic:claude-sonnet-4-5"
    assert Config.ai()[:api_key] == "sk-config"
    assert Config.ai_enabled?()

    answer(:data_source_descriptions, {:ok, %{"postgres" => "orders and customers"}})
    assert Config.data_source_description("postgres") == "orders and customers"
  end

  test ":default, or a raise, keeps the config's" do
    answer(:read_only, :default)
    assert Config.read_only?()

    defmodule Raising do
      @moduledoc false
      def get(_key), do: raise("store down")
    end

    Application.put_env(:lotus, :settings, Raising)
    Config.reload!()

    assert capture_log(fn -> assert Config.read_only?() end) =~ "store down"
  end

  test "an answer the config would not take keeps the config's" do
    for value <- [nil, "no", 0] do
      answer(:read_only, {:ok, value})
      assert capture_log(fn -> assert Config.read_only?() == true end) =~ "would not take"
    end

    answer(:default_page_size, {:ok, -1})
    capture_log(fn -> assert Config.default_page_size() != -1 end)
  end

  test "validate/2 checks a value as the config would" do
    assert {:ok, 100} = Settings.validate(:default_page_size, 100)
    assert {:error, _message} = Settings.validate(:default_page_size, -1)
    assert {:error, _message} = Settings.validate(:read_only, "yes")
    assert {:error, message} = Settings.validate(:storage_repo, Foo)
    assert message =~ "not a setting"
  end
end
