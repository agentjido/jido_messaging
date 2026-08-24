defmodule Jido.Messaging.JidokaDelegationContext do
  @moduledoc """
  Authorized canonical messages for one Jidoka delegation event.

  This value does not contain a Jidoka task, forwarded context, operation
  output, prompt, memory, or handoff ownership state.
  """

  alias Jido.Messaging.{JidokaDelegationEvent, Message}

  @enforce_keys [:event, :messages]
  defstruct [:event, :messages]

  @type t :: %__MODULE__{
          event: JidokaDelegationEvent.t(),
          messages: [Message.t()]
        }

  @doc "Builds an authorized delegation context from canonical messages."
  @spec new(JidokaDelegationEvent.t(), [Message.t()]) :: t()
  def new(%JidokaDelegationEvent{} = event, messages) when is_list(messages) do
    %__MODULE__{event: event, messages: messages}
  end
end
