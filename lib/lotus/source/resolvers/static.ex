defmodule Lotus.Source.Resolvers.Static do
  @moduledoc """
  Default source resolver that reads from static `data_sources` configuration.

  Resolution priority:

    1. `source_opt` as string name — lookup in data_sources, wrap in adapter
    2. `source_opt` as module — reverse lookup (find name for module), wrap in adapter
    3. `fallback` as string name — lookup
    4. `fallback` as module — reverse lookup
    5. Both nil — use `Config.default_data_source()`
    6. Not found — `{:error, :not_found}`

  ## Entry forms

  A `:data_sources` entry is one of:

    * an `Ecto.Repo` module — matched against the built-in Ecto adapters by
      the repo's Ecto adapter, falling back to the generic Ecto adapter.

    * `%{adapter: MyAdapter, ...}` — the **canonical** form. The named module
      is used directly; the whole map is passed to its `wrap/2` as state.
      Prefer this: it is explicit, skips `can_handle?/1` probing, and cannot
      become ambiguous.

    * any other term — offered to each module in `:source_adapters` via
      `can_handle?/1`. Exactly one must claim it. If several do, resolution
      raises rather than silently picking the first; name the adapter in the
      entry to settle it.
  """

  @behaviour Lotus.Source.Resolver

  alias Lotus.Config
  alias Lotus.Source.Adapters.Ecto, as: EctoAdapter

  # ---------------------------------------------------------------------------
  # Callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def resolve(source_opt, fallback) do
    cond do
      is_binary(source_opt) ->
        lookup_by_name(source_opt)

      source_module?(source_opt) ->
        lookup_by_module(source_opt)

      is_binary(fallback) ->
        lookup_by_name(fallback)

      source_module?(fallback) ->
        lookup_by_module(fallback)

      is_nil(source_opt) and is_nil(fallback) ->
        {:ok, default_adapter()}

      # Neither position could be resolved, but at least one of them named
      # something. Falling through to the default source here would run the
      # query against the wrong database: a typo in a saved query's
      # `data_source`, or a source dropped from config, would quietly
      # return rows from somewhere else. Callers see :not_found instead,
      # which `Lotus.Source.resolve!/2` turns into a message listing the
      # configured source names.
      true ->
        {:error, :not_found}
    end
  end

  @impl true
  def list_sources do
    Config.data_sources()
    |> Enum.map(fn {name, mod} -> wrap_entry(name, mod) end)
  end

  @impl true
  def get_source!(name) do
    mod = Config.get_data_source!(name)
    wrap_entry(name, mod)
  end

  @impl true
  def list_source_names do
    Config.list_data_source_names()
  end

  @impl true
  def default_source do
    {name, mod} = Config.default_data_source()
    {name, wrap_entry(name, mod)}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp lookup_by_name(name) do
    case Map.get(Config.data_sources(), name) do
      nil -> {:error, :not_found}
      mod -> {:ok, wrap_entry(name, mod)}
    end
  end

  defp lookup_by_module(mod) do
    case Enum.find(Config.data_sources(), fn {_name, m} -> m == mod end) do
      {name, _} -> {:ok, wrap_entry(name, mod)}
      nil -> {:error, :not_found}
    end
  end

  # An entry may name its adapter outright — `%{adapter: MyAdapter, ...}` —
  # which is the canonical form: no `can_handle?/1` probing, no ambiguity,
  # and the whole entry is handed to the adapter as its state.
  defp wrap_entry(name, %{adapter: adapter_mod} = entry) when is_atom(adapter_mod) do
    if module_name?(adapter_mod) do
      wrap_named_adapter(name, adapter_mod, entry)
    else
      wrap_by_probing(name, entry)
    end
  end

  defp wrap_entry(name, entry), do: wrap_by_probing(name, entry)

  defp wrap_named_adapter(name, adapter_mod, entry) do
    unless Code.ensure_loaded?(adapter_mod) and function_exported?(adapter_mod, :wrap, 2) do
      raise ArgumentError, """
      Data source #{inspect(name)} names #{inspect(adapter_mod)} as its adapter,
      but that module is not loaded or does not export `wrap/2`.

      The configured entry was:

          #{inspect(entry)}

      Check the module name for typos and make sure the library providing it
      is listed in your dependencies.
      """
    end

    adapter_mod.wrap(name, entry)
  end

  # Distinguishes `%{adapter: MyApp.Adapter}` — a module reference — from
  # `%{adapter: :some_tag}`, where the host is using `:adapter` as its own
  # discriminator and expects `can_handle?/1` probing. Elixir module atoms
  # are `Elixir.`-prefixed, so Module.split/1 succeeds only for those.
  defp module_name?(atom) do
    Module.split(atom)
    true
  rescue
    ArgumentError -> false
  end

  defp wrap_by_probing(name, entry) do
    case find_adapter(entry) do
      {:ok, adapter_mod} ->
        adapter_mod.wrap(name, entry)

      :none when is_atom(entry) ->
        # Atom entries fall back to EctoAdapter — it handles unknown Ecto
        # dialects by wrapping them with a default source_type.
        EctoAdapter.wrap(name, entry)

      {:ambiguous, mods} ->
        raise ArgumentError, """
        More than one source adapter claims data source #{inspect(name)}.

        These adapters all returned true from `can_handle?/1`:

        #{Enum.map_join(mods, "\n", &"    * #{inspect(&1)}")}

        Probing cannot decide between them. Name the adapter you want in the
        entry itself:

            #{inspect(name)} => %{adapter: #{inspect(hd(mods))}, ...}

        A named adapter is used directly and skips `can_handle?/1` entirely.
        """

      :none ->
        raise ArgumentError, """
        No source adapter can handle data source #{inspect(name)}.

        The configured entry was:

            #{inspect(entry)}

        For non-Ecto sources (maps, tuples, etc.), either name the adapter in
        the entry — `%{adapter: MyAdapter, ...}` — or configure it in
        `:lotus, :source_adapters` with a `can_handle?/1` that returns true
        for this entry.
        """
    end
  end

  defp find_adapter(entry) do
    all_adapters = Config.source_adapters() ++ EctoAdapter.builtin_adapters()

    case Enum.filter(all_adapters, & &1.can_handle?(entry)) do
      [] -> :none
      [mod] -> {:ok, mod}
      mods -> {:ambiguous, mods}
    end
  end

  # Accepts any loaded module (Ecto repo or non-Ecto adapter module). Rejects
  # bare atoms (e.g. :typoed_name) so they fall through the resolver's cond
  # chain instead of committing to a failing module lookup.
  defp source_module?(mod) when is_atom(mod) and not is_nil(mod) do
    Code.ensure_loaded?(mod) and function_exported?(mod, :module_info, 0)
  end

  defp source_module?(_), do: false

  defp default_adapter do
    {name, mod} = Config.default_data_source()
    wrap_entry(name, mod)
  end
end
