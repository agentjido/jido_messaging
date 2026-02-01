defmodule JidoMessaging.Streaming do
  @moduledoc """
  Streaming response support for progressive message updates.

  Enables LLM-style streaming responses where message content is
  updated incrementally as it's generated. This is particularly useful
  for long-running agent responses.

  ## Channel Support

  - **Telegram**: Uses `editMessageText` to update message content
  - Other channels can implement the `StreamingChannel` behaviour

  ## Usage

      # Start a streaming response
      {:ok, stream} = Streaming.start(messaging_module, room, channel, chat_id, "Thinking...")

      # Update the content as it streams in
      :ok = Streaming.update(stream, "Thinking... Processing your request")
      :ok = Streaming.update(stream, "Thinking... Processing your request. Here's what I found:")

      # Finalize when complete
      {:ok, final_message} = Streaming.finish(stream, "Here's what I found: [full response]")

  ## Rate Limiting

  Updates are automatically rate-limited to avoid hitting API limits.
  By default, updates are throttled to at most one every 100ms.
  """

  use GenServer
  require Logger

  @schema Zoi.struct(
            __MODULE__,
            %{
              messaging_module: Zoi.any(),
              room: Zoi.struct(JidoMessaging.Room),
              channel: Zoi.any(),
              chat_id: Zoi.any(),
              message_id: Zoi.any() |> Zoi.nullish(),
              current_content: Zoi.string() |> Zoi.nullish(),
              last_update_at: Zoi.integer() |> Zoi.nullish(),
              min_update_interval_ms: Zoi.integer(),
              pending_update: Zoi.string() |> Zoi.nullish()
            },
            coerce: false
          )

  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema"
  def schema, do: @schema

  @default_min_interval_ms 100

  @doc """
  Start a streaming response.

  Sends an initial message and returns a stream handle for updates.

  ## Options

  - `:min_update_interval_ms` - Minimum time between updates (default: 100)
  - `:parse_mode` - Telegram parse mode ("Markdown", "HTML", etc.)
  """
  def start(messaging_module, room, channel, chat_id, initial_content, opts \\ []) do
    GenServer.start(__MODULE__, %{
      messaging_module: messaging_module,
      room: room,
      channel: channel,
      chat_id: chat_id,
      initial_content: initial_content,
      opts: opts
    })
  end

  @doc """
  Update the streaming message content.

  If updates come faster than the rate limit, only the latest content
  will be sent when the throttle window expires.
  """
  def update(stream, content) do
    GenServer.cast(stream, {:update, content})
  end

  @doc """
  Finalize the streaming response.

  Sends the final content and stops the stream process.
  Returns the final message info.
  """
  def finish(stream, final_content) do
    GenServer.call(stream, {:finish, final_content})
  end

  @doc """
  Cancel the streaming response without sending a final update.
  """
  def cancel(stream) do
    GenServer.cast(stream, :cancel)
  end

  @doc """
  Get the current state of the stream.
  """
  def get_state(stream) do
    GenServer.call(stream, :get_state)
  end

  # GenServer callbacks

  @impl true
  def init(%{
        messaging_module: messaging_module,
        room: room,
        channel: channel,
        chat_id: chat_id,
        initial_content: initial_content,
        opts: opts
      }) do
    min_interval = Keyword.get(opts, :min_update_interval_ms, @default_min_interval_ms)

    case channel.send_message(chat_id, initial_content, opts) do
      {:ok, %{message_id: message_id}} ->
        state =
          struct!(__MODULE__, %{
            messaging_module: messaging_module,
            room: room,
            channel: channel,
            chat_id: chat_id,
            message_id: message_id,
            current_content: initial_content,
            last_update_at: System.monotonic_time(:millisecond),
            min_update_interval_ms: min_interval,
            pending_update: nil
          })

        {:ok, state}

      {:error, reason} ->
        {:stop, {:send_failed, reason}}
    end
  end

  @impl true
  def handle_cast({:update, content}, state) do
    now = System.monotonic_time(:millisecond)
    elapsed = now - state.last_update_at

    if elapsed >= state.min_update_interval_ms do
      new_state = do_update(state, content)
      {:noreply, new_state}
    else
      remaining = state.min_update_interval_ms - elapsed

      if state.pending_update == nil do
        Process.send_after(self(), :flush_pending, remaining)
      end

      {:noreply, %{state | pending_update: content}}
    end
  end

  def handle_cast(:cancel, state) do
    {:stop, :normal, state}
  end

  @impl true
  def handle_call({:finish, final_content}, _from, state) do
    case cancel_pending_timer(state) do
      state -> do_update(state, final_content)
    end

    result = {:ok, %{message_id: state.message_id, content: final_content}}
    {:stop, :normal, result, state}
  end

  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_info(:flush_pending, %{pending_update: nil} = state) do
    {:noreply, state}
  end

  def handle_info(:flush_pending, %{pending_update: content} = state) do
    new_state = do_update(%{state | pending_update: nil}, content)
    {:noreply, new_state}
  end

  # Private helpers

  defp do_update(state, content) when content == state.current_content do
    state
  end

  defp do_update(state, content) do
    case edit_message(state, content) do
      :ok ->
        %{
          state
          | current_content: content,
            last_update_at: System.monotonic_time(:millisecond)
        }

      {:error, reason} ->
        Logger.warning("Streaming update failed: #{inspect(reason)}")
        state
    end
  end

  defp edit_message(%{channel: channel} = state, content) do
    if function_exported?(channel, :edit_message, 3) do
      case channel.edit_message(state.chat_id, state.message_id, content) do
        {:ok, _} -> :ok
        error -> error
      end
    else
      Logger.debug("Channel #{inspect(channel)} does not support edit_message")
      :ok
    end
  end

  defp cancel_pending_timer(state) do
    %{state | pending_update: nil}
  end
end
