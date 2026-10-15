defmodule Jido.Messaging.ChatRequestStore do
  @moduledoc false
  alias Jido.Messaging.RequestStore

  def claim({store, generation}, key, digest),
    do: RequestStore.call(store, {:claim, {:chat, generation, key}, digest, generation})

  def complete({store, _generation}, claim, result),
    do: RequestStore.call(store, {:complete, claim, result})

  def remember({store, generation}, result_id, class, tag),
    do: RequestStore.call(store, {:remember, {:chat_failure, generation, result_id}, {class, tag}})

  def failure({store, generation}, result_id),
    do: RequestStore.call(store, {:lookup, {:chat_failure, generation, result_id}})
end
