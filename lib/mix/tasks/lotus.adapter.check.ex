defmodule Mix.Tasks.Lotus.Adapter.Check do
  @shortdoc "Lists the capabilities a source adapter declares"

  @moduledoc """
  Lists the capability behaviours each given source adapter declares, and
  what keeps the others from applying.

      $ mix lotus.adapter.check MyApp.Adapters.Search

      MyApp.Adapters.Search
        core           declared
        introspection  declared
        preflight      declared
        binding        not declared
        shaping        not declared, ignores apply_filters/3, apply_sorts/3
        editor         declared, missing example_query/3
        session        not declared

  `Lotus.Source.Adapter` dispatches a capability's callbacks only to a
  module that declares its behaviour, so a capability is one of:

    * **declared** — the module declares the behaviour and Lotus calls its
      callbacks.
    * **declared, missing ...** — the module declares the behaviour but
      leaves out required callbacks. The compiler warns about these too.
    * **not declared** — Lotus uses the defaults of
      `Lotus.Source.Adapter` for the capability.
    * **not declared, ignores ...** — the module exports callbacks of the
      behaviour without declaring it, so Lotus ignores them. Add the
      `@behaviour` line.

  The task exits with a non-zero status when a module is not a
  `Lotus.Source.Adapter`, misses callbacks of a capability it declares, or
  exports callbacks of one it does not.
  """

  use Mix.Task

  alias Lotus.Source.Adapter

  @impl Mix.Task
  def run(args) do
    {_opts, names, _invalid} = OptionParser.parse(args, strict: [])

    if names == [] do
      Mix.raise("Usage: mix lotus.adapter.check MyApp.Adapter [MyApp.OtherAdapter ...]")
    end

    Mix.Task.run("compile")

    failed =
      names
      |> Enum.map(&to_module/1)
      |> Enum.reject(fn mod ->
        report = report(mod)
        Mix.shell().info(format(report))
        report.ok?
      end)

    if failed != [] do
      Mix.raise("Adapter check failed for #{Enum.map_join(failed, ", ", &label/1)}")
    end
  end

  # A module that is not compiled has no atom yet; keep the name as given
  # rather than minting one.
  defp to_module(name) do
    Module.safe_concat([name])
  rescue
    ArgumentError -> name
  end

  @typedoc false
  @type status ::
          :declared
          | {:missing, [{atom(), arity()}]}
          | :absent
          | {:ignored, [{atom(), arity()}]}

  @typedoc false
  @type report :: %{
          module: module() | String.t(),
          core: :declared | :absent | :not_loaded,
          capabilities: [{Adapter.capability(), status()}],
          ok?: boolean()
        }

  @doc false
  @spec report(module() | String.t()) :: report()
  def report(mod) when is_atom(mod) do
    if Code.ensure_loaded?(mod) do
      behaviours =
        mod.module_info(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()

      core = if Adapter in behaviours, do: :declared, else: :absent

      capabilities =
        for {cap, behaviour} <- Adapter.capability_behaviours(),
            do: {cap, status(mod, behaviour, behaviour in behaviours)}

      ok? =
        core == :declared and
          Enum.all?(capabilities, fn {_cap, status} -> status in [:declared, :absent] end)

      %{module: mod, core: core, capabilities: capabilities, ok?: ok?}
    else
      %{module: mod, core: :not_loaded, capabilities: [], ok?: false}
    end
  end

  def report(name) when is_binary(name),
    do: %{module: name, core: :not_loaded, capabilities: [], ok?: false}

  defp status(mod, behaviour, true) do
    required =
      behaviour.behaviour_info(:callbacks) -- behaviour.behaviour_info(:optional_callbacks)

    case Enum.reject(required, fn {fun, arity} -> function_exported?(mod, fun, arity) end) do
      [] -> :declared
      missing -> {:missing, Enum.sort(missing)}
    end
  end

  defp status(mod, behaviour, false) do
    case Enum.filter(behaviour.behaviour_info(:callbacks), fn {fun, arity} ->
           function_exported?(mod, fun, arity)
         end) do
      [] -> :absent
      exported -> {:ignored, Enum.sort(exported)}
    end
  end

  @doc false
  @spec format(report()) :: String.t()
  def format(%{module: mod, core: :not_loaded}),
    do: "#{label(mod)}\n  not loaded: check the module name\n"

  def format(%{module: mod, core: core, capabilities: capabilities}) do
    rows = [{"core", core_label(core)} | Enum.map(capabilities, &capability_row/1)]
    width = rows |> Enum.map(fn {name, _} -> String.length(name) end) |> Enum.max()

    lines =
      Enum.map(rows, fn {name, text} -> "  #{String.pad_trailing(name, width)}  #{text}" end)

    Enum.join([label(mod) | lines], "\n") <> "\n"
  end

  defp label(name) when is_binary(name), do: name
  defp label(mod), do: inspect(mod)

  defp core_label(:declared), do: "declared"
  defp core_label(:absent), do: "not declared: add `@behaviour Lotus.Source.Adapter`"

  defp capability_row({cap, status}), do: {Atom.to_string(cap), status_label(status)}

  defp status_label(:declared), do: "declared"
  defp status_label(:absent), do: "not declared"
  defp status_label({:missing, funs}), do: "declared, missing #{format_funs(funs)}"
  defp status_label({:ignored, funs}), do: "not declared, ignores #{format_funs(funs)}"

  defp format_funs(funs), do: Enum.map_join(funs, ", ", fn {fun, arity} -> "#{fun}/#{arity}" end)
end
