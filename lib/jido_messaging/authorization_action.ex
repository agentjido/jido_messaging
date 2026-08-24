defmodule Jido.Messaging.AuthorizationAction do
  @moduledoc """
  Closed vocabulary for durable messaging grants.

  The chat action names match `Jido.Messaging.ChatActions`. Agent invocation,
  canonical delivery, and transcript reads use additional messaging actions.
  """

  @actions [
    :add_reaction,
    :delete_subscription,
    :delete_message,
    :discover_principal,
    :edit_message,
    :ensure_subscription,
    :fetch_channel_messages,
    :fetch_channel_metadata,
    :fetch_message,
    :fetch_thread,
    :fetch_thread_messages,
    :invoke_agent,
    :list_subscriptions,
    :list_threads,
    :lookup_participant,
    :lookup_user,
    :post_channel_message,
    :post_message,
    :read_transcript,
    :receive_message,
    :remove_reaction,
    :send_direct_message,
    :start_typing
  ]

  @type t :: unquote(Enum.reduce(@actions, &{:|, [], [&1, &2]}))

  @doc "Returns all supported durable messaging actions."
  @spec all() :: [t()]
  def all, do: @actions

  @doc "Normalizes a supported action without creating atoms."
  @spec normalize!(atom() | String.t()) :: t()
  def normalize!(action) when action in @actions, do: action

  def normalize!(action) when is_binary(action) do
    Enum.find(@actions, &(Atom.to_string(&1) == action)) ||
      raise ArgumentError, "unsupported messaging authorization action"
  end

  def normalize!(_action), do: raise(ArgumentError, "unsupported messaging authorization action")
end
