defmodule Lotus.Source.Adapter.Connection do
  @moduledoc """
  Capability behaviour for an adapter whose sources can be connected from
  settings a person types, instead of from a module in the app's config:
  a host, a port, a user and a password, or a URL and an API key.

  An adapter declares it next to the core behaviour:

      @behaviour Lotus.Source.Adapter
      @behaviour Lotus.Source.Adapter.Connection

  and implements `connection/0`, which names the kind of source and the
  fields its form asks for, and `from_settings/2`, which turns the fields'
  values into the entry its `c:Lotus.Source.Adapter.wrap/2` takes. Whatever
  processes the source needs (a pool, a dynamic repo) are started from
  `c:Lotus.Source.Adapter.source_children/2` like any other source's.

  `Lotus.Source.Connections` lists the kinds every installed adapter offers
  (`Lotus.Source.Connections.kinds/0`), checks a form's values against the
  fields, builds the source, and tests it before it is saved. A host or a
  library such as Lotus Pro keeps the settings and returns the built
  sources from its `Lotus.Source.Resolver`.

  Adapters built with `use Lotus.Source.Adapters.Ecto` get both callbacks
  from its `:connection` option.
  """

  @typedoc """
  A field of a connection form.

    * `:key` - Where `from_settings/2` finds its value
    * `:label` - What the form calls it
    * `:type` - `:string`, `:integer`, `:boolean`, or `:secret` for a
      password or a key, which a form never shows back
    * `:required` - Whether a value must be given. `false` by default
    * `:default` - The value when none is given
    * `:placeholder` - An example value for the form
    * `:hint` - A sentence the form shows under the field
  """
  @type field :: %{
          required(:key) => atom(),
          required(:label) => String.t(),
          required(:type) => :string | :integer | :boolean | :secret,
          optional(:required) => boolean(),
          optional(:default) => term(),
          optional(:placeholder) => String.t(),
          optional(:hint) => String.t()
        }

  @typedoc """
  A kind of source an adapter connects.

    * `:kind` - A stable name for the kind, such as `"postgres"`. Settings
      are saved with it, so it does not change between releases
    * `:label` - What a form calls it, such as `"PostgreSQL"`
    * `:fields` - The fields its form asks for, in order
  """
  @type spec :: %{
          required(:kind) => String.t(),
          required(:label) => String.t(),
          required(:fields) => [field()]
        }

  @doc """
  The kind of source this adapter connects and the fields of its form, or
  `nil` when it cannot connect one in this app, such as when the database
  library it needs is not installed.
  """
  @callback connection() :: spec() | nil

  @doc """
  The entry `c:Lotus.Source.Adapter.wrap/2` takes for a source called
  `name` with these settings, each field's value under its `:key`, checked
  and cast to its type, with defaults filled in.

  `{:error, %{key => message}}` names the fields that are wrong in a way
  `connection/0` cannot say, such as a file that does not exist.
  """
  @callback from_settings(name :: String.t(), settings :: keyword()) ::
              {:ok, term()} | {:error, %{atom() => String.t()} | String.t()}
end
