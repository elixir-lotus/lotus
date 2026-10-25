defmodule Lotus.Source.Connections do
  @moduledoc """
  Sources connected from settings a person types: the kinds of source the
  installed adapters can connect, checking a form's values against a kind's
  fields, building the source, and testing it before it is saved.

      iex> Lotus.Source.Connections.kinds() |> Enum.map(& &1.kind)
      ["postgres", "mysql", "sqlite", "clickhouse", "elasticsearch"]

      {:ok, adapter} =
        Lotus.Source.Connections.build("warehouse", "postgres", %{
          "hostname" => "db.internal",
          "database" => "analytics",
          "username" => "lotus",
          "password" => "…"
        })

  A kind comes from an adapter that declares
  `Lotus.Source.Adapter.Connection`: the built-in Postgres, MySQL and SQLite
  adapters when their database library is installed, and any adapter in
  `config :lotus, source_adapters:` that declares it, such as
  `lotus_clickhouse`'s or `lotus_elasticsearch`'s.

  Lotus does not keep the settings. Whoever does (the host, or Lotus Pro)
  returns the sources `build/3` makes from its `Lotus.Source.Resolver` and
  calls `Lotus.Source.reconcile/0` when they change, which starts and stops
  their processes on every node.
  """

  alias Lotus.Config
  alias Lotus.Source.Adapter
  alias Lotus.Source.Adapter.Connection
  alias Lotus.Source.Adapters.Ecto, as: EctoAdapter

  @typedoc "A kind of source, with the adapter module that connects it."
  @type kind :: %{
          required(:kind) => String.t(),
          required(:label) => String.t(),
          required(:fields) => [Connection.field()],
          required(:module) => module()
        }

  @typedoc """
  A form's values, by field key as a string (`"hostname"`) or an atom
  (`:hostname`).
  """
  @type settings :: %{optional(String.t() | atom()) => term()}

  @typedoc "What is wrong with a form, by field key."
  @type errors :: %{atom() => String.t()}

  @doc """
  The kinds of source the installed adapters can connect, the built-in ones
  first, then those of `:source_adapters` in their order. Two adapters
  offering the same kind: the first one wins.
  """
  @spec kinds() :: [kind()]
  def kinds do
    (EctoAdapter.builtin_adapters() ++ Config.source_adapters())
    |> Enum.uniq()
    |> Enum.flat_map(&kind_of/1)
    |> Enum.uniq_by(& &1.kind)
  end

  defp kind_of(module) do
    with true <- Code.ensure_loaded?(module),
         true <- Adapter.capability?(module, :connection),
         %{kind: _, label: _, fields: _} = spec <- module.connection() do
      [Map.put(spec, :module, module)]
    else
      _none -> []
    end
  end

  @doc "A kind by name, or `nil` when no installed adapter connects it."
  @spec kind(String.t()) :: kind() | nil
  def kind(name) when is_binary(name), do: Enum.find(kinds(), &(&1.kind == name))

  @doc """
  The settings a form gives, checked against the fields of `kind` and cast
  to their types, with defaults filled in: `{:ok, keyword}` or
  `{:error, errors}`.

  A string is trimmed, and blank is no value. An integer may come as a
  string. A boolean is `true`, `"true"` or `"on"`; anything else is
  `false`. A secret is taken as it is.
  """
  @spec cast(kind(), settings()) :: {:ok, keyword()} | {:error, errors()}
  def cast(%{fields: fields}, settings) do
    {values, errors} =
      Enum.reduce(fields, {[], %{}}, fn field, {values, errors} ->
        case cast_field(field, value(settings, field.key)) do
          {:ok, nil} -> {values, errors}
          {:ok, value} -> {[{field.key, value} | values], errors}
          {:error, message} -> {values, Map.put(errors, field.key, message)}
        end
      end)

    if errors == %{}, do: {:ok, Enum.reverse(values)}, else: {:error, errors}
  end

  defp value(settings, key) do
    case Map.fetch(settings, key) do
      {:ok, value} -> value
      :error -> Map.get(settings, Atom.to_string(key))
    end
  end

  defp cast_field(%{type: :boolean} = field, value) do
    case value do
      blank when blank in [nil, ""] -> {:ok, Map.get(field, :default, false)}
      value -> {:ok, value in [true, "true", "on"]}
    end
  end

  defp cast_field(field, value) do
    case {blank(value), field} do
      {nil, %{default: default}} when not is_nil(default) -> {:ok, default}
      {nil, %{required: true}} -> {:error, "Give the #{String.downcase(field.label)}."}
      {nil, _optional} -> {:ok, nil}
      {value, %{type: :integer}} -> integer(value, field)
      {value, %{type: :secret}} -> {:ok, value}
      {value, _string} -> {:ok, String.trim(to_string(value))}
    end
  end

  defp blank(nil), do: nil
  defp blank(value) when is_binary(value), do: if(String.trim(value) == "", do: nil, else: value)
  defp blank(value), do: value

  defp integer(value, _field) when is_integer(value), do: {:ok, value}

  defp integer(value, field) do
    case Integer.parse(String.trim(to_string(value))) do
      {integer, ""} -> {:ok, integer}
      _other -> {:error, "#{field.label} is a whole number."}
    end
  end

  @doc """
  The source called `name` that `settings` connect, of `kind`: the
  `%Adapter{}` a resolver returns. Its processes are not started: a
  resolver lists it and `Lotus.Source.reconcile/0` starts them.

  `{:error, :unknown_kind}` when no installed adapter connects `kind`,
  `{:error, errors}` when the settings are not valid.
  """
  @spec build(String.t(), String.t() | kind(), settings()) ::
          {:ok, Adapter.t()} | {:error, :unknown_kind | errors() | String.t()}
  def build(name, kind, settings) when is_binary(name) and is_binary(kind) do
    case kind(kind) do
      nil -> {:error, :unknown_kind}
      kind -> build(name, kind, settings)
    end
  end

  def build(name, %{module: module} = kind, settings) when is_binary(name) do
    with {:ok, values} <- cast(kind, settings),
         {:ok, entry} <- module.from_settings(name, values) do
      {:ok, Adapter.with_capabilities(module.wrap(name, entry))}
    end
  end

  @doc """
  Whether `settings` connect, without keeping anything: `:ok`, or
  `{:error, message}` with what the database said, such as
  `password authentication failed for user "lotus"`.

  The source's processes are not started: the adapter's
  `c:Lotus.Source.Adapter.health_check/1` makes a connection of its own.
  """
  @spec test(String.t() | kind(), settings()) :: :ok | {:error, String.t() | errors()}
  def test(kind, settings) do
    name = "lotus-connection-test-#{System.unique_integer([:positive])}"

    case build(name, kind, settings) do
      {:ok, adapter} -> health(adapter)
      {:error, :unknown_kind} -> {:error, "No installed adapter connects #{inspect(kind)}."}
      {:error, errors} -> {:error, errors}
    end
  end

  defp health(adapter) do
    case Adapter.health_check(adapter) do
      :ok -> :ok
      {:error, reason} -> {:error, message(reason)}
    end
  rescue
    exception -> {:error, Exception.message(exception)}
  end

  defp message(%{__exception__: true} = exception), do: Exception.message(exception)
  defp message(message) when is_binary(message), do: message
  defp message(reason), do: inspect(reason)
end
