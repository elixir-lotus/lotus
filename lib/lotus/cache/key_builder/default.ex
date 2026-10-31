defmodule Lotus.Cache.KeyBuilder.Default do
  @moduledoc """
  Default cache key builder for Lotus.

  Preserves the original key generation logic that was previously inline
  in `Lotus.Schema` and `Lotus.Cache.Key`.
  """

  alias Lotus.Cache.KeyBuilder

  @behaviour KeyBuilder

  @impl true
  def discovery_key(
        %{kind: kind, source_name: source_name, components: components, version: version},
        scope
      ) do
    digest =
      :crypto.hash(
        :sha256,
        :erlang.term_to_binary(
          List.to_tuple([source_name | Tuple.to_list(components)] ++ [version])
        )
      )
      |> Base.encode16(case: :lower)

    scope_part =
      case KeyBuilder.scope_digest(scope) do
        "" -> ""
        d -> ":#{d}"
      end

    "schema:#{kind}:#{source_name}:#{digest}#{scope_part}"
  end

  @impl true
  def result_key(body, bound, opts, scope) do
    repo = Keyword.fetch!(opts, :data_source)
    path = Keyword.get(opts, :search_path, "") || ""
    version = Keyword.get(opts, :lotus_version, Lotus.version())

    digest_input =
      case bound do
        %{} = vars -> vars
        list when is_list(list) -> %{__params__: list}
      end

    digest =
      :crypto.hash(
        :sha256,
        [
          :erlang.term_to_binary(body),
          ?|,
          :erlang.term_to_binary(digest_input),
          ?|,
          repo,
          ?|,
          path,
          ?|,
          version
          | mode_part(Keyword.get(opts, :read_only, true))
        ]
      )
      |> Base.encode16(case: :lower)

    scope_part =
      case KeyBuilder.scope_digest(scope) do
        "" -> ""
        d -> ":#{d}"
      end

    "result:#{repo}:#{digest}#{scope_part}"
  end

  # A read-only run's key is as it always was; a read-write run's differs.
  defp mode_part(false), do: [?|, "read-write"]
  defp mode_part(_read_only), do: []
end
