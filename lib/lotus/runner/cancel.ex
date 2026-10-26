defmodule Lotus.Runner.Cancel do
  @moduledoc """
  The token that stops a running statement, and its bookkeeping.

  A caller of `Lotus.run_statement/3` or `Lotus.run_query/2` passes
  `on_cancel_token: fun`. When the statement is about to run on a source
  that declares `Lotus.Source.Adapter.Cancel`, `fun` is called with a token,
  in the process running the statement. Any process may then pass the token
  to `Lotus.cancel/1`.

  The token is only good while its statement runs. Once the statement
  returns, `Lotus.cancel/1` does nothing to the database: the connection
  is back in the pool, and may run someone else's statement. While a cancel
  is on its way, the statement's transaction stays open until it is done,
  for the same reason.

  The token reaches the caller just before the statement starts, so a
  cancel can arrive before the database runs it, and a database ignores a
  cancel for a connection that runs nothing. `Lotus.cancel/1` asks again,
  every 100 milliseconds for up to two seconds, until the statement
  returns.

  A cancelled statement returns `{:error, "The query was cancelled."}`,
  whatever the database answered: MySQL's `SLEEP()` returns `1` when it is
  killed, and a statement may finish just as the cancel arrives.
  """

  alias Lotus.Source.Adapter

  @message "The query was cancelled."

  # How often a cancel is asked again while the statement has not returned,
  # and how many times.
  @retry_interval 100
  @retries 20

  # How long a statement that returned waits for a cancel on its way, before
  # it gives its connection back. Longer than all the retries.
  @cancel_wait 10_000

  # The token's atomics: its state, and whether the statement returned.
  @state 1
  @returned 2

  @running 0
  @cancelling 1
  @cancelled 2
  @finished 3

  @enforce_keys [:adapter, :handle, :atomics, :owner, :ref]
  defstruct @enforce_keys

  @typedoc "A token for `Lotus.cancel/1`."
  @opaque t :: %__MODULE__{
            adapter: Adapter.t(),
            handle: term(),
            atomics: :atomics.atomics_ref(),
            owner: pid() | nil,
            ref: reference()
          }

  @doc "The error a cancelled statement returns."
  @spec message() :: String.t()
  def message, do: @message

  @doc false
  # Before the statement's transaction: a token without its handle when the
  # caller passed an `:on_cancel_token` function and the source can cancel,
  # `nil` otherwise.
  @spec prepare(Adapter.t(), keyword()) :: t() | nil
  def prepare(%Adapter{} = adapter, opts) do
    if is_function(Keyword.get(opts, :on_cancel_token), 1) and
         Adapter.capability?(adapter, :cancel) do
      %__MODULE__{
        adapter: adapter,
        handle: nil,
        atomics: :atomics.new(2, signed: false),
        owner: nil,
        ref: make_ref()
      }
    end
  end

  @doc false
  # Runs `fun`, the statement, inside its transaction. With a token from
  # `prepare/2`, the caller's `:on_cancel_token` function gets it first,
  # with its handle. Once `fun` returns or raises, the token is spent; a
  # statement cancelled on the way returns the cancelled error, once the
  # cancel is done.
  @spec run(t() | nil, keyword(), (-> result)) :: result | {:error, term()}
        when result: term()
  def run(nil, _opts, fun) when is_function(fun, 0), do: fun.()

  def run(%__MODULE__{adapter: adapter} = token, opts, fun) when is_function(fun, 0) do
    case Adapter.cancel_handle(adapter) do
      {:ok, handle} ->
        token = %{token | handle: handle, owner: self()}
        run_cancellable(token, Keyword.fetch!(opts, :on_cancel_token), fun)

      {:error, _reason} = error ->
        error
    end
  end

  @doc false
  # After the statement's transaction: the cancelled error for a cancelled
  # statement, whatever the transaction made of it (a nested rollback, say);
  # `result` otherwise.
  @spec result(t() | nil, result) :: result | {:error, String.t()} when result: term()
  def result(nil, result), do: result

  def result(%__MODULE__{atomics: atomics}, result) do
    if :atomics.get(atomics, @state) == @cancelled, do: {:error, @message}, else: result
  end

  defp run_cancellable(token, notify, fun) do
    notify.(token)
    fun.()
  catch
    kind, reason ->
      finish(token, nil)
      :erlang.raise(kind, reason, __STACKTRACE__)
  else
    result -> finish(token, result)
  end

  defp finish(%__MODULE__{atomics: atomics, ref: ref}, result) do
    case :atomics.compare_exchange(atomics, @state, @running, @finished) do
      :ok ->
        result

      _cancelling_or_cancelled ->
        :atomics.put(atomics, @returned, 1)

        receive do
          {^ref, :cancel_done} -> :ok
        after
          @cancel_wait -> :ok
        end

        # A cancel the database refused puts the token back to running.
        case :atomics.compare_exchange(atomics, @state, @running, @finished) do
          :ok -> result
          _cancelled -> {:error, @message}
        end
    end
  end

  @doc false
  # `Lotus.cancel/1`.
  @spec cancel(t()) :: :ok | {:error, term()}
  def cancel(%__MODULE__{atomics: atomics} = token) do
    case :atomics.compare_exchange(atomics, @state, @running, @cancelling) do
      :ok ->
        result = cancel_until_returned(token, @retries)
        :atomics.put(atomics, @state, if(result == :ok, do: @cancelled, else: @running))
        send(token.owner, {token.ref, :cancel_done})
        result

      @finished ->
        {:error, "The query is not running."}

      _cancelling_or_cancelled ->
        :ok
    end
  end

  # Asks the database to cancel the statement, and again while it has not
  # returned. Only the first refusal is an error: once the database took a
  # cancel, the statement is reported cancelled.
  defp cancel_until_returned(%__MODULE__{} = token, retries) do
    case safe_cancel(token.adapter, token.handle) do
      :ok ->
        if retries > 0 and not returned_within?(token.atomics, @retry_interval),
          do: cancel_until_returned(token, retries - 1),
          else: :ok

      {:error, _reason} = error when retries == @retries ->
        error

      {:error, _reason} ->
        :ok
    end
  end

  defp returned_within?(atomics, wait) do
    cond do
      :atomics.get(atomics, @returned) == 1 ->
        true

      wait <= 0 ->
        false

      true ->
        Process.sleep(10)
        returned_within?(atomics, wait - 10)
    end
  end

  defp safe_cancel(adapter, handle) do
    case Adapter.cancel(adapter, handle) do
      :ok -> :ok
      {:error, _reason} = error -> error
    end
  rescue
    e -> {:error, Exception.message(e)}
  end
end
