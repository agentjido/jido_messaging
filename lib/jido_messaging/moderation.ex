defmodule JidoMessaging.Moderation do
  @moduledoc """
  Moderation behaviour and utilities for message filtering.

  Provides a behaviour for implementing content moderation strategies,
  plus utilities for composing and applying moderators.

  ## Implementing a Moderator

      defmodule MyApp.SpamFilter do
        @behaviour JidoMessaging.Moderation

        @impl true
        def moderate(message, _opts) do
          if contains_spam?(message) do
            {:reject, :spam, "Message contains spam"}
          else
            :allow
          end
        end

        defp contains_spam?(_message), do: false
      end

  ## Moderation Results

  - `:allow` - Message passes moderation
  - `{:reject, reason, description}` - Message is rejected
  - `{:flag, reason, description}` - Message is flagged for review but allowed
  - `{:modify, message}` - Message is modified (e.g., content filtered)
  """

  alias JidoMessaging.Message

  @type reason :: atom()
  @type description :: String.t()
  @type result ::
          :allow
          | {:reject, reason(), description()}
          | {:flag, reason(), description()}
          | {:modify, Message.t()}

  @doc """
  Moderate a message before it is processed.

  Returns a moderation result indicating whether the message should be
  allowed, rejected, flagged, or modified.
  """
  @callback moderate(message :: Message.t(), opts :: keyword()) :: result()

  @doc """
  Apply a list of moderators to a message in sequence.

  Stops at the first rejection. Flags are accumulated.
  Modifications are applied in order.

  Returns `{:ok, message, flags}` or `{:error, reason, description}`.
  """
  def apply_moderators(message, moderators, opts \\ []) do
    apply_moderators_loop(message, moderators, opts, [])
  end

  defp apply_moderators_loop(message, [], _opts, flags) do
    {:ok, message, Enum.reverse(flags)}
  end

  defp apply_moderators_loop(message, [moderator | rest], opts, flags) do
    case moderator.moderate(message, opts) do
      :allow ->
        apply_moderators_loop(message, rest, opts, flags)

      {:reject, reason, description} ->
        {:error, reason, description}

      {:flag, reason, description} ->
        apply_moderators_loop(message, rest, opts, [{reason, description} | flags])

      {:modify, modified_message} ->
        apply_moderators_loop(modified_message, rest, opts, flags)
    end
  end

  @doc """
  Check if a moderation result allows the message.
  """
  def allowed?(:allow), do: true
  def allowed?({:flag, _, _}), do: true
  def allowed?({:modify, _}), do: true
  def allowed?({:reject, _, _}), do: false
end
