defmodule Lotus.AI.Prompts.AdapterNotes do
  @moduledoc """
  Resolves the prompt text an adapter contributes about its own query
  language, falling back to core's language-agnostic defaults.

  Core owns prompt *structure* — the workflow, the tool list, the
  `UNABLE_TO_GENERATE` protocol, the fence. The adapter owns prompt
  *content* about its own language. The split follows the enforcement:
  `sanitize_query/3` is already an adapter callback, so the adapter, not
  core, decides what counts as a write. Prompt text belongs where the
  authority sits.

  Adapter notes render **in place of** core's defaults, never appended
  after them. Appending would make an adapter argue against core instead
  of speaking for itself — the Elasticsearch adapter's `syntax_notes`
  followed core's "never generate INSERT, UPDATE, DELETE", which names
  operations Elasticsearch does not have.

  ## Falling back, never blanking

  `Lotus.Source.Adapter.ai_context/1` drops both fields for adapters that
  are not in `:trusted_source_adapters`. This module then supplies core's
  default. It must never resolve to an empty string: an empty
  `read_only_notes/1` would leave the prompt with no read-only
  instruction at all, which is a way for an untrusted adapter to weaken
  the guard by supplying a blank.
  """

  @default_read_only_notes """
  **IMPORTANT:** You can ONLY generate read-only queries. Never generate
  anything that creates, modifies or deletes data or schema. If asked to,
  respond with: "UNABLE_TO_GENERATE: [reason]"
  """

  @default_write_notes """
  **IMPORTANT:** You can generate queries that read and queries that
  write.
  """

  @default_generation_notes """
  - Prefer naming fields explicitly over wildcards.
  - Constrain the result size unless asked for everything.
  - Use fully-qualified names when the tools provide them.
  """

  @default_language "sql"
  @default_fence_label "sql"

  # A fence label is interpolated straight into the prompt, so it is
  # constrained here as well as upstream. `ai_context/1` already replaces a
  # malformed `:language` with `"unknown"`, but this module must not depend on
  # that being the only way a value reaches it.
  @fence_label_format ~r/\A[a-z0-9]+\z/

  @doc """
  Guidance on how to shape a good query for this source.

  Returns the adapter's `:generation_notes` when it supplied one, else
  core's language-agnostic default.
  """
  @spec generation_notes(map()) :: String.t()
  def generation_notes(ai_context) do
    resolve(ai_context, :generation_notes, @default_generation_notes)
  end

  @doc """
  Guidance on which operations count as writes for this source, and so
  must never be generated.

  Returns the adapter's `:read_only_notes` when it supplied one, else
  core's language-agnostic default. Passing `false` for `read_only?`
  returns core's write-permitted text and ignores the adapter's notes,
  which describe a restriction that is not in force.
  """
  @spec read_only_notes(map(), boolean()) :: String.t()
  def read_only_notes(ai_context, read_only? \\ true)

  def read_only_notes(ai_context, true) do
    resolve(ai_context, :read_only_notes, @default_read_only_notes)
  end

  def read_only_notes(_ai_context, false), do: @default_write_notes

  @doc """
  The markdown fence label for statements in this language.

  This is the language *family* — the part before the colon — because
  editors and markdown renderers know `sql` and `json`, and do not know
  `sql:clickhouse`.

  Reads only the sanitized `:language` from `ai_context`, which
  `Lotus.Source.Adapter.ai_context/1` has already constrained to
  `~r/\\A[a-z0-9]+:[a-z0-9_-]+\\z/` or replaced with `"unknown"`. Never
  interpolate a raw `query_language/1` here: that value has no
  validation, so it could carry a newline or backticks and break out of
  the fence. As a second line of defence, a family that is not plain
  `[a-z0-9]+` is replaced with `"sql"` rather than emitted.
  """
  @spec fence_label(map()) :: String.t()
  def fence_label(ai_context) do
    ai_context
    |> Map.get(:language, @default_language)
    |> family()
  end

  defp family(language) when is_binary(language) do
    case language |> String.split(":", parts: 2) |> hd() do
      "unknown" ->
        @default_fence_label

      family ->
        if Regex.match?(@fence_label_format, family),
          do: family,
          else: @default_fence_label
    end
  end

  defp family(_), do: @default_fence_label

  defp resolve(ai_context, key, default) do
    case Map.get(ai_context, key) do
      notes when is_binary(notes) ->
        if String.trim(notes) == "", do: default, else: notes

      _ ->
        default
    end
  end
end
