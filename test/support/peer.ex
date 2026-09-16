defmodule Lotus.Test.Peer do
  @moduledoc """
  Starts a second node that runs `:lotus` for the cluster integration tests.

  The test node becomes distributed on first use. The peer gets the same
  code path and the same `:lotus` application environment as the test
  node, plus whatever `env` the caller adds, and boots the `:lotus`
  application with it. `epmd` must be running: `epmd -daemon`.
  """

  @cookie :lotus_cluster_test

  @spec ensure_distribution!() :: :ok
  def ensure_distribution! do
    unless Node.alive?() do
      {_, 0} = System.cmd("epmd", ["-daemon"])
      name = :"lotus_test_#{System.pid()}@127.0.0.1"
      {:ok, _} = :net_kernel.start(name, %{name_domain: :longnames})
    end

    Node.set_cookie(@cookie)
    :ok
  end

  @spec start!(atom(), keyword()) :: {pid(), node()}
  def start!(name, env) do
    ensure_distribution!()

    code_path = Enum.flat_map(:code.get_path(), &[~c"-pa", &1])
    args = code_path ++ [~c"-setcookie", Atom.to_charlist(@cookie)]

    {:ok, pid, node} =
      :peer.start(%{
        name: name,
        host: ~c"127.0.0.1",
        longnames: true,
        args: args,
        wait_boot: 30_000
      })

    lotus_env = Keyword.merge(Application.get_all_env(:lotus), env)
    :ok = :rpc.call(node, Application, :put_all_env, [[lotus: lotus_env]])
    {:ok, _apps} = :rpc.call(node, Application, :ensure_all_started, [:lotus])

    {pid, node}
  end

  @spec stop(pid()) :: :ok
  def stop(pid), do: :peer.stop(pid)

  @spec call(node(), module(), atom(), list()) :: term()
  def call(node, module, function, args) do
    case :rpc.call(node, module, function, args) do
      {:badrpc, reason} -> raise "rpc to #{node} failed: #{inspect(reason)}"
      result -> result
    end
  end

  @spec wait_until((-> boolean()), pos_integer()) :: :ok
  def wait_until(fun, attempts \\ 100) do
    cond do
      fun.() ->
        :ok

      attempts == 0 ->
        raise "condition did not become true in time"

      true ->
        Process.sleep(20)
        wait_until(fun, attempts - 1)
    end
  end
end
