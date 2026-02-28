defmodule Jido.Messaging.Demo.DiscordHandler do
  @moduledoc """
  Demo process placeholder for Discord ingress wiring.

  Phase 3 removed in-package platform handler stacks from `jido_messaging`.
  Live Discord ingress should be wired through `jido_chat_discord`.
  """

  use GenServer
  require Logger

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(state) do
    Logger.info("[Demo.DiscordHandler] Started placeholder process")
    {:ok, state}
  end

  @doc false
  def handle_message(_message, _context), do: :noreply
end
