defmodule Lotus.Settings do
  @moduledoc """
  Settings a host changes while Lotus runs, over its config.

  Most of Lotus's config is fixed when the app deploys. A few settings are
  the kind an admin changes in the app: whether statements may write, the
  default page size, how each data source is described to the AI, the AI
  provider and key, delivery and the result cache. A module that implements
  this behaviour answers them at run time:

      config :lotus, settings: MyApp.LotusSettings

      defmodule MyApp.LotusSettings do
        @behaviour Lotus.Settings

        @impl true
        def get(:ai), do: {:ok, [enabled: true, model: "anthropic:claude-sonnet-4-5"]}
        def get(_key), do: :default
      end

  `get/1` is asked on every read of a setting, so it answers from memory
  (`:persistent_term`, ETS), never from a database on each call. What it
  answers goes over the config: a value replaces it, a keyword list or a
  map is merged into it (`ai: [model: …]` keeps the config's `:api_key`).
  `:default` leaves the config as it is, and so does a raise, which is
  logged.

  The keys are `overridable/0`. Check a value before storing it with
  `validate/2`.
  """

  require Logger

  @overridable [:read_only, :default_page_size, :data_source_descriptions, :ai, :delivery, :cache]

  @typedoc "A setting a `Lotus.Settings` module may answer."
  @type key ::
          :read_only | :default_page_size | :data_source_descriptions | :ai | :delivery | :cache

  @doc "The setting `key` over the config, or `:default` to keep the config's."
  @callback get(key :: key()) :: {:ok, term()} | :default

  @doc "The settings a `Lotus.Settings` module may answer."
  @spec overridable() :: [key(), ...]
  def overridable, do: @overridable

  @doc """
  Whether `value` is valid for the setting `key`, as the config would
  take it: `{:ok, value}` with defaults filled in, or `{:error, message}`.
  """
  @spec validate(atom(), term()) :: {:ok, term()} | {:error, String.t()}
  def validate(key, value) when key in @overridable do
    case Lotus.Config.validate_setting(key, value) do
      {:ok, validated} -> {:ok, validated}
      {:error, %NimbleOptions.ValidationError{} = error} -> {:error, Exception.message(error)}
    end
  end

  def validate(key, _value),
    do: {:error, "#{inspect(key)} is not a setting Lotus.Settings answers"}

  @doc false
  # The config's value of `key` with the settings module's over it.
  @spec apply(key(), term()) :: term()
  def apply(key, configured) when key in @overridable do
    case module() do
      nil -> configured
      module -> merge(configured, answer(module, key))
    end
  end

  defp module, do: Lotus.Config.load!()[:settings]

  defp answer(module, key) do
    case module.get(key) do
      {:ok, value} -> {:ok, value}
      _default -> :default
    end
  rescue
    error ->
      Logger.warning(
        "#{inspect(module)}.get(#{inspect(key)}) raised: #{Exception.message(error)}"
      )

      :default
  end

  defp merge(configured, :default), do: configured
  defp merge(configured, {:ok, value}), do: deep_merge(configured, value)

  defp deep_merge(left, right) when is_map(left) and is_map(right),
    do: Map.merge(left, right, fn _key, l, r -> deep_merge(l, r) end)

  defp deep_merge(left, right) when is_list(left) and is_list(right) do
    if Keyword.keyword?(left) and Keyword.keyword?(right) and right != [],
      do: Keyword.merge(left, right, fn _key, l, r -> deep_merge(l, r) end),
      else: right
  end

  defp deep_merge(_left, right), do: right
end
