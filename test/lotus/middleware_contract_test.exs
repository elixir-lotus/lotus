defmodule Lotus.MiddlewareContractTest do
  @moduledoc """
  The query middleware contract, as a whole:

    * `:relations` is a list when preflight proved the set — `[]` means the
      statement touches no relation — and a tagged tuple when nothing is
      known: `{:unrestricted, reason}` or `{:skipped, reason}`.
    * `:after_query` carries the same `:relations` as `:before_execute`, and
      both carry `:origin`, `:executed` or `:cached`.
    * `:after_query` carries the `:assigns` the `:before_execute` plugs of the
      same call left, on a miss and on a hit, and the cache never stores them.
    * `[:lotus, :run, *]` telemetry brackets the whole run on every path —
      a cache hit, a halt in any phase — with the caller's context.
    * Preflight hands its relations back as a value. Nothing crosses phases
      through the process dictionary.
  """

  use Lotus.Case, async: false
  use Mimic

  alias Lotus.Cache.{ETS, Key}
  alias Lotus.{Config, Middleware, Preflight, Runner}
  alias Lotus.Query.Statement
  alias Lotus.Source.Adapters.Ecto, as: EctoAdapter
  alias Lotus.Test.Schemas.User

  defmodule CapturePlug do
    @moduledoc false
    def init(opts), do: opts

    def call(payload, event: event) do
      send(self(), {event, payload})
      {:cont, payload}
    end
  end

  defmodule DenyUserPlug do
    @moduledoc false
    def init(opts), do: opts
    def call(%{context: %{user: "b"}}, _opts), do: {:halt, "denied"}
    def call(payload, _opts), do: {:cont, payload}
  end

  defmodule AssignPlug do
    @moduledoc false
    def init(opts), do: opts

    def call(%{assigns: assigns} = payload, key: key, value: value) do
      {:cont, %{payload | assigns: Map.put(assigns, key, value)}}
    end
  end

  defmodule AssignUserPlug do
    @moduledoc false
    def init(opts), do: opts

    def call(%{assigns: assigns, context: %{user: user}} = payload, _opts) do
      {:cont, %{payload | assigns: Map.put(assigns, :granted_to, user)}}
    end
  end

  defmodule RewriteCoreKeysPlug do
    @moduledoc false
    def init(opts), do: opts

    def call(%{statement: statement} = payload, _opts) do
      {:cont,
       %{
         payload
         | statement: %{statement | body: "SELECT 'rewritten' AS id"},
           relations: [{"public", "decoy"}],
           origin: :cached,
           context: %{user: "impostor"},
           assigns: %{kept: true}
       }}
    end
  end

  defmodule NonMapAssignsPlug do
    @moduledoc false
    def init(opts), do: opts
    def call(payload, _opts), do: {:cont, %{payload | assigns: :not_a_map}}
  end

  defmodule DenyingResolver do
    @moduledoc false
    @behaviour Lotus.Visibility.Resolver

    @impl true
    def schema_rules_for(_source, _scope), do: []

    @impl true
    def table_rules_for(_source, _scope), do: [deny: [{"public", "test_users"}]]

    @impl true
    def column_rules_for(_source, _scope), do: []
  end

  @statement "SELECT id FROM test_users ORDER BY id"
  @pg_adapter EctoAdapter.wrap("postgres", Lotus.Test.Repo)
  @run_events [[:lotus, :run, :start], [:lotus, :run, :stop], [:lotus, :run, :exception]]

  setup :set_mimic_from_context

  setup do
    clear_cache_tables()

    on_exit(fn ->
      :persistent_term.erase({Lotus.Middleware, :compiled})
      clear_cache_tables()
    end)

    Config
    |> stub(:cache_adapter, fn -> {:ok, ETS} end)
    |> stub(:cache_namespace, fn -> "middleware_contract_test" end)
    |> stub(:default_cache_profile, fn -> :results end)
    |> stub(:cache_profile_settings, fn _profile -> [ttl_ms: 30_000] end)

    Repo.insert!(%User{id: 1, name: "Ada", email: "ada@example.test", age: 36})
    Repo.insert!(%User{id: 2, name: "Grace", email: "grace@example.test", age: 85})

    :ok
  end

  defp clear_cache_tables do
    for table <- [:lotus_cache, :lotus_cache_tags] do
      if :ets.whereis(table) != :undefined, do: :ets.delete_all_objects(table)
    end

    :ok
  end

  defp run(statement \\ @statement, opts) do
    Lotus.run_statement(statement, [], Keyword.merge([repo: "postgres"], opts))
  end

  defp attach_run_events do
    ref = make_ref()
    pid = self()

    for event <- @run_events do
      id = {ref, event}

      :telemetry.attach(
        id,
        event,
        fn ev, measurements, metadata, _config ->
          send(pid, {:run_event, ev, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(id) end)
    end

    :ok
  end

  defp drain(acc \\ []) do
    receive do
      message -> drain([message | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe ":relations" do
    test "an empty list means the statement touches no relation" do
      Middleware.compile(%{before_execute: [{CapturePlug, [event: :before_execute]}]})

      assert {:ok, _} = run("SELECT 1", [])

      assert_received {:before_execute, %{relations: []}}
    end

    test "a statement the adapter does not preflight yields {:skipped, reason}" do
      Middleware.compile(%{before_execute: [{CapturePlug, [event: :before_execute]}]})

      assert {:ok, _} = run("EXPLAIN SELECT 1", [])

      assert_received {:before_execute, %{relations: {:skipped, reason}}}
      assert is_binary(reason)
    end
  end

  describe ":after_query" do
    test "carries the relations :before_execute saw, and origin :executed on a miss" do
      Middleware.compile(%{
        before_execute: [{CapturePlug, [event: :before_execute]}],
        after_query: [{CapturePlug, [event: :after_query]}]
      })

      assert {:ok, _} = run(context: %{user: "a"})

      assert_received {:before_execute, %{relations: relations, origin: :executed}}
      assert relations == [{"public", "test_users"}]
      assert_received {:after_query, %{relations: ^relations, origin: :executed}}
    end

    test "on a cache hit both events carry the stored relations and origin :cached" do
      Middleware.compile(%{
        before_execute: [{CapturePlug, [event: :before_execute]}],
        after_query: [{CapturePlug, [event: :after_query]}]
      })

      assert {:ok, _} = run(context: %{user: "a"})
      drain()

      assert {:ok, _} = run(context: %{user: "a"})

      assert_received {:before_execute, %{relations: [{"public", "test_users"}], origin: :cached}}
      assert_received {:after_query, %{relations: [{"public", "test_users"}], origin: :cached}}
    end

    test "the uncached runner path carries the same keys" do
      Middleware.compile(%{after_query: [{CapturePlug, [event: :after_query]}]})

      assert {:ok, _} =
               Runner.run_statement(@pg_adapter, Statement.new(@statement, []),
                 context: %{user: "a"}
               )

      assert_received {:after_query,
                       %{
                         relations: [{"public", "test_users"}],
                         origin: :executed,
                         context: %{user: "a"}
                       }}
    end
  end

  describe ":assigns" do
    test ":before_execute starts with empty assigns, and each plug sees what the previous one left" do
      Middleware.compile(%{
        before_execute: [
          {CapturePlug, [event: :first]},
          {AssignPlug, [key: :grant, value: :read]},
          {CapturePlug, [event: :second]}
        ]
      })

      assert {:ok, _} = run(context: %{user: "a"})

      assert_received {:first, %{assigns: %{} = first}}
      assert first == %{}
      assert_received {:second, %{assigns: %{grant: :read}}}
    end

    test ":after_query receives the assigns :before_execute left, on a miss" do
      Middleware.compile(%{
        before_execute: [{AssignUserPlug, []}],
        after_query: [{CapturePlug, [event: :after_query]}]
      })

      assert {:ok, _} = run(context: %{user: "a"})

      assert_received {:after_query, %{assigns: %{granted_to: "a"}, origin: :executed}}
    end

    test "on a cache hit, :after_query receives the assigns of this call's :before_execute" do
      Middleware.compile(%{
        before_execute: [{AssignUserPlug, []}],
        after_query: [{CapturePlug, [event: :after_query]}]
      })

      assert {:ok, _} = run(context: %{user: "a"})
      drain()

      assert {:ok, _} = run(context: %{user: "b"})

      assert_received {:after_query, %{assigns: %{granted_to: "b"}, origin: :cached}}
    end

    test "the cache stores the execution without the assigns" do
      Middleware.compile(%{before_execute: [{AssignUserPlug, []}]})

      assert {:ok, _} = run(context: %{user: "a"})

      key =
        Key.result(
          @statement,
          %{__params__: []},
          [data_source: "postgres", search_path: nil, lotus_version: Lotus.version()],
          nil
        )

      assert {:ok, entry} = Lotus.Cache.get(key)
      assert entry |> Map.keys() |> Enum.sort() == [:relations, :result]
    end

    test "the uncached runner path carries the assigns" do
      Middleware.compile(%{
        before_execute: [{AssignUserPlug, []}],
        after_query: [{CapturePlug, [event: :after_query]}]
      })

      assert {:ok, _} =
               Runner.run_statement(@pg_adapter, Statement.new(@statement, []),
                 context: %{user: "a"}
               )

      assert_received {:after_query, %{assigns: %{granted_to: "a"}}}
    end

    test ":after_query receives empty assigns when no :before_execute plug is configured" do
      Middleware.compile(%{after_query: [{CapturePlug, [event: :after_query]}]})

      assert {:ok, _} = run(context: %{user: "a"})

      assert_received {:after_query, %{assigns: assigns}}
      assert assigns == %{}
    end

    test "a :before_execute plug that changes the core keys changes only the assigns" do
      Middleware.compile(%{
        before_execute: [{RewriteCoreKeysPlug, []}],
        after_query: [{CapturePlug, [event: :after_query]}]
      })

      assert {:ok, result} = run(context: %{user: "a"})
      assert result.rows == [[1], [2]]

      assert_received {:after_query, payload}
      assert payload.statement.body == @statement
      assert payload.relations == [{"public", "test_users"}]
      assert payload.origin == :executed
      assert payload.context == %{user: "a"}
      assert payload.assigns == %{kept: true}
    end

    test "assigns that are not a map reach :after_query as an empty map" do
      Middleware.compile(%{
        before_execute: [{NonMapAssignsPlug, []}],
        after_query: [{CapturePlug, [event: :after_query]}]
      })

      assert {:ok, _} = run(context: %{user: "a"})

      assert_received {:after_query, %{assigns: assigns}}
      assert assigns == %{}
    end

    test "a :before_execute halt on a miss stores nothing" do
      Middleware.compile(%{
        before_execute: [{DenyUserPlug, []}],
        after_query: [{CapturePlug, [event: :after_query]}]
      })

      assert {:error, "denied"} = run(context: %{user: "b"})
      assert {:ok, _} = run(context: %{user: "a"})

      assert_received {:after_query, %{origin: :executed}}
    end
  end

  describe "[:lotus, :cache, *] telemetry for a run" do
    setup do
      ref = make_ref()
      pid = self()
      events = [[:lotus, :cache, :hit], [:lotus, :cache, :miss], [:lotus, :cache, :put]]

      :telemetry.attach_many(
        ref,
        events,
        fn [:lotus, :cache, kind], _measurements, _metadata, _config ->
          send(pid, {:cache_event, kind})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(ref) end)
    end

    test "a miss reports one miss and one put, and a hit reports one hit" do
      assert {:ok, _} = run(context: %{user: "a"})
      assert Enum.sort(for {:cache_event, kind} <- drain(), do: kind) == [:miss, :put]

      assert {:ok, _} = run(context: %{user: "a"})
      assert for({:cache_event, kind} <- drain(), do: kind) == [:hit]
    end
  end

  describe "[:lotus, :run, *] telemetry" do
    setup do
      attach_run_events()
    end

    test "brackets the run from :before_query to :after_query" do
      Middleware.compile(%{
        before_query: [{CapturePlug, [event: :before_query]}],
        after_query: [{CapturePlug, [event: :after_query]}]
      })

      assert {:ok, _} = run(context: %{user: "a"})

      order =
        drain()
        |> Enum.map(fn
          {:run_event, [:lotus, :run, phase], _, _} -> {:run, phase}
          {event, _payload} -> event
        end)

      assert order == [{:run, :start}, :before_query, :after_query, {:run, :stop}]
    end

    test ":stop fires on a cache hit with the caller's context and origin :cached" do
      assert {:ok, _} = run(context: %{user: "a"})
      drain()

      assert {:ok, _} = run(context: %{user: "b"})

      assert_received {:run_event, [:lotus, :run, :stop], %{duration: _, row_count: 2}, metadata}
      assert metadata.context == %{user: "b"}
      assert metadata.origin == :cached
      assert metadata.relations == [{"public", "test_users"}]
      assert metadata.source == "postgres"
    end

    test ":exception fires on a :before_query halt with the phase and the caller's context" do
      Middleware.compile(%{before_query: [{DenyUserPlug, []}]})

      assert {:error, "denied"} = run(context: %{user: "b"})

      assert_received {:run_event, [:lotus, :run, :exception], %{duration: _}, metadata}
      assert metadata.phase == :before_query
      assert metadata.reason == "denied"
      assert metadata.context == %{user: "b"}
      refute_received {:run_event, [:lotus, :run, :stop], _, _}
    end

    test ":exception fires on a :before_execute halt on a cache hit" do
      Middleware.compile(%{before_execute: [{DenyUserPlug, []}]})

      assert {:ok, _} = run(context: %{user: "a"})
      drain()

      assert {:error, "denied"} = run(context: %{user: "b"})

      assert_received {:run_event, [:lotus, :run, :exception], _, metadata}
      assert metadata.phase == :before_execute
      assert metadata.origin == :cached
      assert metadata.context == %{user: "b"}
    end

    test "the run events are listed" do
      for event <- @run_events, do: assert(event in Lotus.Telemetry.events())
    end
  end

  describe "preflight" do
    test "analyze/4 returns the relations a statement touches" do
      assert {:ok, [{"public", "test_users"}]} =
               Preflight.analyze(@pg_adapter, Statement.new(@statement, []))
    end

    test "analyze/4 returns an empty list for a statement that touches nothing" do
      assert {:ok, []} = Preflight.analyze(@pg_adapter, Statement.new("SELECT 1", []))
    end

    test "analyze/4 returns the error for a blocked relation" do
      stub(Config, :visibility_resolver, fn -> DenyingResolver end)

      assert {:error, message} = Preflight.analyze(@pg_adapter, Statement.new(@statement, []))
      assert message =~ "blocked"
    end

    test "a run leaves nothing in the process dictionary, on success and on a halt" do
      assert {:ok, _} = run(context: %{user: "a"})
      assert Process.get(:lotus_preflight_relations) == nil

      Middleware.compile(%{before_execute: [{DenyUserPlug, []}]})
      assert {:error, "denied"} = run(context: %{user: "b"})
      assert Process.get(:lotus_preflight_relations) == nil
    end
  end
end
