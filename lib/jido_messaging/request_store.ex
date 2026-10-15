defmodule Jido.Messaging.RequestStore do
  @moduledoc false
  use GenServer
  alias Jido.Chat.Signal.Policy
  alias Jido.Messaging.RequestStore.Worker

  @entry_limit 1_000
  @byte_limit 16 * 1_024 * 1_024

  def start_link(owner), do: GenServer.start_link(__MODULE__, owner)

  def call(store, operation) do
    GenServer.call(store, operation, :infinity)
  catch
    :exit, _ -> Policy.error(:request_outcome_unknown)
  end

  @impl true
  def init(owner) do
    Process.flag(:trap_exit, true)
    epoch = :crypto.strong_rand_bytes(32)
    directory = Path.join(System.tmp_dir!(), "jido-request-" <> Base.url_encode64(epoch, padding: false))
    path = Path.join(directory, "history.sqlite3")

    with :ok <- File.mkdir(directory),
         :ok <- File.chmod(directory, 0o700),
         :ok <- File.write(path, "", [:exclusive]),
         :ok <- File.chmod(path, 0o600),
         {:ok, worker} <- Worker.start_link(path: path, epoch: epoch, new: true) do
      {:ok,
       %{
         owner: owner,
         directory: directory,
         path: path,
         epoch: epoch,
         worker: worker,
         retry: nil,
         cache: %{},
         order: :queue.new(),
         bytes: 0
       }}
    else
      _ ->
        File.rm_rf(directory)
        {:stop, :request_store_unavailable}
    end
  end

  @impl true
  def handle_call(operation, from, state) do
    request(operation, from, state)
  rescue
    _ -> unavailable(state)
  catch
    _, _ -> unavailable(state)
  end

  defp request(:stats, _from, state) do
    case store_call(state, :stats) do
      {:ok, stats} ->
        {:reply,
         {:ok,
          Map.merge(stats, %{
            cache_entries: map_size(state.cache),
            cache_bytes: state.bytes,
            entry_limit: @entry_limit,
            byte_limit: @byte_limit,
            path: state.path,
            worker: state.worker
          })}, state}

      _ ->
        unavailable(state)
    end
  end

  defp request({:claim, key, digest, authority}, {owner, _tag}, state) do
    encoded_key = encode(key)

    case read(state, encoded_key) do
      {:ok, nil} ->
        entry = {key, digest, authority, {:running, owner}}

        case store_call(state, {:write, encoded_key, encode(entry), 0}) do
          {:ok, []} -> {:reply, {:ok, {key, digest, authority}}, state}
          _ -> unavailable(state)
        end

      {:ok, {^key, ^digest, ^authority, {:done, result}} = entry} ->
        {:reply, {:cached, result}, cache(state, encoded_key, entry)}

      {:ok, {^key, ^digest, ^authority, {:running, previous}}} ->
        {:reply, Policy.error(if(Process.alive?(previous), do: :request_in_progress, else: :request_outcome_unknown)),
         state}

      {:ok, {^key, ^digest, ^authority, :unknown}} ->
        {:reply, Policy.error(:request_outcome_unknown), state}

      {:ok, _entry} ->
        {:reply, Policy.error(:request_conflict), state}

      _ ->
        unavailable(state)
    end
  end

  defp request({:complete, {key, digest, authority}, result}, {owner, _tag}, state) do
    encoded_key = encode(key)

    case read(state, encoded_key) do
      {:ok, {^key, ^digest, ^authority, {:running, ^owner}}} ->
        entry = {key, digest, authority, {:done, result}}

        case store_call(state, {:write, encoded_key, encode(entry), 1}) do
          {:ok, []} -> {:reply, :ok, cache(state, encoded_key, entry)}
          _ -> unavailable(state)
        end

      {:ok, {^key, ^digest, ^authority, {:done, ^result}}} ->
        {:reply, :ok, state}

      {:ok, _} ->
        {:reply, Policy.error(:request_outcome_unknown), state}

      _ ->
        unavailable(state)
    end
  end

  defp request({:remember, key, value}, _from, state) do
    encoded_key = encode(key)
    entry = {key, :metadata, :metadata, {:done, value}}

    case store_call(state, {:write, encoded_key, encode(entry), 1}) do
      {:ok, []} -> {:reply, :ok, cache(drop_cache(state, encoded_key), encoded_key, entry)}
      _ -> unavailable(state)
    end
  end

  defp request({:lookup, key}, _from, state) do
    encoded_key = encode(key)

    case read(state, encoded_key) do
      {:ok, {^key, :metadata, :metadata, {:done, value}} = entry} ->
        {:reply, {:ok, value}, cache(state, encoded_key, entry)}

      {:ok, nil} ->
        {:reply, {:error, :not_found}, state}

      _ ->
        unavailable(state)
    end
  end

  defp request(_operation, _from, state),
    do: {:stop, :request_store_failed, Policy.error(:request_outcome_unknown), state}

  @impl true
  def handle_cast(_message, state), do: {:noreply, state}

  @impl true
  def handle_info({:EXIT, owner, reason}, %{owner: owner} = state), do: {:stop, reason, state}

  def handle_info({:EXIT, worker, _reason}, %{worker: worker} = state), do: {:noreply, recover(state)}

  def handle_info({:reopen, token}, %{retry: token} = state) do
    case Worker.start_link(path: state.path, epoch: state.epoch) do
      {:ok, worker} -> {:noreply, %{state | worker: worker, retry: nil}}
      _ -> {:noreply, recover(%{state | retry: nil})}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if is_pid(state.worker) and Process.alive?(state.worker), do: GenServer.stop(state.worker, :normal, :infinity)
    File.rm_rf(state.directory)
    :ok
  end

  @impl true
  def format_status(status) do
    Map.new(status, fn
      {:state, _} -> {:state, :private_request_history}
      {:message, _} -> {:message, :private_request_history}
      {:client_info, _} -> {:client_info, :undefined}
      {:reason, _} -> {:reason, :request_store_failed}
      {:log, _} -> {:log, []}
      field -> field
    end)
  end

  defp read(%{worker: nil}, _key), do: {:error, :request_store_unavailable}

  defp read(state, key) do
    if Process.alive?(state.worker) do
      case state.cache[key] do
        nil -> read_disk(state, key)
        encoded -> {:ok, :erlang.binary_to_term(encoded)}
      end
    else
      {:error, :request_store_unavailable}
    end
  end

  defp read_disk(state, key) do
    case store_call(state, {:read, key}) do
      {:ok, []} ->
        {:ok, nil}

      {:ok, [[encoded, status]]} ->
        {entry_key, digest, authority, value} = :erlang.binary_to_term(encoded)
        {:ok, {entry_key, digest, authority, if(status == 2, do: :unknown, else: value)}}

      _ ->
        {:error, :request_store_unavailable}
    end
  end

  defp store_call(%{worker: nil}, _operation), do: {:error, :request_store_unavailable}

  defp store_call(state, operation) do
    GenServer.call(state.worker, operation, :infinity)
  catch
    :exit, _ -> {:error, :request_store_unavailable}
  end

  defp unavailable(state), do: {:reply, Policy.error(:request_outcome_unknown), recover(state)}

  defp recover(state) do
    if is_pid(state.worker) and Process.alive?(state.worker), do: Process.exit(state.worker, :kill)
    token = state.retry || make_ref()
    if is_nil(state.retry), do: Process.send_after(self(), {:reopen, token}, 100)
    %{state | worker: nil, retry: token, cache: %{}, order: :queue.new(), bytes: 0}
  end

  defp drop_cache(state, key) do
    case Map.pop(state.cache, key) do
      {nil, _cache} ->
        state

      {encoded, cache} ->
        %{
          state
          | cache: cache,
            bytes: state.bytes - byte_size(encoded),
            order: :queue.filter(&(&1 != key), state.order)
        }
    end
  end

  defp cache(state, key, entry) do
    encoded = encode(entry)

    cond do
      byte_size(encoded) > @byte_limit ->
        state

      Map.has_key?(state.cache, key) ->
        state

      true ->
        trim(%{
          state
          | cache: Map.put(state.cache, key, encoded),
            order: :queue.in(key, state.order),
            bytes: state.bytes + byte_size(encoded)
        })
    end
  end

  defp trim(state) when map_size(state.cache) <= @entry_limit and state.bytes <= @byte_limit, do: state

  defp trim(state) do
    {{:value, key}, order} = :queue.out(state.order)
    {encoded, cache} = Map.pop(state.cache, key)
    trim(%{state | cache: cache, order: order, bytes: state.bytes - byte_size(encoded)})
  end

  defp encode(value), do: :erlang.term_to_binary(value, [:deterministic])
end
