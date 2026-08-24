defmodule Jido.Messaging.JidokaContinuityContext do
  @moduledoc """
  Scoped messaging transcript and continuity link for a Jidoka adapter.

  The context contains canonical messages only. It does not assemble a prompt,
  recall memory, load a Jidoka session, or resume a turn.
  """

  alias Jido.Messaging.{Message, ThreadContinuityLink}

  @enforce_keys [:link, :messages]
  defstruct [:link, :messages]

  @type t :: %__MODULE__{
          link: ThreadContinuityLink.t(),
          messages: [Message.t()]
        }

  @doc "Builds a scoped continuity context from canonical messages."
  @spec new(ThreadContinuityLink.t(), [Message.t()]) :: t()
  def new(%ThreadContinuityLink{} = link, messages) when is_list(messages) do
    %__MODULE__{link: link, messages: messages}
  end
end
