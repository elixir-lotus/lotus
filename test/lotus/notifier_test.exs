defmodule Lotus.NotifierTest do
  use ExUnit.Case, async: true

  alias Lotus.Notifier

  setup do
    topic = {:notifier_test, System.unique_integer([:positive])}
    on_exit(fn -> Notifier.unlisten(topic) end)
    %{topic: topic}
  end

  describe "listen/1 and notify/3" do
    test "delivers the payload to a listener on this node", %{topic: topic} do
      :ok = Notifier.listen(topic)

      :ok = Notifier.notify(topic, {:changed, "main"})

      assert_receive {:lotus_notification, ^topic, {:changed, "main"}}
    end

    test "delivers to every listener of the topic", %{topic: topic} do
      parent = self()

      listener =
        spawn_link(fn ->
          Notifier.listen(topic)
          send(parent, :listening)

          receive do
            message -> send(parent, {:forwarded, message})
          end
        end)

      assert_receive :listening
      :ok = Notifier.listen(topic)

      :ok = Notifier.notify(topic, :ping)

      assert_receive {:lotus_notification, ^topic, :ping}
      assert_receive {:forwarded, {:lotus_notification, ^topic, :ping}}
      assert listener in Notifier.listeners(topic)
    end

    test "does not deliver to another topic", %{topic: topic} do
      :ok = Notifier.listen(topic)

      :ok = Notifier.notify({:other, topic}, :ping)

      refute_receive {:lotus_notification, _, :ping}
    end

    test "skips listeners on the nodes listed in :except", %{topic: topic} do
      :ok = Notifier.listen(topic)

      :ok = Notifier.notify(topic, :ping, except: [node()])

      refute_receive {:lotus_notification, ^topic, :ping}
    end

    test "is a no-op with no listeners", %{topic: topic} do
      assert Notifier.notify(topic, :ping) == :ok
      assert Notifier.listeners(topic) == []
    end
  end

  describe "unlisten/1" do
    test "stops delivery to the calling process", %{topic: topic} do
      :ok = Notifier.listen(topic)
      :ok = Notifier.unlisten(topic)

      :ok = Notifier.notify(topic, :ping)

      refute_receive {:lotus_notification, ^topic, :ping}
      refute self() in Notifier.listeners(topic)
    end

    test "returns :ok for a topic the process never joined", %{topic: topic} do
      assert Notifier.unlisten(topic) == :ok
    end
  end

  describe "listeners/1" do
    test "forgets a listener that exits", %{topic: topic} do
      parent = self()

      listener =
        spawn(fn ->
          Notifier.listen(topic)
          send(parent, :listening)

          receive do
            :stop -> :ok
          end
        end)

      assert_receive :listening
      assert listener in Notifier.listeners(topic)

      ref = Process.monitor(listener)
      send(listener, :stop)
      assert_receive {:DOWN, ^ref, :process, ^listener, _}

      wait_until(fn -> listener not in Notifier.listeners(topic) end)
    end
  end

  describe "start_link/1" do
    test "returns :ignore when the scope is already running" do
      assert Notifier.start_link([]) == :ignore
    end
  end

  defp wait_until(fun, attempts \\ 50)

  defp wait_until(fun, 0), do: assert(fun.())

  defp wait_until(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      wait_until(fun, attempts - 1)
    end
  end
end
